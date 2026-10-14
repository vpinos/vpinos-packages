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

## Releasing

1. Add a changelog entry: `vpinos-core/debian/changelog` (new version,
   for example `1.1.1`).
2. Tag it `core-v<version>` (for example `core-v1.1.1`) and push the tag.
   `release.yml` checks that the tag matches the changelog, then builds the
   package and creates the GitHub release.
3. In `vpinos/deb-repo`, run **Update apt repository** with
   `source_repo=vpinos/vpinos-packages` and that tag.

Cabinets get it on their next **Menu → Update VPinOS** or
`sudo apt update && sudo apt upgrade`.

Versioning: `vpinos-core` carries the user-facing VPinOS version (1.1.0,
1.1.1, ...). The ISO's version only moves when a new ISO is cut.
