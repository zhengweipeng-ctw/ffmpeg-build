# shellcheck shell=bash
# Shared helpers for the FFmpeg static build system (Linux target).

set -euo pipefail

# Production target is Linux (fully static).
IS_LINUX=1

# CPU count.
cpu_count() {
    if command -v nproc >/dev/null 2>&1; then nproc
    else echo 4; fi
}

# sha256 of a file.
sha256_of() {
    sha256sum "$1" | awk '{print $1}'
}

# Layout (overridable via environment). All generated artifacts live under
# one tree (.build/) so the repo root stays clean.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${WORK_DIR:=${REPO_ROOT}/.build}"
: "${SRC_DIR:=${WORK_DIR}/src}"       # cached source tarballs
: "${BUILD_DIR:=${WORK_DIR}/obj}"     # extracted + compiled sources
: "${PREFIX:=${WORK_DIR}/prefix}"     # staging prefix for static deps
: "${OUT_DIR:=${WORK_DIR}/out}"       # final ffmpeg binaries
: "${STAMP_DIR:=${PREFIX}/stamps}"    # per-dependency build stamps (skip cache)
# Parallel jobs. The container runs on the same host, so by default we use the
# host's full CPU count (nproc) — no point leaving cores idle. If a build runs
# out of memory, set JOBS lower (or use MEM_BASED_JOBS=1 to fall back to a
# memory-capped estimate of one job per ~1.5GB free RAM).
mem_based_jobs() {
    local cpus free_mb jobs
    cpus="$(cpu_count)"
    if command -v free >/dev/null 2>&1; then
        free_mb="$(free -m 2>/dev/null | awk '/Mem:/{print $7}')"
    fi
    free_mb="${free_mb:-0}"
    if [ "$free_mb" -gt 0 ] 2>/dev/null; then
        jobs=$(( free_mb / 1500 ))
    else
        jobs="$cpus"
    fi
    [ "$jobs" -lt 1 ] 2>/dev/null && jobs=1
    [ "$jobs" -gt "$cpus" ] 2>/dev/null && jobs="$cpus"
    echo "$jobs"
}
if [ "${MEM_BASED_JOBS:-0}" = "1" ]; then
    : "${JOBS:=$(mem_based_jobs)}"
else
    : "${JOBS:=$(cpu_count)}"
fi
# Parallel dependency jobs: how many independent dependencies may compile at
# once (each still uses -j${JOBS} internally). Keep this low enough that
# DEP_JOBS * JOBS does not exhaust container memory. Bump with DEP_JOBS=4 etc.
: "${DEP_JOBS:=2}"

# pkg-config / build flags pointing at our static staging prefix
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/lib/x86_64-linux-gnu/pkgconfig"
export PATH="${PREFIX}/bin:${PATH}"

# -ffile-prefix-map rewrites __FILE__ (and debug paths) so that assert/log
# strings compiled into a dependency say ./svtav1/... instead of the build
# tree's /work/obj/svtav1/..., which would otherwise ship in every binary.
export CFLAGS="-I${PREFIX}/include ${CFLAGS:-} -O2 -fPIC -ffile-prefix-map=${BUILD_DIR}=."
export CXXFLAGS="-I${PREFIX}/include ${CXXFLAGS:-} -O2 -fPIC -ffile-prefix-map=${BUILD_DIR}=."
export LDFLAGS="-L${PREFIX}/lib -L${PREFIX}/lib/x86_64-linux-gnu ${LDFLAGS:-}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ccache: wrap the compiler so object compilation is cached across builds.
# CCACHE_DIR is set by the container (mounted from host); if ccache is missing
# or disabled, fall back to the plain compiler. This speeds up rebuilds of the
# same sources (e.g. after a container teardown) dramatically.
if command -v ccache >/dev/null 2>&1 && [ -n "${CCACHE_DIR:-}" ]; then
    export CC="ccache gcc"
    export CXX="ccache g++"
    export CCACHE_COMPRESS=1
    log "ccache enabled (dir=${CCACHE_DIR})"
else
    export CC="${CC:-gcc}"
    export CXX="${CXX:-g++}"
fi

# sha256_matches FILE EXPECTED  -> 0 if match (or no expected sha), 1 otherwise.
# Non-fatal counterpart to verify_sha256, used to test a cached file.
sha256_matches() {
    local file="$1" expected="$2"
    [ -n "$expected" ] || return 0
    [ "$(sha256_of "$file")" = "$expected" ]
}

# verify_sha256 FILE EXPECTED  -> die on mismatch (used for fresh downloads).
verify_sha256() {
    local file="$1" expected="$2"
    [ -n "$expected" ] || return 0
    local actual
    actual="$(sha256_of "$file")"
    if [ "$actual" != "$expected" ]; then
        die "checksum mismatch for $(basename "$file"): expected $expected got $actual"
    fi
    log "sha256 ok: $(basename "$file")"
}

# download URL DEST [SHA256]
download() {
    local url="$1" dest="$2" sha="${3:-}"
    if [ -f "$dest" ]; then
        # The cache is keyed by dependency name, not version, so a cached
        # tarball from a *previous* version of this dep can shadow a new URL.
        # If a checksum is given and the cached file matches, reuse it; if it
        # does not match, treat the cache as stale (a version/URL bump) and
        # re-download rather than aborting the whole build.
        if sha256_matches "$dest" "$sha"; then
            log "cached: $(basename "$dest")"
            return 0
        fi
        warn "cached $(basename "$dest") does not match expected sha256; \
stale cache from a previous version — re-downloading"
        rm -f "$dest"
    fi
    log "download: $url"
    curl -fL --retry 3 --retry-delay 2 -o "${dest}.tmp" "$url"
    verify_sha256 "${dest}.tmp" "$sha"
    mv "${dest}.tmp" "$dest"
}

# extract ARCHIVE DEST_DIR  (strips leading component)
extract() {
    local archive="$1" dest="$2"
    mkdir -p "$dest"
    log "extract: $(basename "$archive") -> $dest"
    tar -xf "$archive" -C "$dest" --strip-components=1
}

# fetch_and_extract URL NAME [SHA256]  -> echoes source dir
# If the second arg after NAME is the literal "noclean", the extracted source
# dir is reused (not wiped) — used when a dependency is already built and we
# only need its source path for a stamp check.
fetch_and_extract() {
    local url="$1" name="$2" sha="${3:-}" clean="${4:-clean}"
    local archive="${SRC_DIR}/${name}$(archive_ext "$url")"
    local srcdir="${BUILD_DIR}/${name}"
    download "$url" "$archive" "$sha"
    if [ "$clean" = "clean" ]; then
        rm -rf "$srcdir"
    fi
    extract "$archive" "$srcdir"
    printf '%s\n' "$srcdir"
}

# --- dependency stamp cache (skip already-built deps) ---
# A stamp records the manifest line that produced an installed dependency.
# If the stamp exists and matches, the dependency is skipped on rebuild.
stamp_path()   { printf '%s/%s.stamp' "$STAMP_DIR" "$1"; }
stamp_write()  { mkdir -p "$STAMP_DIR"; printf '%s' "$2" > "$(stamp_path "$1")"; }
stamp_match() {
    local name="$1" line="$2" sp
    sp="$(stamp_path "$name")"
    [ -f "$sp" ] && [ "$(cat "$sp")" = "$line" ]
}
stamp_clear()  { rm -f "$(stamp_path "$1")"; }

archive_ext() {
    case "$1" in
        *.tar.xz)  echo ".tar.xz" ;;
        *.tar.bz2) echo ".tar.bz2" ;;
        *.tar.gz|*.tgz) echo ".tar.gz" ;;
        *) echo ".tar.gz" ;;
    esac
}

ensure_dirs() {
    mkdir -p "$SRC_DIR" "$BUILD_DIR" "$PREFIX" "$OUT_DIR" "$STAMP_DIR"
}
