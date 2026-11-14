#!/bin/sh
# Builds the kernel/NVIDIA side of VPinOS into dist/, from versions.env:
#
#   vpinos-platform (amd64, arm64)             the apt pins (+ NVIDIA modprobe
#                                              config on amd64); no version-
#                                              locked dependencies
#   vpinos-kernel (amd64, arm64)               the exact kernel (+ NVIDIA
#                                              modules on amd64)
#   vpinos-nvidia-modules-<KERNEL_ABI>-amd64   the NVIDIA kernel modules,
#                                              prebuilt for exactly that kernel
#
# Why two packages: apt picks versions using the pins already on the
# cabinet. A new kernel/driver needs new pins first, so the pins
# (vpinos-platform) must be able to upgrade on their own in one apt run,
# and the kernel/driver (vpinos-kernel) follows in the next run, under
# the new pins. vpinos-update.sh runs two rounds for exactly this.
#
#   docker build -t vpinos-packages-builder .
#   ./build-platform.sh
#
# The modules are built the way the ISO's old 0120 hook built them --
# linux-image + linux-headers from the frozen backports snapshot,
# nvidia-kernel-open-dkms from NVIDIA's repo, DKMS -- just in a throwaway
# container instead of the image, so cabinets get them through apt and
# never need a compiler. Needs network (snapshot.debian.org, NVIDIA).
set -e

. ./versions.env
KABI="${KERNEL_ABI}-amd64"
MODPKG="vpinos-nvidia-modules-${KABI}"
# Platform version first, so even a driver *rollback* is an upgrade.
MODVER="${PLATFORM_VERSION}+nv${NVIDIA_VERSION}"
APT=vpinos-platform/apt

# versions.env and the apt files cabinets get must agree -- they're
# edited by hand together on a bump.
grep -q "/archive/debian/${SNAPSHOT}/" "$APT/vpinos-backports.list" || {
    echo "E: $APT/vpinos-backports.list doesn't use SNAPSHOT=${SNAPSHOT}" >&2; exit 1; }
grep -q "^Pin: version ${NVIDIA_VERSION}-\*$" "$APT/vpinos-nvidia-repo.pref" || {
    echo "E: $APT/vpinos-nvidia-repo.pref doesn't pin NVIDIA_VERSION=${NVIDIA_VERSION}" >&2; exit 1; }
case "$NVIDIA_DEB_VERSION" in
    "$NVIDIA_VERSION"-*) ;;
    *) echo "E: NVIDIA_DEB_VERSION=$NVIDIA_DEB_VERSION isn't a revision of NVIDIA_VERSION=$NVIDIA_VERSION" >&2; exit 1 ;;
esac

mkdir -p dist
docker run --rm -v "$PWD:/work" -w /work \
    -e KABI="$KABI" -e MODPKG="$MODPKG" -e MODVER="$MODVER" \
    -e PLATFORM_VERSION="$PLATFORM_VERSION" -e NVIDIA_VERSION="$NVIDIA_VERSION" \
    -e NVIDIA_DEB_VERSION="$NVIDIA_DEB_VERSION" -e NVIDIA_USERSPACE="$NVIDIA_USERSPACE" \
    -e NVIDIA_LEGACY_VERSION="$NVIDIA_LEGACY_VERSION" -e NVIDIA_LEGACY_SHA256="$NVIDIA_LEGACY_SHA256" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    vpinos-packages-builder bash -ec '
export DEBIAN_FRONTEND=noninteractive
APT=vpinos-platform/apt

# --- the same apt setup a cabinet has ---------------------------------
sed -i "s/^Components:.*/Components: main contrib non-free non-free-firmware/" /etc/apt/sources.list.d/debian.sources
cp $APT/vpinos-backports.list /etc/apt/sources.list.d/
cp $APT/vpinos-backports.pref $APT/vpinos-nvidia-repo.pref /etc/apt/preferences.d/
# Build container only: vpinos-nvidia-repo.pref makes the DKMS module
# source uninstallable (cabinets must never get it), but this is exactly
# where it is supposed to be installed. Read first (alphabetical), so its
# record wins.
printf "Package: nvidia-kernel-open-dkms\nPin: version %s\nPin-Priority: 1001\n" "$NVIDIA_DEB_VERSION" \
    > /etc/apt/preferences.d/00-vpinos-build.pref
apt-get update -qq
apt-get install -y -qq curl ca-certificates >/dev/null
curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/cuda-keyring_1.1-1_all.deb -o /tmp/cuda-keyring.deb
dpkg -i /tmp/cuda-keyring.deb >/dev/null
apt-get update -qq

# --- build the modules ------------------------------------------------
# linux-image too, not just headers: with the kernel installed, DKMS
# compresses the modules the same way the kernel ships its own (.ko.xz),
# so the files match what 1.1 cabinets already have at the same paths.
apt-get install -y -qq --no-install-recommends \
    "linux-image-$KABI" "linux-headers-$KABI" build-essential dkms kmod xz-utils >/tmp/apt-kernel.log 2>&1 \
    || { tail -30 /tmp/apt-kernel.log; exit 1; }
apt-get install -y -qq --no-install-recommends "nvidia-kernel-open-dkms=$NVIDIA_DEB_VERSION" >/tmp/apt-nvidia.log 2>&1 \
    || { tail -30 /tmp/apt-nvidia.log; exit 1; }
moddir=/usr/lib/modules/$KABI/updates/dkms
ls "$moddir"/*.ko* >/dev/null 2>&1 || { echo "E: DKMS built nothing for $KABI"; grep -i dkms /tmp/apt-nvidia.log | tail; exit 1; }
for ko in "$moddir"/*.ko*; do
    vm=$(modinfo -F vermagic "$ko" | cut -d" " -f1)
    [ "$vm" = "$KABI" ] || { echo "E: $(basename "$ko") vermagic $vm != $KABI"; exit 1; }
    mv=$(modinfo -F version "$ko")
    case "$(basename "$ko")" in
        nvidia.ko*) [ "$mv" = "$NVIDIA_VERSION" ] || { echo "E: nvidia module version $mv != $NVIDIA_VERSION"; exit 1; } ;;
    esac
done
echo "I: built for $KABI: $(cd "$moddir" && ls | tr "\n" " ")"
kver=$(dpkg-query -W -f="\${Version}" "linux-image-$KABI")

# Warn when NVIDIA_USERSPACE has drifted from what nvidia-driver
# actually pulls in at this version (packages renamed/added on a bump).
for dep in $(apt-cache depends "nvidia-driver=$NVIDIA_DEB_VERSION" 2>/dev/null | awk "/Depends:/{print \$2}" | tr -d "<>"); do
    case " $NVIDIA_USERSPACE nvidia-kernel-open-dkms nvidia-kernel-dkms " in
        *" $dep "*) ;;
        *) echo "W: nvidia-driver $NVIDIA_DEB_VERSION depends on $dep, which NVIDIA_USERSPACE does not list" ;;
    esac
done

out=/tmp/pkgs
mkdir -p $out

# --- vpinos-nvidia-modules-<kabi> ---------------------------------------
st=$out/modules
mkdir -p "$st/DEBIAN" "$st$moddir"
cp -a "$moddir"/*.ko* "$st$moddir/"
mkdir -p "$st/usr/share/doc/$MODPKG"
cp vpinos-core/debian/copyright "$st/usr/share/doc/$MODPKG/copyright"
deps="linux-image-$KABI"
for p in $NVIDIA_USERSPACE; do deps="$deps, $p (= $NVIDIA_DEB_VERSION)"; done
cat > "$st/DEBIAN/control" <<EOF
Package: $MODPKG
Version: $MODVER
Architecture: amd64
Maintainer: Superhac <superhac007@gmail.com>
Section: kernel
Priority: optional
Depends: $deps
Homepage: https://github.com/vpinos/vpinos-packages
Description: NVIDIA $NVIDIA_VERSION kernel modules for Linux $KABI (VPinOS)
 The open NVIDIA kernel modules (nvidia, nvidia-modeset, nvidia-drm,
 nvidia-uvm, nvidia-peermem) prebuilt for exactly linux-image-$KABI
 $kver, so a cabinet never needs DKMS or a compiler. Holds the NVIDIA
 userspace at exactly $NVIDIA_DEB_VERSION, so the libraries and the
 modules can only ever move together.
EOF
cat > "$st/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
if [ "\$1" = configure ]; then
    depmod -a $KABI
    # The initramfs carries modprobe.d (nvidia-drm modeset=1).
    if [ -e /boot/initrd.img-$KABI ] && command -v update-initramfs >/dev/null; then
        update-initramfs -u -k $KABI
    fi
    # Takes effect on the next boot; the running kernel keeps whatever
    # nvidia module it already loaded.
    [ -d /run ] && touch /run/reboot-required 2>/dev/null || true
fi
exit 0
EOF
cat > "$st/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
case "\$1" in
    remove|purge)
        [ -d /usr/lib/modules/$KABI/kernel ] && depmod -a $KABI || true
        ;;
esac
exit 0
EOF
chmod 0755 "$st/DEBIAN/postinst" "$st/DEBIAN/postrm"
dpkg-deb --root-owner-group -Zxz --build "$st" "$out/${MODPKG}_${MODVER}_amd64.deb" >/dev/null

# --- vpinos-nvidia-legacy-userspace + vpinos-nvidia-legacy-<kabi> --------
# NVIDIA 580 for Maxwell/Pascal/Volta, which the 615 open module refuses
# (see versions.env). From the NVIDIA .run rather than its apt repo: 580 is
# only in the debian12 repo, and those packages share names with the 615
# ones vpinos-nvidia-repo.pref holds at an exact version. The closed
# modules get the same kbuild DKMS would do; the userspace goes to its own
# directory, picked by vpinos-launch when this module version is loaded,
# so nothing of the 615 packages is replaced. Installed on demand
# (vpinos-nvidia-legacy-setup.sh), never in the ISO.
LEGACY_DIR=/usr/lib/vpinos-nvidia-legacy
LEGACY_RUN=NVIDIA-Linux-x86_64-$NVIDIA_LEGACY_VERSION
LEGPKG="vpinos-nvidia-legacy-${KABI}"
LEGVER="${PLATFORM_VERSION}+nv${NVIDIA_LEGACY_VERSION}"
curl -fsSL "https://download.nvidia.com/XFree86/Linux-x86_64/$NVIDIA_LEGACY_VERSION/$LEGACY_RUN.run" -o "/tmp/$LEGACY_RUN.run"
echo "$NVIDIA_LEGACY_SHA256  /tmp/$LEGACY_RUN.run" | sha256sum -c --quiet
(cd /tmp && sh "$LEGACY_RUN.run" -x >/dev/null)
src=/tmp/$LEGACY_RUN
make -C "$src/kernel" -j"$(nproc)" SYSSRC="/usr/lib/modules/$KABI/source" SYSOUT="/usr/lib/modules/$KABI/build" modules \
    >/tmp/legacy-build.log 2>&1 || { tail -30 /tmp/legacy-build.log; exit 1; }
for ko in "$src"/kernel/*.ko; do
    vm=$(modinfo -F vermagic "$ko" | cut -d" " -f1)
    [ "$vm" = "$KABI" ] || { echo "E: legacy $(basename "$ko") vermagic $vm != $KABI"; exit 1; }
done
mv=$(modinfo -F version "$src/kernel/nvidia.ko")
[ "$mv" = "$NVIDIA_LEGACY_VERSION" ] || { echo "E: legacy nvidia module version $mv != $NVIDIA_LEGACY_VERSION"; exit 1; }
echo "I: built legacy $NVIDIA_LEGACY_VERSION for $KABI: $(cd "$src/kernel" && ls *.ko | tr "\n" " ")"

st=$out/legacy-userspace
L=$st$LEGACY_DIR
LIBDIR=/usr/lib/x86_64-linux-gnu
mkdir -p "$st/DEBIAN" "$st$LIBDIR" "$L/egl_external_platform.d" "$L/lib" "$L/bin" "$st/usr/share/doc/vpinos-nvidia-legacy-userspace"
# What EGL (Hyprland), GBM, Vulkan (VPinball) and nvidia-smi load; not
# CUDA/OpenCL/NGX/ray tracing, which nothing here uses. Into the normal
# library directory under their full versioned names, which the 615
# packages never use, so ld.so finds their versioned NEEDED entries even
# for Hyprland (cap_sys_nice: secure-execution, no LD_LIBRARY_PATH).
# ldconfig keeps the soname links on the highest version, the 615 ones.
for lib in libEGL_nvidia libGLX_nvidia libGLESv1_CM_nvidia libGLESv2_nvidia \
    libnvidia-eglcore libnvidia-glcore libnvidia-glsi libnvidia-glvkspirv libnvidia-gpucomp \
    libnvidia-tls libnvidia-allocator libnvidia-ml libnvidia-cfg libnvidia-present libnvidia-wayland-client; do
    install -m 0644 "$src/$lib.so.$NVIDIA_LEGACY_VERSION" "$st$LIBDIR/"
done
# EGL platform plugins of this driver (the image has newer ones, which
# this driver does not work with). Unique versioned file names too.
for f in "$src"/libnvidia-egl-gbm.so.1.* "$src"/libnvidia-egl-wayland.so.1.* \
    "$src"/libnvidia-egl-xcb.so.1.* "$src"/libnvidia-egl-xlib.so.1.*; do
    install -m 0644 "$f" "$st$LIBDIR/"
done
# The entry points, by absolute path; vpinos-gpu-driver.sh bind-mounts
# them over the 615 ones while this module version is loaded.
icd() { printf "{\"file_format_version\": \"1.0.0\", \"ICD\": {\"library_path\": \"%s\"}}\n" "$1"; }
icd "$LIBDIR/libEGL_nvidia.so.$NVIDIA_LEGACY_VERSION" > "$L/10_nvidia.json"
sed "s#\"libGLX_nvidia.so.0\"#\"$LIBDIR/libGLX_nvidia.so.$NVIDIA_LEGACY_VERSION\"#" "$src/nvidia_icd.json" > "$L/nvidia_icd.json"
icd "$LIBDIR/$(basename "$src"/libnvidia-egl-wayland.so.1.*)" > "$L/egl_external_platform.d/10_nvidia_wayland.json"
icd "$LIBDIR/$(basename "$src"/libnvidia-egl-gbm.so.1.*)" > "$L/egl_external_platform.d/15_nvidia_gbm.json"
icd "$LIBDIR/$(basename "$src"/libnvidia-egl-xcb.so.1.*)" > "$L/egl_external_platform.d/20_nvidia_xcb.json"
icd "$LIBDIR/$(basename "$src"/libnvidia-egl-xlib.so.1.*)" > "$L/egl_external_platform.d/20_nvidia_xlib.json"
# nvidia-smi loads libnvidia-ml.so.1 by soname, which is the 615 one.
ln -s "$LIBDIR/libnvidia-ml.so.$NVIDIA_LEGACY_VERSION" "$L/lib/libnvidia-ml.so.1"
install -m 0755 "$src/nvidia-smi" "$L/bin/nvidia-smi.real"
printf "#!/bin/sh\nLD_LIBRARY_PATH=%s/lib exec %s/bin/nvidia-smi.real \"\$@\"\n" "$LEGACY_DIR" "$LEGACY_DIR" > "$L/bin/nvidia-smi"
chmod 0755 "$L/bin/nvidia-smi"
echo "$NVIDIA_LEGACY_VERSION" > "$L/version"
cp vpinos-core/debian/copyright "$st/usr/share/doc/vpinos-nvidia-legacy-userspace/copyright"
cp "$src/LICENSE" "$st/usr/share/doc/vpinos-nvidia-legacy-userspace/LICENSE.nvidia"
cat > "$st/DEBIAN/control" <<EOF
Package: vpinos-nvidia-legacy-userspace
Version: $LEGVER
Architecture: amd64
Maintainer: Superhac <superhac007@gmail.com>
Section: non-free/libs
Priority: optional
Depends: libc6, libglvnd0, libvulkan1, libgbm1, libdrm2
Homepage: https://github.com/vpinos/vpinos-packages
Description: NVIDIA $NVIDIA_LEGACY_VERSION userspace for Maxwell/Pascal/Volta (VPinOS)
 The EGL, GLX, Vulkan and GBM libraries of the NVIDIA $NVIDIA_LEGACY_VERSION
 driver and its EGL platform plugins, under versioned names beside the
 image NVIDIA driver without replacing any of its files, plus nvidia-smi
 in $LEGACY_DIR/bin. vpinos-gpu-driver.sh switches the EGL, GBM and
 Vulkan entry points to them while this nvidia module is loaded.
EOF
echo "activate-noawait ldconfig" > "$st/DEBIAN/triggers"
dpkg-deb --root-owner-group -Zxz --build "$st" "$out/vpinos-nvidia-legacy-userspace_${LEGVER}_amd64.deb" >/dev/null

st=$out/legacy-modules
lmd=/usr/lib/modules/$KABI/updates/nvidia-legacy
mkdir -p "$st/DEBIAN" "$st$lmd" "$st/usr/lib/depmod.d" "$st/usr/share/doc/$LEGPKG"
for ko in "$src"/kernel/*.ko; do
    xz -C crc32 -c "$ko" > "$st$lmd/$(basename "$ko").xz"
done
# Takes the module names over from the 615 ones in updates/dkms for this
# kernel only, so `modprobe nvidia` (vpinos-gpu-driver.sh) loads 580.
for m in nvidia nvidia_modeset nvidia_drm nvidia_uvm nvidia_peermem; do
    echo "override $m $KABI updates/nvidia-legacy"
done > "$st/usr/lib/depmod.d/$LEGPKG.conf"
cp vpinos-core/debian/copyright "$st/usr/share/doc/$LEGPKG/copyright"
cat > "$st/DEBIAN/control" <<EOF
Package: $LEGPKG
Version: $LEGVER
Architecture: amd64
Maintainer: Superhac <superhac007@gmail.com>
Section: non-free/kernel
Priority: optional
Depends: linux-image-$KABI, vpinos-nvidia-legacy-userspace (= $LEGVER)
Homepage: https://github.com/vpinos/vpinos-packages
Description: NVIDIA $NVIDIA_LEGACY_VERSION legacy kernel modules for Linux $KABI (VPinOS)
 The closed NVIDIA kernel modules of the $NVIDIA_LEGACY_VERSION driver (NVIDIA
 last branch for Maxwell, Pascal and Volta: GTX 900/10 series), which the
 image driver does not support. Prebuilt for exactly
 linux-image-$KABI $kver, with a depmod override so they are the nvidia
 modules this kernel loads.
EOF
cat > "$st/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
if [ "\$1" = configure ]; then
    depmod -a $KABI
    [ -d /run ] && touch /run/reboot-required 2>/dev/null || true
fi
exit 0
EOF
cat > "$st/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
case "\$1" in
    remove|purge)
        [ -d /usr/lib/modules/$KABI/kernel ] && depmod -a $KABI || true
        ;;
esac
exit 0
EOF
chmod 0755 "$st/DEBIAN/postinst" "$st/DEBIAN/postrm"
dpkg-deb --root-owner-group -Zxz --build "$st" "$out/${LEGPKG}_${LEGVER}_amd64.deb" >/dev/null

# --- vpinos-platform + vpinos-kernel (amd64 + arm64) -------------------
for arch in amd64 arm64; do
    st=$out/platform-$arch
    mkdir -p "$st/DEBIAN" "$st/usr/share/vpinos-platform/apt" "$st/usr/share/doc/vpinos-platform"
    cp $APT/vpinos-backports.list $APT/vpinos-backports.pref $APT/vpinos-nvidia-repo.pref \
        "$st/usr/share/vpinos-platform/apt/"
    cp vpinos-core/debian/copyright "$st/usr/share/doc/vpinos-platform/copyright"
    if [ $arch = amd64 ]; then
        mkdir -p "$st/usr/share/vpinos-platform/modprobe"
        cp vpinos-platform/modprobe/*.conf "$st/usr/share/vpinos-platform/modprobe/"
        pdeps="Depends: cuda-keyring"
        kdeps="vpinos-platform (>= $PLATFORM_VERSION), linux-image-$KABI, $MODPKG (= $MODVER)"
        kdesc="linux-image-$KABI and the NVIDIA $NVIDIA_VERSION modules prebuilt
 for it ($MODPKG)"
    else
        pdeps=""
        kdeps="vpinos-platform (>= $PLATFORM_VERSION), linux-image-arm64"
        kdesc="linux-image-arm64 from the frozen backports snapshot"
    fi
    cat > "$st/DEBIAN/control" <<EOF
Package: vpinos-platform
Version: $PLATFORM_VERSION
Architecture: $arch
Maintainer: Superhac <superhac007@gmail.com>
Section: admin
Priority: optional
${pdeps}
Homepage: https://github.com/vpinos/vpinos-packages
Description: VPinOS apt pins for the kernel and drivers
 Owns the apt pins that hold the kernel, Mesa, firmware and NVIDIA
 driver of every VPinOS cabinet in place: the frozen trixie-backports
 snapshot and the exact NVIDIA version. Deliberately has no
 version-locked dependencies, so a new version can always install and
 move the pins first; vpinos-kernel then follows under the new pins.
EOF
    sed -i "/^\$/d" "$st/DEBIAN/control"
    cp vpinos-platform/postinst "$st/DEBIAN/postinst"
    chmod 0755 "$st/DEBIAN/postinst"
    dpkg-deb --root-owner-group -Zxz --build "$st" "$out/vpinos-platform_${PLATFORM_VERSION}_${arch}.deb" >/dev/null

    st=$out/kernel-$arch
    mkdir -p "$st/DEBIAN" "$st/usr/share/doc/vpinos-kernel"
    cp vpinos-core/debian/copyright "$st/usr/share/doc/vpinos-kernel/copyright"
    cat > "$st/DEBIAN/control" <<EOF
Package: vpinos-kernel
Version: $PLATFORM_VERSION
Architecture: $arch
Maintainer: Superhac <superhac007@gmail.com>
Section: kernel
Priority: optional
Depends: $kdeps
Homepage: https://github.com/vpinos/vpinos-packages
Description: VPinOS kernel (and NVIDIA driver) selection
 Picks the exact kernel every VPinOS cabinet runs: $kdesc.
 A new version of this package is how a kernel or NVIDIA driver upgrade
 reaches cabinets. The previous kernel stays installed as a fallback in
 the GRUB menu.
EOF
    dpkg-deb --root-owner-group -Zxz --build "$st" "$out/vpinos-kernel_${PLATFORM_VERSION}_${arch}.deb" >/dev/null
done

cd $out
for deb in *.deb; do
    # no-changelog: these are built straight from versions.env, which is
    # their history.
    lintian --tag-display-limit 0 --suppress-tags no-changelog "$deb" 2>/dev/null | grep -E "^E:" || true
    sha256sum "$deb" > "$deb.sha256"
    cp "$deb" "$deb.sha256" /work/dist/
    chown "$HOST_UID:$HOST_GID" "/work/dist/$deb" "/work/dist/$deb.sha256"
    echo "built dist/$deb"
done
'
