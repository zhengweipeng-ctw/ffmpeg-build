#!/usr/bin/env bash
# Linux build entry point for statically-linked FFmpeg.
#
# Runs the full build (all static dependencies + FFmpeg) and produces binaries
# in $OUT_DIR/bin. Designed to run both:
#   - inside the Ubuntu 24.04 build container (preferred), and
#   - natively on Ubuntu 24.04 once the Dockerfile apt deps are installed.
#
# It knows nothing about containers — it just builds. The container wrapper
# (build-in-container.sh on macOS) only provides the environment.
#
# Usage:
#   ./build.sh                 # full build (all deps + ffmpeg)
#   ./build.sh x264 x265       # build ONLY the listed deps, then stop
#                              # (skips ffmpeg, since a partial dep set would
#                              # fail ffmpeg's configure with missing --enable-libs)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -gt 0 ]; then
    log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
    log "selective build: dependencies only ($*)"
    "${HERE}/build-deps.sh" "$@"
    echo
    echo "Built selected dependencies into ${PREFIX:-/work/prefix}."
    echo "Run ./build.sh (no args) to build ffmpeg against all of them."
    exit 0
fi

"${HERE}/build-deps.sh"
"${HERE}/build-ffmpeg.sh"

echo
echo "Build complete. Binaries are in ${OUT_DIR:-/work/out}/bin"
