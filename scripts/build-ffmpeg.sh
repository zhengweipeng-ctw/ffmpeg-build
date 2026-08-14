#!/usr/bin/env bash
# Build FFmpeg (ffmpeg, ffprobe) against the static dependencies
# previously built into $PREFIX by build-deps.sh.
#
# Third-party libraries are linked statically; only the core system libraries
# (libc, libm, libgcc, libstdc++, libnuma) remain dynamic. Intended to run
# inside the Ubuntu 24.04 build container (or natively on Ubuntu 24.04).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=manifest.sh
source "${HERE}/manifest.sh"
# shellcheck source=common.sh
source "${HERE}/common.sh"

ensure_dirs

src="$(fetch_and_extract "$FFMPEG_URL" ffmpeg "$FFMPEG_SHA256")"
cd "$src"

configure_args=(
    # The declared install root, shown in `ffmpeg -version` (FFMPEG_CONFIGURATION)
    # and used as the preset search path ($prefix/share/ffmpeg). Not the staging
    # directory here: `make install-progs prefix=` below redirects where the
    # binaries are actually written. It is independent of the server deploy
    # path (see Justfile) — this is deliberately just the declared prefix.
    --prefix=/usr/local
    --pkg-config-flags="--static"
    --disable-debug
    --disable-doc
    # Hermetic build: never auto-enable an external library just because it
    # happens to be present on the host. Only the libraries we explicitly
    # --enable below (all built statically into $PREFIX) are linked in. This
    # guarantees the binaries stay free of host dependencies (e.g. X11 via
    # libxcb/libX11, alsa, bzlib) without having to --disable each one, which
    # is exactly what the portable, fully-static target needs.
    --disable-autodetect
    # License: GPLv3. --enable-gpl is required by librubberband, libvidstab,
    # libx264, libx265 and libxvid; --enable-version3 by opencore-amr.
    # --enable-nonfree is deliberately NOT set: nothing here needs it (FFmpeg's
    # nonfree list is decklink, libfdk_aac, libmpeghdec, cuda_nvcc, cuda_sdk,
    # libnpp) and setting it would make the binaries non-redistributable for
    # no benefit. Adding any of those libraries means adding it back.
    --enable-gpl
    --enable-version3
    --enable-pthreads
    --enable-runtime-cpudetect
    --enable-ffmpeg
    --enable-ffprobe
)

configure_args+=(
    --enable-static
    --disable-shared
    --extra-libs="-lpthread -lm -ldl"
)
# Many of the statically-linked third-party libs are C++ (x265, harfbuzz,
# snappy, zimg, jxl, rubberband, opencore-amr, ...), so the
# binaries need the C++ runtime. Ubuntu's gcc links libstdc++ dynamically by
# default, which couples the binary to the build host's GLIBCXX version and
# breaks on servers with an older libstdc++. Fold it into the binary; it carries
# the GCC Runtime Library Exception so static linking is fine to ship.
# (libgcc_s stays dynamic — the glibc/pthread unwinder pulls it in regardless,
# so -static-libgcc has no effect and is omitted.)
configure_args+=(
    --extra-ldflags="-static-libstdc++"
)
# NOTE: x265 is built with -DENABLE_LIBNUMA=OFF (see manifest.sh), so no
# statically-linked dependency pulls in libnuma anymore and the binaries carry
# no libnuma.so.1 dependency. No numa link flags are needed here.

# Append the --enable-lib* flags declared in the manifest.
configure_args+=( "${FFMPEG_ENABLE[@]}" )

if ! ./configure "${configure_args[@]}"; then
    echo "ERROR: ffmpeg configure failed; tail of ffbuild/config.log:" >&2
    tail -40 ffbuild/config.log 2>/dev/null >&2 || true
    exit 1
fi

make -j"$JOBS"
# install-progs, not install: we only ship the binaries. Plain `install` would
# also drop the static libav* libraries, their headers, the .pc files and the
# presets/examples under share/ into $OUT_DIR, none of which is deployed.
# (In a static build install-progs pulls in no library install step, and doc is
# disabled, so this installs exactly ffmpeg and ffprobe into $OUT_DIR/bin.)
# prefix= overrides only the install destination; config.mak resolves BINDIR as
# ${prefix}/bin lazily, so the path compiled into the binary is unaffected.
make install-progs prefix="$OUT_DIR"

log "FFmpeg binaries installed into ${OUT_DIR}/bin"
log "dynamic dependencies of produced binaries:"
for b in ffmpeg ffprobe; do
    bin="${OUT_DIR}/bin/${b}"
    [ -x "$bin" ] || { warn "missing ${b}"; continue; }
    printf '  %-8s ' "$b"
    echo "dynamic -> $(ldd "$bin" 2>/dev/null | grep -c '=>') shared libs"
done

"${OUT_DIR}/bin/ffmpeg" -version | head -1 || true
