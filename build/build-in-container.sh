#!/usr/bin/env bash
# macOS helper: build the Linux/x86_64 FFmpeg binaries using a container.
#
# This script does NOT contain any build logic. It only provides the build
# environment (Ubuntu 24.04 image) and invokes the real Linux build entry
# point at scripts/build.sh inside the container. The actual build is
# identical to running scripts/build.sh natively on Linux.
#
# Produces static binaries under ./dist/out/bin and caches sources/deps
# under ./dist/. The binaries are Linux/x86_64 executables — copy them to
# your Linux server; they will not run natively on macOS.
#
# Usage:
#   ./build-in-container.sh              # full build (all deps + ffmpeg)
#   ./build-in-container.sh x264 x265    # build ONLY listed deps, then stop
#                                         (ffmpeg is skipped; a partial dep set
#                                         would fail its configure step)
set -euo pipefail

# This script lives in build/, so the repo root is one level up.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="ffmpeg-build:ubuntu24.04"
ARCH="amd64"   # config target is amd64/x86_64
# Memory for the build VM. Some dependencies (harfbuzz, aom) and the final
# static link of FFmpeg need more than the default ~1GB; bump with
# MEMORY=16384M if the link stage still OOMs.
MEMORY="${MEMORY:-8192M}"
# CPUs to grant the container. Apple Container defaults to ~half the host
# cores; set this to the host core count so parallel builds use all cores.
# Override with CPUS=8 etc. (docker accepts the same -c/--cpus flag shape via
# the cpus_flag below; we pass --cpus which both runtimes understand).
CPUS="${CPUS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 10)}"

# Pick a container runtime.
if command -v container >/dev/null 2>&1; then
    RUNTIME="container"
elif command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
else
    echo "ERROR: neither 'container' (Apple) nor 'docker' found." >&2
    exit 1
fi
echo "Using runtime: ${RUNTIME} (arch=${ARCH})"

mkdir -p "${ROOT}/dist/src" "${ROOT}/dist/obj" "${ROOT}/dist/prefix" "${ROOT}/dist/out" "${ROOT}/dist/ccache"

build_image() {
    echo "==> Building image ${IMAGE}"
    "${RUNTIME}" build --arch "${ARCH}" -t "${IMAGE}" -f "${ROOT}/build/Dockerfile" "${ROOT}"
}

# Build the mount arguments for the chosen runtime.
#   docker  : -v src:dst
#   container: --mount type=bind,source=src,target=dst
mount_args() {
    local mounts=(
        "${ROOT}/scripts:/opt/ffmpeg-build/scripts"
        "${ROOT}/dist/src:/work/src"
        "${ROOT}/dist/obj:/work/obj"
        "${ROOT}/dist/prefix:/work/prefix"
        "${ROOT}/dist/out:/work/out"
        "${ROOT}/dist/ccache:/ccache"
    )
    local m
    if [ "$RUNTIME" = "docker" ]; then
        for m in "${mounts[@]}"; do printf -- '-v %s\n' "$m"; done
    else
        for m in "${mounts[@]}"; do
            local src="${m%%:*}" dst="${m##*:}"
            printf -- '--mount type=bind,source=%s,target=%s\n' "$src" "$dst"
        done
    fi
}

run_build() {
    echo "==> Running build container (Linux entry point: scripts/build.sh)"
    local mem_flag="-m"
    [ "$RUNTIME" = "docker" ] && mem_flag="--memory"
    # shellcheck disable=SC2046
    "${RUNTIME}" run --rm --arch "${ARCH}" "${mem_flag}" "${MEMORY}" \
        --cpus "${CPUS}" \
        $(mount_args) \
        "${IMAGE}" "$@"
}

build_image
run_build "$@"

echo
echo "Done. Linux binaries (copy to your server):"
ls -lh "${ROOT}/dist/out/bin" 2>/dev/null || echo "  (none produced)"
