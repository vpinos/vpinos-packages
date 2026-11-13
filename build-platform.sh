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
#   vpinos-nvidia-legacy (amd64)               the NVIDIA legacy (580) userspace,
#                                              graphics only, in its own prefix
#                                              /usr/lib/vpinos/nvidia-legacy
#   vpinos-nvidia-legacy-modules-<KERNEL_ABI>-amd64
#                                              the closed 580 kernel modules for
#                                              that kernel, under the same prefix
#
# The legacy driver (Maxwell/Pascal/Volta, NVIDIA_LEGACY_* in versions.env)
# comes from NVIDIA's .run installer, not apt: NVIDIA's debian13 repo has
# no 580. It is installed beside the current driver, never over it, and
# nothing of it lands in the system's library, glvnd, Vulkan, GBM or
# /lib/modules paths; vpinos-gpu-driver.sh insmods it and vpinos-launch
# points the session at it when a cabinet picks "NVIDIA legacy". See
# notes/nvidia-legacy-plan.md in the VPinOS workspace.
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
LEGPKG="vpinos-nvidia-legacy"
LEGVER="${NVIDIA_LEGACY_VERSION}-${NVIDIA_LEGACY_REVISION}"
LEGMODPKG="vpinos-nvidia-legacy-modules-${KABI}"
LEGMODVER="${PLATFORM_VERSION}+nv${NVIDIA_LEGACY_VERSION}"
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
case "$NVIDIA_LEGACY_SHA256" in
    [0-9a-f]*) [ ${#NVIDIA_LEGACY_SHA256} -eq 64 ] || { echo "E: NVIDIA_LEGACY_SHA256 isn't a sha256" >&2; exit 1; } ;;
    *) echo "E: NVIDIA_LEGACY_SHA256 isn't a sha256" >&2; exit 1 ;;
esac

mkdir -p dist
docker run --rm -v "$PWD:/work" -w /work \
    -e KABI="$KABI" -e MODPKG="$MODPKG" -e MODVER="$MODVER" \
    -e PLATFORM_VERSION="$PLATFORM_VERSION" -e NVIDIA_VERSION="$NVIDIA_VERSION" \
    -e NVIDIA_DEB_VERSION="$NVIDIA_DEB_VERSION" -e NVIDIA_USERSPACE="$NVIDIA_USERSPACE" \
    -e NVIDIA_LEGACY_VERSION="$NVIDIA_LEGACY_VERSION" -e NVIDIA_LEGACY_SHA256="$NVIDIA_LEGACY_SHA256" \
    -e LEGPKG="$LEGPKG" -e LEGVER="$LEGVER" -e LEGMODPKG="$LEGMODPKG" -e LEGMODVER="$LEGMODVER" \
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

# --- the legacy (580) driver, from the NVIDIA .run installer -----------
# Closed kernel module: the open one has no Maxwell/Pascal/Volta support.
# Debian splits the headers: SYSSRC must be the -common tree (the headers
# themselves), SYSOUT the -amd64 one (.config, generated files). With
# both on -amd64, the NVIDIA conftest misdetects nearly every header and the
# build dies on "stdarg.h: No such file or directory".
nvl=/tmp/nvl
nvrun=/tmp/NVIDIA-Linux-x86_64-$NVIDIA_LEGACY_VERSION.run
curl -fsSL -o "$nvrun" "https://download.nvidia.com/XFree86/Linux-x86_64/$NVIDIA_LEGACY_VERSION/NVIDIA-Linux-x86_64-$NVIDIA_LEGACY_VERSION.run"
echo "$NVIDIA_LEGACY_SHA256  $nvrun" | sha256sum -c --quiet - \
    || { echo "E: $(basename "$nvrun") sha256 != NVIDIA_LEGACY_SHA256"; exit 1; }
sh "$nvrun" --extract-only --target "$nvl" >/dev/null
make -C "$nvl/kernel" -j"$(nproc)" modules \
    SYSSRC="/usr/src/linux-headers-${KABI%-amd64}-common" SYSOUT="/usr/src/linux-headers-$KABI" \
    >/tmp/make-legacy.log 2>&1 \
    || { grep -nE "error:|Error [0-9]" /tmp/make-legacy.log | head -30; echo "E: legacy $NVIDIA_LEGACY_VERSION modules failed to build for $KABI"; exit 1; }
legmods="nvidia nvidia-modeset nvidia-drm nvidia-uvm"
for m in $legmods; do
    ko="$nvl/kernel/$m.ko"
    [ -f "$ko" ] || { echo "E: legacy build produced no $m.ko"; exit 1; }
    vm=$(modinfo -F vermagic "$ko" | cut -d" " -f1)
    [ "$vm" = "$KABI" ] || { echo "E: legacy $m.ko vermagic $vm != $KABI"; exit 1; }
    mv=$(modinfo -F version "$ko")
    [ "$mv" = "$NVIDIA_LEGACY_VERSION" ] || { echo "E: legacy $m.ko version $mv != $NVIDIA_LEGACY_VERSION"; exit 1; }
done
# license=NVIDIA proves the closed module was built (the open one says
# "Dual MIT/GPL" and would never drive the cards this is for).
[ "$(modinfo -F license "$nvl/kernel/nvidia.ko")" = NVIDIA ] \
    || { echo "E: legacy nvidia.ko is not the closed module"; exit 1; }
for m in $legmods; do
    strip --strip-debug "$nvl/kernel/$m.ko"
    # Same xz settings the kernel uses for its own .ko.xz.
    xz -f --check=crc32 --lzma2=dict=1MiB "$nvl/kernel/$m.ko"
done
echo "I: built legacy $NVIDIA_LEGACY_VERSION for $KABI: $(cd "$nvl/kernel" && ls *.ko.xz | tr "\n" " ")"

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

# --- vpinos-nvidia-legacy (the 580 userspace) ---------------------------
# Graphics only: GLX/EGL/GLES/Vulkan, the GBM backend and nvidia-smi. No
# CUDA/NVENC (VR encoding stays on the current driver), no ray tracing,
# OptiX, NGX or OpenCL -- the ISO has no room (notes/nvidia-legacy-plan.md
# 6.1). Also not libnvidia-present (66 MB: the "Smooth Motion" Vulkan
# layer, RTX 40 and newer only, off unless NVPRESENT_ENABLE_SMOOTH_MOTION
# is set) or libnvidia-wayland-client (nvidia-settings only). All under one prefix, so nothing collides with the current
# driver: the vendor .json files live there too, never in the system
# glvnd/Vulkan dirs, and only vpinos-launch (in nvidia-legacy mode) points
# a session at them. The EGL platform libraries (egl-gbm, egl-wayland2,
# egl-xcb, egl-xlib) are the system ones: they are standalone and not tied
# to a driver version.
L=/usr/lib/vpinos/nvidia-legacy
st=$out/legacy
mkdir -p "$st/DEBIAN" "$st$L/lib/gbm" "$st$L/share/egl_vendor.d" "$st$L/share/vulkan/icd.d" \
    "$st$L/bin" "$st/usr/share/doc/$LEGPKG"
V=$NVIDIA_LEGACY_VERSION
for f in libGLX_nvidia libEGL_nvidia libGLESv2_nvidia libGLESv1_CM_nvidia libnvidia-allocator \
         libnvidia-glcore libnvidia-eglcore libnvidia-glsi libnvidia-tls libnvidia-glvkspirv \
         libnvidia-gpucomp libnvidia-cfg libnvidia-ml; do
    [ -f "$nvl/$f.so.$V" ] || { echo "E: $f.so.$V missing from the .run"; exit 1; }
    install -m 0644 "$nvl/$f.so.$V" "$st$L/lib/"
    soname=$(objdump -p "$nvl/$f.so.$V" | awk "/SONAME/{print \$2}")
    [ -n "$soname" ] && [ "$soname" != "$f.so.$V" ] && ln -s "$f.so.$V" "$st$L/lib/$soname"
done
# libnvidia-api ships under its soname only.
install -m 0644 "$nvl/libnvidia-api.so.1" "$st$L/lib/"
# Mesa GBM loads <GBM_BACKENDS_PATH>/<GBM_BACKEND>_gbm.so.
ln -s ../libnvidia-allocator.so.1 "$st$L/lib/gbm/nvidia-drm_gbm.so"
cat > "$st$L/share/egl_vendor.d/10_nvidia_legacy.json" <<EOF
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "$L/lib/libEGL_nvidia.so.0"
    }
}
EOF
sed "s|\"library_path\": *\"libGLX_nvidia.so.0\"|\"library_path\": \"$L/lib/libGLX_nvidia.so.0\"|" \
    "$nvl/nvidia_icd.json" > "$st$L/share/vulkan/icd.d/nvidia_legacy_icd.json"
grep -q "\"$L/lib/libGLX_nvidia.so.0\"" "$st$L/share/vulkan/icd.d/nvidia_legacy_icd.json" \
    || { echo "E: could not point nvidia_icd.json at $L"; exit 1; }
install -m 0755 "$nvl/nvidia-smi" "$st$L/bin/nvidia-smi.bin"
cat > "$st$L/bin/nvidia-smi" <<EOF
#!/bin/sh
# nvidia-smi of the legacy driver, against its own libnvidia-ml.
LD_LIBRARY_PATH=$L/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH} exec $L/bin/nvidia-smi.bin "\$@"
EOF
chmod 0755 "$st$L/bin/nvidia-smi"
install -m 0644 "$nvl/LICENSE" "$st/usr/share/doc/$LEGPKG/copyright"
install -m 0644 "$nvl/supported-gpus/supported-gpus.json" "$st$L/share/supported-gpus.json"
cat > "$st/DEBIAN/control" <<EOF
Package: $LEGPKG
Version: $LEGVER
Architecture: amd64
Maintainer: Superhac <superhac007@gmail.com>
Section: non-free/libs
Priority: optional
Depends: libc6, libglvnd0, libgbm1, libnvidia-egl-gbm1, libnvidia-egl-wayland21 | libnvidia-egl-wayland1
Homepage: https://github.com/vpinos/vpinos-packages
Description: NVIDIA legacy driver $V userspace (VPinOS, Maxwell/Pascal/Volta)
 The OpenGL, EGL, GLES and Vulkan libraries and nvidia-smi from NVIDIA
 $V, the last driver branch for GTX 750 to 10-series and Titan V cards.
 Installed under $L only, beside the current NVIDIA driver; a session
 uses it only when Setup > GPU Driver is set to NVIDIA legacy.
 Unmodified files from NVIDIA-Linux-x86_64-$V.run.
EOF
dpkg-deb --root-owner-group -Zxz --build "$st" "$out/${LEGPKG}_${LEGVER}_amd64.deb" >/dev/null

# --- vpinos-nvidia-legacy-modules-<kabi> --------------------------------
# Outside /lib/modules on purpose: depmod and udev must never see a second
# "nvidia" module. vpinos-gpu-driver.sh insmods these by path. No
# postinst: nothing to depmod, nothing in the initramfs.
st=$out/legacy-modules
mkdir -p "$st/DEBIAN" "$st$L/modules/$KABI" "$st/usr/share/doc/$LEGMODPKG"
for m in $legmods; do install -m 0644 "$nvl/kernel/$m.ko.xz" "$st$L/modules/$KABI/"; done
install -m 0644 "$nvl/LICENSE" "$st/usr/share/doc/$LEGMODPKG/copyright"
cat > "$st/DEBIAN/control" <<EOF
Package: $LEGMODPKG
Version: $LEGMODVER
Architecture: amd64
Maintainer: Superhac <superhac007@gmail.com>
Section: non-free/kernel
Priority: optional
Depends: linux-image-$KABI, $LEGPKG (= $LEGVER)
Homepage: https://github.com/vpinos/vpinos-packages
Description: NVIDIA legacy $V kernel modules for Linux $KABI (VPinOS)
 The closed NVIDIA kernel modules (nvidia, nvidia-modeset, nvidia-drm,
 nvidia-uvm) from NVIDIA $V, the last branch for Maxwell, Pascal and
 Volta cards, prebuilt for exactly linux-image-$KABI $kver. Installed
 under $L/modules, outside /lib/modules, and loaded only when Setup > GPU
 Driver is set to NVIDIA legacy.
EOF
dpkg-deb --root-owner-group -Zxz --build "$st" "$out/${LEGMODPKG}_${LEGMODVER}_amd64.deb" >/dev/null

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
        kdeps="vpinos-platform (>= $PLATFORM_VERSION), linux-image-$KABI, $MODPKG (= $MODVER), $LEGMODPKG (= $LEGMODVER)"
        kdesc="linux-image-$KABI and the NVIDIA $NVIDIA_VERSION modules prebuilt
 for it ($MODPKG), plus the NVIDIA legacy $NVIDIA_LEGACY_VERSION modules
 ($LEGMODPKG)"
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
