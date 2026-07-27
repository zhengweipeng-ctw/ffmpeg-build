# shellcheck shell=bash
# Generic dependency builder. Given a manifest line it fetches the source and
# builds it as a static library into $PREFIX, applying the standard static
# flags for its build system. Recipe-specific tweaks live in manifest.sh.

# Expand @PREFIX@ placeholder and split a string into an array of args.
expand_args() {
    local s="$1"
    s="${s//@PREFIX@/$PREFIX}"
    printf '%s' "$s"
}

# Parse a "@SUBDIR:source@" hint out of the extra args. Sets two globals:
#   PARSED_SUBDIR  - the subdir (empty if none)
#   PARSED_ARGS    - the extra args with the hint removed
# Uses globals (not command substitution) so assignments are visible to the
# caller; a $(...) call would run in a subshell and lose them.
PARSED_SUBDIR=""
PARSED_ARGS=""
parse_extra() {
    local extra="$1" subdir=""
    if [[ "$extra" =~ @SUBDIR:([^@]+)@ ]]; then
        subdir="${BASH_REMATCH[1]}"
        extra="${extra//@SUBDIR:${subdir}@/}"
    fi
    PARSED_SUBDIR="$subdir"
    PARSED_ARGS="$extra"
}

build_autotools() {
    local dir="$1"; shift
    local static_flags=(--enable-static --disable-shared)
    local args=()
    for a in "$@"; do
        if [ "$a" = "@NO_STATIC@" ]; then
            static_flags=()
        else
            args+=("$a")
        fi
    done
    ( cd "$dir"
      # Some autotools tarballs ship without a generated ./configure;
      # bootstrap it first if an autogen script or configure.ac is present.
      if [ ! -x ./configure ] && [ -x ./autogen.sh ]; then
          ./autogen.sh
      elif [ ! -x ./configure ] && [ -f configure.ac ]; then
          autoreconf -fi
      fi
      ./configure --prefix="$PREFIX" "${static_flags[@]}" "${args[@]}"
      make -j"$JOBS"
      make install )
}

build_cmake() {
    local dir="$1"; shift
    ( cd "$dir"
      cmake -B build -G "Unix Makefiles" \
          -DCMAKE_INSTALL_PREFIX="$PREFIX" \
          -DCMAKE_BUILD_TYPE=Release \
          -DBUILD_SHARED_LIBS=OFF \
          -DENABLE_SHARED=OFF \
          -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
          -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
          -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
          "$@"
      cmake --build build -j"$JOBS"
      cmake --install build )
}

build_meson() {
    local dir="$1"; shift
    ( cd "$dir"
      meson setup build \
          --prefix="$PREFIX" \
          --libdir=lib \
          --buildtype=release \
          --default-library=static \
          "$@"
      ninja -C build
      ninja -C build install )
}

# OpenSSL uses its own Configure/config script, not autotools/cmake.
build_openssl() {
    local dir="$1"; shift
    ( cd "$dir"
      ./config --prefix="$PREFIX" --openssldir="${PREFIX}/etc/ssl" --libdir=lib "$@"
      make -j"$JOBS"
      make install_sw )
}

# Plain Makefile projects (e.g. openh264). Args are passed as make variables.
# Supports @TARGET:xxx@ and @INSTALL_TARGET:xxx@ markers.
build_make() {
    local dir="$1"; shift
    local target=""
    local install_target=""
    local args=()
    for a in "$@"; do
        if [[ "$a" =~ @TARGET:(.+)@ ]]; then
            target="${BASH_REMATCH[1]}"
        elif [[ "$a" =~ @INSTALL_TARGET:(.+)@ ]]; then
            install_target="${BASH_REMATCH[1]}"
        else
            args+=("$a")
        fi
    done
    ( cd "$dir"
      make -j"$JOBS" "${args[@]}" ${target:+"$target"}
      make install "${args[@]}" ${install_target:+"$install_target"} )
}

# build_dep "name|system|url|sha256|extra..."
build_dep() {
    local line="$1"
    local IFS='|'
    read -r name system url sha extra <<<"$line"
    unset IFS

    [ "$sha" = "-" ] && sha=""

    # Skip if a matching stamp exists: the dependency is already built and
    # its manifest line (version/url/flags) is unchanged.
    if stamp_match "$name" "$line"; then
        log "===== skipping ${name} (stamp up to date) ====="
        return 0
    fi

    log "===== building dependency: ${name} (${system}) ====="
    local src
    src="$(fetch_and_extract "$url" "$name" "$sha" clean)"

    parse_extra "${extra:-}"
    [ -n "$PARSED_SUBDIR" ] && src="${src}/${PARSED_SUBDIR}"

    # shellcheck disable=SC2206
    local args=( $(expand_args "$PARSED_ARGS") )

    # Pre-build setup for deps that need source-level patches
    pre_build_setup "$name" "$src"

    case "$system" in
        autotools) build_autotools "$src" "${args[@]}" ;;
        cmake)     build_cmake "$src" "${args[@]}" ;;
        meson)     build_meson "$src" "${args[@]}" ;;
        openssl)   build_openssl "$src" "${args[@]}" ;;
        make)      build_make "$src" "${args[@]}" ;;
        *)         die "unknown build system '$system' for '$name'" ;;
    esac

    post_install_fixup "$name"
    stamp_write "$name" "$line"
    log "===== done: ${name} ====="
}

# Per-library fix-ups applied after install (mostly pkg-config quirks that
# break FFmpeg's static link/detection).
post_install_fixup() {
    local name="$1"
    case "$name" in
        x265)
            # x265's pkg-config omits -lpthread, which breaks static linking
            # into FFmpeg. See multicoreware/x265_git issue #371.
            local pc="${PREFIX}/lib/pkgconfig/x265.pc"
            if [ -f "$pc" ] && ! grep -q -- '-lpthread' "$pc"; then
                sed_inplace 's/-lx265/-lx265 -lpthread/g' "$pc"
            fi
            ;;
        freetype)
            # freetype's freetype2.pc always lists optional deps (zlib, bzip2,
            # libpng, harfbuzz) in Requires based on what exists on the host,
            # regardless of --with-*=no. Under --pkg-config-flags=--static that
            # drags in the host's *dynamic* copies of those libs. We built
            # freetype without them, so clear Requires to keep the link clean.
            local pc="${PREFIX}/lib/pkgconfig/freetype2.pc"
            if [ -f "$pc" ]; then
                sed_inplace 's/^Requires:.*/Requires:/' "$pc"
                sed_inplace 's/^Requires.private:.*/Requires.private:/' "$pc"
            fi
            ;;
        xvid)
            # xvid's build installs both .a and .so; the dynamic .so would be
            # picked up by FFmpeg's linker, leaving a runtime dependency on
            # libxvidcore.so. Remove the shared libs so static linking wins.
            rm -f "${PREFIX}/lib/libxvidcore.so"*
            ;;
        openh264)
            # openh264's Makefile installs both .a and .so. Drop the .so so
            # FFmpeg links the static archive.
            rm -f "${PREFIX}/lib/libopenh264.so"*
            ;;
        zlib)
            # zlib uses @NO_STATIC@ (its ./configure rejects --disable-shared),
            # so it installs BOTH libz.a and libz.so*. In the not-fully-static
            # final link the linker prefers the shared object, leaking a
            # dynamic libz.so.1 into the FFmpeg binaries. Remove the shared
            # libs (including any stale sonames from a previous version) so -lz
            # resolves to libz.a and zlib is linked statically.
            rm -f "${PREFIX}/lib/libz.so"*
            ;;
        xz)
            # xz's install prefix puts pkg-config files under lib/x86_64-linux-gnu
            # on some distros; symlink them to the standard lib/pkgconfig path.
            if [ -d "${PREFIX}/lib/x86_64-linux-gnu/pkgconfig" ] && [ ! -e "${PREFIX}/lib/pkgconfig/liblzma.pc" ]; then
                mkdir -p "${PREFIX}/lib/pkgconfig"
                ln -sf "${PREFIX}/lib/x86_64-linux-gnu/pkgconfig/liblzma.pc" "${PREFIX}/lib/pkgconfig/liblzma.pc"
            fi
            ;;
        libssh)
            # libssh's pkg-config doesn't list openssl, which is needed for
            # static linking. Add openssl to Libs.private.
            #
            # libssh's cmake may install the .pc file to the multiarch path
            # (lib/x86_64-linux-gnu/pkgconfig). Symlink it to the standard
            # lib/pkgconfig path so the fixup and pkg-config both find it.
            if [ -f "${PREFIX}/lib/x86_64-linux-gnu/pkgconfig/libssh.pc" ] && [ ! -f "${PREFIX}/lib/pkgconfig/libssh.pc" ]; then
                mkdir -p "${PREFIX}/lib/pkgconfig"
                ln -sf "${PREFIX}/lib/x86_64-linux-gnu/pkgconfig/libssh.pc" "${PREFIX}/lib/pkgconfig/libssh.pc"
            fi
            local pc="${PREFIX}/lib/pkgconfig/libssh.pc"
            if [ -f "$pc" ]; then
                # libssh is built with zlib support by default, which pulls in
                # deflate/inflate symbols. Ensure zlib is in Libs.private so
                # consumers (FFmpeg's configure test) can link statically.
                if ! grep -q -- '-lz' "$pc"; then
                    if grep -q '^Libs.private:' "$pc"; then
                        sed_inplace 's#^Libs.private:#Libs.private: -lz#' "$pc"
                    else
                        sed_inplace '/^Libs:/i Libs.private: -lz' "$pc"
                    fi
                fi
                # Also ensure openssl libs are present (libssh uses crypto).
                if ! grep -q -- '-lssl' "$pc"; then
                    if grep -q '^Libs.private:' "$pc"; then
                        sed_inplace 's#^Libs.private:#Libs.private: -lssl -lcrypto#' "$pc"
                    else
                        sed_inplace '/^Libs:/i Libs.private: -lssl -lcrypto' "$pc"
                    fi
                fi
            else
                warn "libssh.pc not found after install (expected at ${pc})"
            fi
            ;;
        srt)
            # srt's cmake may install the .pc file to the multiarch path.
            # Symlink it to the standard path so pkg-config finds it.
            for name in srt haisrt; do
                if [ -f "${PREFIX}/lib/x86_64-linux-gnu/pkgconfig/${name}.pc" ] && [ ! -f "${PREFIX}/lib/pkgconfig/${name}.pc" ]; then
                    mkdir -p "${PREFIX}/lib/pkgconfig"
                    ln -sf "${PREFIX}/lib/x86_64-linux-gnu/pkgconfig/${name}.pc" "${PREFIX}/lib/pkgconfig/${name}.pc"
                fi
            done
            # srt installs its .pc as srt.pc (or haisrt.pc), but FFmpeg's
            # --enable-libsrt looks for libsrt.pc. Create the alias.
            local actual=""
            for name in srt haisrt; do
                if [ -f "${PREFIX}/lib/pkgconfig/${name}.pc" ]; then
                    actual="${name}.pc"
                    break
                fi
                if [ -f "${PREFIX}/lib/x86_64-linux-gnu/pkgconfig/${name}.pc" ]; then
                    mkdir -p "${PREFIX}/lib/pkgconfig"
                    ln -sf "${PREFIX}/lib/x86_64-linux-gnu/pkgconfig/${name}.pc" "${PREFIX}/lib/pkgconfig/${name}.pc"
                    actual="${name}.pc"
                    break
                fi
            done
            if [ -n "$actual" ] && [ ! -f "${PREFIX}/lib/pkgconfig/libsrt.pc" ]; then
                ln -sf "$actual" "${PREFIX}/lib/pkgconfig/libsrt.pc"
            fi
            ;;
        librist)
            # librist's meson may install the .pc file to the multiarch path.
            if [ -f "${PREFIX}/lib/x86_64-linux-gnu/pkgconfig/librist.pc" ] && [ ! -f "${PREFIX}/lib/pkgconfig/librist.pc" ]; then
                mkdir -p "${PREFIX}/lib/pkgconfig"
                ln -sf "${PREFIX}/lib/x86_64-linux-gnu/pkgconfig/librist.pc" "${PREFIX}/lib/pkgconfig/librist.pc"
            fi
            ;;
        jxl)
            # libjxl builds highway and brotli in third_party/ and installs
            # them alongside libjxl. The generated .pc files are correct —
            # except libjxl_threads.pc omits -lstdc++ (needed for
            # std::thread, std::condition_variable).
            local pc="${PREFIX}/lib/pkgconfig/libjxl_threads.pc"
            if [ -f "$pc" ] && ! grep -q -- '-lstdc++' "$pc"; then
                sed_inplace 's#^Libs.private: -lm#Libs.private: -lstdc++ -lm#' "$pc"
            fi
            ;;
    esac
}

# Pre-build setup: apply source-level patches before configuring a dependency.
# Some tarballs omit generated files (version.h) or need minor source tweaks
# to work with the FFmpeg version we are building.
pre_build_setup() {
    local name="$1" src="$2"
    case "$name" in
        jxl)
            # libjxl's internal .cc files include the PUBLIC jxl/*.h headers.
            # The global -I${PREFIX}/include (set in common.sh) puts any
            # previously-installed jxl headers ahead of the in-tree ones, so a
            # stale copy from a *different* jxl version shadows the rebuild and
            # produces "invalid use of incomplete type 'JxlDecoder'" errors
            # (e.g. after a version bump/downgrade). Remove any previously
            # installed jxl headers so the build sees only its own tree.
            rm -rf "${PREFIX}/include/jxl"
            ;;
    esac
}

# In-place sed (GNU sed, used on Linux).
sed_inplace() {
    sed -i -e "$1" "$2"
}

# Look up a manifest line by dependency name.
find_dep_line() {
    local want="$1" line
    for line in "${DEPS[@]}"; do
        [ "${line%%|*}" = "$want" ] && { printf '%s' "$line"; return 0; }
    done
    return 1
}
