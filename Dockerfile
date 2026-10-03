# The kernel builder: the packages of Kata's kernel builder
# (tools/packaging/static-build/kernel/Dockerfile at KATA_VERSION) on the
# same Ubuntu release, so the compiler is the one Kata's config was
# generated with (the config's CONFIG_CC_VERSION_TEXT matches Kata's).
# zstd packs the artifact.
#
# The base is pinned by digest, and the packages that make the kernel's
# and the artifact's bytes are pinned by version (pahole itself, not just
# dwarves, which only depends on it): when Ubuntu replaces one
# of these in jammy-updates, the builder stops building rather than build
# different bytes for the same release. Moving a pin is a change to the
# kernel (README.md, "Following Kata"). build.sh records the toolchain's
# versions in the artifact's buildinfo.
FROM ubuntu:22.04@sha256:b1066385161d28ddf6bc7e7b28a9170eec11484c821d1a5150d176cbde41d7f7
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
	    bc=1.07.1-3build1 \
	    binutils=2.38-4ubuntu2.12 \
	    bison=2:3.8.2+dfsg-1ubuntu0.22.04.1 \
	    build-essential \
	    ca-certificates \
	    cpio \
	    cpp-11=11.4.0-1ubuntu1~22.04.3 \
	    curl \
	    dwarves=1.25-0ubuntu1~22.04.2 \
	    flex=2.6.4-8build2 \
	    gcc-11=11.4.0-1ubuntu1~22.04.3 \
	    gettext \
	    git \
	    kmod \
	    libdw-dev=0.186-1ubuntu0.1 \
	    libelf-dev=0.186-1ubuntu0.1 \
	    libssl-dev \
	    make=4.3-4.1build1 \
	    pahole=1.25-0ubuntu1~22.04.2 \
	    patch \
	    python3 \
	    rsync \
	    zstd=1.4.8+dfsg-3build1 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
