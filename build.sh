#!/bin/sh
# Builds one package from this repo into dist/, inside the
# vpinos-packages-builder image (see Dockerfile):
#
#   docker build -t vpinos-packages-builder .
#   ./build.sh vpinos-core
#
# Produces dist/<pkg>_<version>_<arch>.deb plus a .deb.sha256 next to
# it -- the shape deb-repo's update-repo.sh consumes from a release.
set -e

pkg=${1:?usage: build.sh <package-dir>}
[ -d "$pkg/debian" ] || { echo "no such package: $pkg" >&2; exit 1; }

mkdir -p dist
docker run --rm -v "$PWD:/work" -w /work -e PKG="$pkg" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    vpinos-packages-builder sh -ec '
        # Build from a copy: dpkg-buildpackage writes its output next to
        # the source dir and leaves debian/ build state behind.
        tmp=$(mktemp -d)
        cp -a "$PKG" "$tmp/"
        cd "$tmp/$PKG"
        if [ -d src/etc/sudoers.d ]; then
            for f in src/etc/sudoers.d/*; do visudo -cf "$f"; done
        fi
        dpkg-buildpackage -b -us -uc
        cd "$tmp"
        for deb in *.deb; do
            lintian --tag-display-limit 0 "$deb" || true
            sha256sum "$deb" > "$deb.sha256"
            cp "$deb" "$deb.sha256" /work/dist/
            chown "$HOST_UID:$HOST_GID" "/work/dist/$deb" "/work/dist/$deb.sha256"
            echo "built dist/$deb"
        done
    '
