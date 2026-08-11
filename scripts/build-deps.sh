#!/usr/bin/env bash
# Build static third-party dependencies into $PREFIX.
#
# Dependencies are grouped into batches; within a batch they build in parallel
# (xargs -P), and batches run in order so dependency edges are respected. The
# freetype -> harfbuzz -> fontconfig -> libass chain and the ogg -> vorbis ->
# theora chain force serialization across batches. Each dependency that is
# already built (matching stamp in common.sh) is skipped entirely.
#
# Usage: build-deps.sh [name1 name2 ...]   (default: every dep in the manifest)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=manifest.sh
source "${HERE}/manifest.sh"
# shellcheck source=common.sh
source "${HERE}/common.sh"
# shellcheck source=builder.sh
source "${HERE}/builder.sh"

ensure_dirs

# Build a single dependency by name (used by both selective and batch modes).
build_one() {
    local name="$1"
    local line
    line="$(find_dep_line "$name")" || { warn "unknown dependency: $name (skipped)"; return 0; }
    build_dep "$line"
}

if [ "$#" -gt 0 ]; then
    # Selective mode: build exactly the requested deps, in the given order.
    for name in "$@"; do
        build_one "$name"
    done
    log "requested dependencies built into ${PREFIX}"
    exit 0
fi

# Batches: each line is a space-separated group built in parallel; groups run
# sequentially. Order encodes dependency edges (see manifest.sh comments).
BATCHES=(
    # No intra-dependencies among these; they can all build in parallel.
    "zlib xz ogg lame opus freetype expat fribidi speex soxr twolame shine opencore-amr snappy xml2 rubberband jxl webp openjpeg zimg vidstab xvid x264 x265 openh264 kvazaar dav1d vpx aom svtav1"
    # vorbis needs ogg; harfbuzz needs freetype.
    "vorbis harfbuzz"
    # fontconfig needs freetype/expat/harfbuzz; theora needs ogg/vorbis.
    "fontconfig theora"
    # libass needs fontconfig/freetype/fribidi/harfbuzz.
    "libass"
)

# Build one dependency by name inside a parallel worker. Sources common.sh /
# builder.sh / manifest.sh so the worker has build_dep + find_dep_line + DEPS.
run_batch() {
    printf '%s\n' "$@" | xargs -P "${DEP_JOBS}" -I{} \
        bash -c 'source "'"${HERE}"'/common.sh"; source "'"${HERE}"'/builder.sh"; source "'"${HERE}"'/manifest.sh"; line="$(find_dep_line "$1")" || exit 1; build_dep "$line"' _ {}
}

for batch in "${BATCHES[@]}"; do
    # shellcheck disable=SC2086
    run_batch $batch
done

log "all dependencies built into ${PREFIX}"
