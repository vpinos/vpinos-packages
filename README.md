# vpinos-packages

Source for VPinOS's own Debian packages. These are the parts of
[VPinOS](https://github.com/vpinos/vpinos) that installed cabinets update
through apt instead of a reinstall.

| Package | What it is |
|---|---|
| `vpinos-core` | The console menu (`vpinos-menu`), the Hyprland kiosk launcher (`vpinos-launch`), the cabinet configuration tool (`vpinos-config`), their root helpers (`/usr/libexec/vpinos/`), sudoers rules, systemd units and login hooks, plus the default cabinet configuration |

Packages are built here, released as GitHub releases, and published by
[`vpinos/deb-repo`](https://github.com/vpinos/deb-repo), the single signed
apt repository every VPinOS image uses:

```
deb-package-builder  --+  (vpinball, vpinfe, vpxconfig, WiVRn, xrizer)
                       +-->  deb-repo (signs + publishes the apt repo)  -->  cabinets
vpinos-packages  ------+  (vpinos-core)
```

## Layout

```
vpinos-core/
├── debian/     control, changelog, rules, preinst/postinst/postrm
└── src/        files laid out exactly as installed
Dockerfile      trixie build image (debhelper, lintian, visudo)
build.sh        builds one package into dist/
.github/workflows/
├── build.yml   every push/PR: build, upload the .debs as artifacts
└── release.yml on a core-vX.Y.Z tag: build and attach .deb + .sha256 to a release
```

## Building

```sh
docker build -t vpinos-packages-builder .
./build.sh vpinos-core
```

This gives you `dist/vpinos-core_<version>_all.deb` and a `.deb.sha256`.
The build also checks the sudoers file with `visudo -cf` and runs lintian.

To try a change on a test cabinet, copy the .deb over and install it with
`sudo apt install ./vpinos-core_<version>_all.deb`. You don't need an ISO
rebuild.

To try it inside an ISO, copy the .deb into the VPinOS repo's
`config/includes.chroot/var/cache/vpinos-local-debs/` (gitignored) and do a
full clean ISO build. The `0100` hook installs it instead of the published
one.

## Rules `vpinos-core` follows

- **Cabinet config is placed once and never touched again.**
  `/etc/vpinos/hyprland.conf`, `hyprland-installer.conf`, `boot-mode`,
  `gpu-driver` and `~vpinos/.config/vpinfe/` (ini and theme) ship as
  defaults under `/usr/share/vpinos/defaults/`. `postinst` copies each one
  into place the first time only, recorded by a stamp in
  `/var/lib/vpinos-core/seeded/`. After that, no upgrade overwrites, merges
  or restores it, even if it was deleted. A default added in a later
  version is still placed once. Anything that must reach existing cabinets
  belongs in a script, not in a default.
- **It installs only on VPinOS 1.1+ images.** `preinst` refuses unless
  `/usr/share/vpinos/base-version` (written by the ISO) is at least
  `MIN_BASE`. Cabinets installed from 1.0.x ISOs share the apt repo but
  must reinstall. Packages from `deb-package-builder` must never depend on
  `vpinos-core`.

## Releasing a new vpinos-core

A release goes from a commit in this repo to every installed cabinet in
four steps: **change → changelog → tag → publish**. Cabinets only pick up a
package whose version is **higher** than the one they have, so every
release needs a new version number.

### 1. Make the change

Edit files under `vpinos-core/src/`, which is laid out exactly as installed:

| To change | Edit |
|---|---|
| The console menu | `src/usr/bin/vpinos-menu` |
| The Hyprland launcher | `src/usr/bin/vpinos-launch` |
| The cabinet configuration tool | `src/usr/bin/vpinos-config`, `src/usr/share/vpinos/config-web/` |
| Root helpers (run via sudo) | `src/usr/libexec/vpinos/*.sh` |
| Passwordless sudo rules | `src/etc/sudoers.d/vpinos-core` |
| Login auto-launch | `src/etc/profile.d/vpinos-menu.sh` |
| SSH login banner | `src/etc/update-motd.d/00-vpinos-banner`, `src/usr/libexec/vpinos/vpinos-banner.sh` |
| systemd units / drop-ins | `src/usr/lib/systemd/system/` (enable/start behaviour is in `debian/rules`) |
| A new Debian package the scripts need | `Depends:` in `debian/control` (installed automatically on update) |

Things to know:

- **Default cabinet config only reaches new installs.** The files under
  `src/usr/share/vpinos/defaults/` (Hyprland configs, `boot-mode`,
  `gpu-driver`, `vpinfe.ini`, the Revolution theme) are copied into place
  once and never touched again. Editing them changes nothing on existing
  cabinets. If a change must reach existing cabinets, do it in a script
  (for example the launcher), not in a default.
- **A new root helper needs three things:** the script in
  `src/usr/libexec/vpinos/`, a sudoers line naming its full path, and the
  call from the menu using that same path with `sudo`.
- **A sudoers mistake can lock the kiosk out of sudo.** The build checks the
  file with `visudo -cf`; don't skip a failing build.
- **If a change needs a newer ISO** (kernel, installer, base OS), raise
  `MIN_BASE` in `debian/preinst` to that image's `base-version`. Older
  cabinets then get a "reinstall" message instead of a broken update.

### 2. Build and try it

```sh
docker build -t vpinos-packages-builder .   # once
./build.sh vpinos-core
```

Fix anything the build reports. lintian warnings about missing man pages
and `chown -R` are known and fine. To try it on a test cabinet, copy the
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

The release alone doesn't reach cabinets. Publish it from `vpinos/deb-repo`:

- **Actions → Update apt repository → Run workflow**, then set **Build repo
  to publish from** to `vpinos/vpinos-packages` (the default is
  `deb-package-builder`, which publishes the wrong thing) and **Release tag**
  to `core-v1.1.2`.
- Or: `gh workflow run update-repo.yml -R vpinos/deb-repo -f source_repo=vpinos/vpinos-packages -f source_release_tag=core-v1.1.2`
  (add `-f dry_run=true` to build and sign without uploading).

Packages from `deb-package-builder` (vpinball, vpinfe, ...) are kept.

### 6. Check it

- The run log shows `SOURCE_REPO: vpinos/vpinos-packages` and
  `vpinos-core_1.1.2_all.deb: OK`.
- The published index has the new version:
  `curl -fsSL https://github.com/vpinos/deb-repo/releases/download/apt/Packages | grep -A1 '^Package: vpinos-core'`
- On a cabinet: **Menu → 4) Update VPinOS** (or
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
- **A bad version reached cabinets**: fix it and release a higher version.
  There's no way to pull a published version back from cabinets.

### Release checklist

1. Change under `vpinos-core/src/` (and `debian/control` if it needs a new dependency).
2. `./build.sh vpinos-core` passes.
3. New top entry in `vpinos-core/debian/changelog` with a higher version.
4. Commit and push `master`.
5. `git tag core-v<version>` and push the tag; **Release package** goes green.
6. deb-repo **Update apt repository** with `source_repo=vpinos/vpinos-packages` and the tag.
7. Check the `Packages` index, then update a test cabinet.
