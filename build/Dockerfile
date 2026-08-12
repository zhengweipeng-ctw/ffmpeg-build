FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Toolchain and build systems only — every library ffmpeg links is built from
# source into $PREFIX, so nothing here is linked into the binaries.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ccache \
        cmake \
        meson \
        ninja-build \
        nasm \
        yasm \
        pkg-config \
        git \
        curl \
        ca-certificates \
        xz-utils \
        bzip2 \
        file \
        autoconf \
        automake \
        autoconf-archive \
        libtool \
        gettext \
        autopoint \
        libnuma-dev \
        gperf \
        gawk \
        perl \
        python3 \
        unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
COPY scripts/ /opt/ffmpeg-build/scripts/
RUN chmod +x /opt/ffmpeg-build/scripts/*.sh

# ccache: cache dir is mounted from the host (see build-in-container.sh) so
# compiled objects survive container teardown and speed up rebuilds.
ENV CCACHE_DIR=/ccache
ENV CCACHE_MAXSIZE=10G
RUN mkdir -p /ccache && chmod 777 /ccache

ENV WORK_DIR=/work
ENTRYPOINT ["/opt/ffmpeg-build/scripts/build.sh"]
