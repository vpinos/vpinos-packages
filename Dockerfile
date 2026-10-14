# Build image for the VPinOS packages: Debian trixie, same as the image
# they install into, with the Debian packaging toolchain. sudo is only
# here for visudo, to check the sudoers file at build time.
FROM debian:trixie

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    debhelper \
    lintian \
    sudo \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
