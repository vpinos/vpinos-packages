# vpinos-packages

Source for VPinOS's own Debian packages. These are the parts of
[VPinOS](https://github.com/vpinos/vpinos) that VPinOS installations update
through apt instead of a reinstall.

| Package | What it is |
|---|---|
| `vpinos-core` | The console menu (`vpinos-menu`), the Hyprland kiosk launcher (`vpinos-launch`), the VPinOS configuration tool (`vpinos-config`), their root helpers (`/usr/libexec/vpinos/`), sudoers rules, systemd units and login hooks, plus the default system configuration. Depends on `vpinos-platform` and `vpinos-kernel` |
| `vpinos-platform` | The apt pins that hold the kernel, Mesa, firmware and NVIDIA driver in place (frozen backports snapshot, exact NVIDIA version), plus on amd64 the NVIDIA modprobe settings. No version-locked dependencies (see [Upgrading the kernel or NVIDIA driver](#upgrading-the-kernel-or-nvidia-driver)) |
| `vpinos-kernel` | The exact kernel, plus on amd64 the NVIDIA modules built for it |
| `vpinos-nvidia-modules-<kernel>` | amd64 only: the open NVIDIA kernel modules prebuilt for exactly that kernel, holding the NVIDIA userspace at exactly the same version. VPinOS installations never need DKMS or a compiler |

Packages are built here, released as GitHub releases, and published by
[`vpinos/deb-repo`](https://github.com/vpinos/deb-repo), the single signed
apt repository every VPinOS image uses:

```
deb-package-builder  --+  (vpinball, vpinfe, vpxconfig, WiVRn, xrizer)
                       +-->  deb-repo (signs + publishes the apt repo)  -->  VPinOS installations
vpinos-packages  ------+  (vpinos-core, vpinos-platform, vpinos-kernel, vpinos-nvidia-modules)
```

## Layout

```
vpinos-core/
├── debian/        control, changelog, rules, preinst/postinst/postrm
└── src/           files laid out exactly as installed
versions.env       kernel, snapshot and NVIDIA versions: the one place they're set
vpinos-platform/
├── apt/           the apt pins VPinOS installations get (must agree with versions.env)
├── modprobe/      the NVIDIA modprobe settings (amd64)
└── postinst       writes the pins + modprobe files on every install/upgrade
Dockerfile         trixie build image (debhelper, lintian, visudo)
build.sh           builds vpinos-core into dist/
build-platform.sh  builds vpinos-platform, vpinos-kernel and the NVIDIA modules into dist/
.github/workflows/
├── build.yml      every push/PR: build everything, upload the .debs as artifacts
└── release.yml    on a core-vX.Y.Z or platform-vX.Y.Z tag: build and attach the .debs to a release
```

## Building

```sh
docker build -t vpinos-packages-builder .
./build.sh vpinos-core
./build-platform.sh          # kernel/NVIDIA packages; about 3 minutes, needs network
```

This gives you `dist/vpinos-core_<version>_all.deb` and a `.deb.sha256`, and
the platform, kernel and NVIDIA module debs.
The build also checks the sudoers file with `visudo -cf` and runs lintian.

To try a change on a test machine, copy the .deb over and install it with
`sudo apt install ./vpinos-core_<version>_all.deb`. You don't need an ISO
rebuild.

To try it inside an ISO, copy the .deb into the VPinOS repo's
`config/includes.chroot/var/cache/vpinos-local-debs/` (gitignored) and do a
full clean ISO build. The `0100` hook installs it instead of the published
one.

## Rules `vpinos-core` follows

- **System config is placed once and never touched again.**
  `/etc/vpinos/hyprland.conf`, `hyprland-installer.conf`, `boot-mode`,
  `gpu-driver` and `~vpinos/.config/vpinfe/` (ini and theme) ship as
  defaults under `/usr/share/vpinos/defaults/`. `postinst` copies each one
  into place the first time only, recorded by a stamp in
  `/var/lib/vpinos-core/seeded/`. After that, no upgrade overwrites, merges
  or restores it, even if it was deleted. A default added in a later
  version is still placed once. Anything that must reach existing installations
  belongs in a script, not in a default.
- **It installs only on VPinOS 1.1+ images.** `preinst` refuses unless
  `/usr/share/vpinos/base-version` (written by the ISO) is at least
  `MIN_BASE`. Systems installed from 1.0.x ISOs share the apt repo but
  must reinstall. Packages from `deb-package-builder` must never depend on
  `vpinos-core`.

## Releasing a new vpinos-core

A release goes from a commit in this repo to every VPinOS installation in
four steps: **change → changelog → tag → publish**. VPinOS installations only pick up a
package whose version is **higher** than the one they have, so every
release needs a new version number.

### 1. Make the change

Edit files under `vpinos-core/src/`, which is laid out exactly as installed:

| To change | Edit |
|---|---|
| The console menu | `src/usr/bin/vpinos-menu` |
| The Hyprland launcher | `src/usr/bin/vpinos-launch` |
| The VPinOS configuration tool | `src/usr/bin/vpinos-config`, `src/usr/share/vpinos/config-web/` |
| Root helpers (run via sudo) | `src/usr/libexec/vpinos/*.sh` |
| Passwordless sudo rules | `src/etc/sudoers.d/vpinos-core` |
| Login auto-launch | `src/etc/profile.d/vpinos-menu.sh` |
| SSH login banner | `src/etc/update-motd.d/00-vpinos-banner`, `src/usr/libexec/vpinos/vpinos-banner.sh` |
| systemd units / drop-ins | `src/usr/lib/systemd/system/` (enable/start behaviour is in `debian/rules`) |
| A new Debian package the scripts need | `Depends:` in `debian/control` (installed automatically on update) |

Things to know:

- **Default system config only reaches new installs.** The files under
  `src/usr/share/vpinos/defaults/` (Hyprland configs, `boot-mode`,
  `gpu-driver`, `vpinfe.ini`, the Revolution theme) are copied into place
  once and never touched again. Editing them changes nothing on existing
  VPinOS installations. If a change must reach existing installations, do it in a script
  (for example the launcher), not in a default.
- **A new root helper needs three things:** the script in
  `src/usr/libexec/vpinos/`, a sudoers line naming its full path, and the
  call from the menu using that same path with `sudo`.
- **A sudoers mistake can lock the kiosk out of sudo.** The build checks the
  file with `visudo -cf`; don't skip a failing build.
- **If a change needs a newer ISO** (kernel, installer, base OS), raise
  `MIN_BASE` in `debian/preinst` to that image's `base-version`. Older
  VPinOS installations then get a "reinstall" message instead of a broken update.

### 2. Build and try it

```sh
docker build -t vpinos-packages-builder .   # once
./build.sh vpinos-core
```

Fix anything the build reports. lintian warnings about missing man pages
and `chown -R` are known and fine. To try it on a test machine, copy the
.deb from `dist/` over and run `sudo apt install ./vpinos-core_<version>_all.deb`.

### 3. Add a changelog entry (this sets the version)

The version comes **only** from the top entry of
`vpinos-core/debian/changelog`. Add a new entry at the top. Copy the
layout exactly; the blank lines and the two spaces before the date
matter:

```
vpinos-core (1.1.2) trixie; urgency=medium

  * Short description of what changed.

 -- Superhac <superhac007@gmail.com>  Wed, 14 Oct 2026 16:00:00 -0500
```

(`date -R` prints the date in the right format.)

Versioning:
- `1.1.x` for normal updates (fixes, menu changes, new options).
- Never reuse a version that has been published, even if the old release
  was broken. Bump again instead.
- `vpinos-core` is the VPinOS version users see (menu header, SSH banner,
  System Info). The ISO's own version (`os-release` in `vpinos/vpinos`) only
  moves when a new ISO is cut.

### 4. Commit, push, tag

```sh
git add -A
git commit -m "vpinos-core 1.1.2: <what changed>"
git push origin master

git tag core-v1.1.2          # must be core-v + exactly the changelog version
git push origin core-v1.1.2
```

The tag push runs **Release package** (`release.yml`). It checks that the tag
matches the changelog, builds the package, and creates a GitHub release
named `vpinos-core 1.1.2` with the `.deb` and `.deb.sha256`. **Commit the
changelog before tagging:** the tag captures whatever commit it points at.

### 5. Publish to the apt repo

The release alone doesn't reach VPinOS installations. deb-repo's workflow doesn't build
anything: it copies the debs from this release into the apt repo. Wait for
**Release package** to go green, then publish from `vpinos/deb-repo`:

- **Actions → Update apt repository → Run workflow**, then set **Build repo
  to publish from** to `vpinos/vpinos-packages` (the default is
  `deb-package-builder`, which publishes the wrong thing) and **Release tag**
  to `core-v1.1.2`. Always type the tag: blank means "newest release in the
  repo", which is wrong as soon as core and platform releases are mixed.
- Or: `gh workflow run update-repo.yml -R vpinos/deb-repo -f source_repo=vpinos/vpinos-packages -f source_release_tag=core-v1.1.2`
  (add `-f dry_run=true` to build and sign without uploading).

Packages from `deb-package-builder` (vpinball, vpinfe, ...) are kept.

### 6. Check it

- The run log shows `SOURCE_REPO: vpinos/vpinos-packages` and
  `vpinos-core_1.1.2_all.deb: OK`.
- The published index has the new version:
  `curl -fsSL https://github.com/vpinos/deb-repo/releases/download/apt/Packages | grep -A1 '^Package: vpinos-core'`
- On a VPinOS installation: **Menu → 4) Update VPinOS** (or
  `sudo apt update && sudo apt upgrade`). The menu header should show the new
  version.

### If something goes wrong

- **"Tag core-vX does not match vpinos-core/debian/changelog (Y)"**: the
  changelog wasn't updated (or committed) before tagging. No release was
  created, so the tag can be moved safely. Fix the changelog, commit and push,
  then:
  ```sh
  git tag -d core-v1.1.2
  git push origin :refs/tags/core-v1.1.2
  git tag core-v1.1.2
  git push origin core-v1.1.2
  ```
  Only do this when the release was **not** created. Once a version has been
  released or published, bump the version instead.
- **Published the wrong thing to deb-repo**: just run it again with the right
  `source_repo` and tag. Each run keeps every package already in the repo and
  only adds or replaces from the release you name.
- **A bad version reached VPinOS installations**: fix it and release a higher version.
  There's no way to pull a published version back from VPinOS installations.

### Release checklist (vpinos-core)

1. Change under `vpinos-core/src/` (and `debian/control` if it needs a new dependency).
2. `./build.sh vpinos-core` passes.
3. New top entry in `vpinos-core/debian/changelog` with a higher version.
4. Commit and push `master`.
5. `git tag core-v<version>` and push the tag; **Release package** goes green.
6. deb-repo **Update apt repository** with `source_repo=vpinos/vpinos-packages` and the tag.
7. Check the `Packages` index, then update a test machine.

## Upgrading the kernel or NVIDIA driver

The kernel and the NVIDIA driver reach VPinOS installations through apt too. Everything
is set in `versions.env`. The full procedure, with how to find available
versions and how to test, is in the VPinOS repo's
`notes/skills/upgrade-kernel-nvidia/SKILL.md`. In short:

1. **Edit `versions.env`.** Always bump `PLATFORM_VERSION`, even for a
   rollback. Change `SNAPSHOT` + `KERNEL_ABI` for a kernel, or
   `NVIDIA_VERSION` + `NVIDIA_DEB_VERSION` for a driver.
2. **Edit the matching apt files:** `vpinos-platform/apt/vpinos-backports.list`
   (snapshot date) and `vpinos-platform/apt/vpinos-nvidia-repo.pref`
   (`Pin: version <NVIDIA_VERSION>-*`).
3. **`./build-platform.sh`.** It refuses to build if step 1 and step 2
   disagree, builds the NVIDIA modules against the exact kernel, and warns
   if NVIDIA's userspace package list changed (add new names to
   `NVIDIA_USERSPACE`).
4. **Test** on a test machine (`sudo apt install ./…deb`, reboot, check
   Setup → GPU Driver both ways) or in a local ISO.
5. **Mirror into the ISO repo:** copy `vpinos-platform/apt/*` to
   `~/repos/vpinos/vpinos/config/archives/` and set the kernel in
   `config/package-lists/vpinos.list.chroot`. The ISO build refuses to run if
   these differ from `vpinos-platform`.
6. **Release:** commit, push, then `git tag platform-v<PLATFORM_VERSION>` and
   push the tag. One release holds all five debs. Publish it through deb-repo
   with `source_repo=vpinos/vpinos-packages` and that tag.
7. **VPinOS installations:** Menu → Update VPinOS, then reboot. The old kernel stays in
   GRUB as a fallback.

**Don't remove or reorder the first record in
`vpinos-platform/apt/vpinos-nvidia-repo.pref`.** It makes `nvidia-driver`,
`nvidia-kernel-open-dkms` and `nvidia-kernel-dkms` uninstallable (priority
−1). NVIDIA's own userspace *recommends* them, so without it every install
would pull in DKMS and a compiler, and DKMS would overwrite the packaged
modules. That's the bug `vpinos-platform` 1.0.1 fixed. It has to stay first
because apt uses the first matching record. `build-platform.sh` lifts it only
inside its own build container. When testing, simulate installs **with**
recommends (`apt-get install -s`), not only `--no-install-recommends`.

**Why there are two packages, and why updating takes two apt rounds.** apt
picks versions using the pins already on the system. A new kernel is in a
snapshot the system doesn't list yet, and a new driver is blocked by the
old exact-version pin. So `vpinos-platform` (the pins, with nothing that can
block it) upgrades first and rewrites them. Then, after a fresh
`apt update`, `vpinos-kernel` (the kernel, modules and NVIDIA userspace)
follows under the new pins. Menu → Update VPinOS always runs both rounds.
Anyone updating by hand runs `sudo apt update && sudo apt upgrade`
**twice** after a kernel/driver release. Put that in the release notes.
