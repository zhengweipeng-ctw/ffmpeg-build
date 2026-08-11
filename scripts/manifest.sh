# shellcheck shell=bash
# Declarative manifest of FFmpeg and its statically-linked dependencies.
#
# Each dependency is one line in DEPS, ordered so that dependencies come first.
# Fields are separated by '|':
#
#   name | system | url | sha256 | extra-args...
#
#   name    short id, also used for --enable-lib<...> mapping
#   system  one of: autotools | cmake | meson | make
#   url     source tarball URL
#   sha256  expected checksum, or "-" to skip verification
#   extra   space-separated extra configure/cmake/meson args (optional)
#
# Special markers:
#   @NO_STATIC@  - for autotools deps whose ./configure does not accept
#                   --enable-static --disable-shared (e.g. zlib)
#   @SUBDIR:dir@ - build inside a subdirectory of the extracted source
#
# The generic builder in builder.sh knows the standard static flags for each
# build system, so recipes only list what differs. Add a new library by adding
# one line here and the matching --enable-* flag in FFMPEG_ENABLE below.

# --- FFmpeg itself ---
FFMPEG_VERSION="9.0"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
FFMPEG_SHA256="7f607a00dd0d28a729d5a4811205812eef01cf6ef6155025febb6f36a9062d52"

# --- Dependencies (build order matters) ---
DEPS=(
# core compression/encoding
"zlib|autotools|https://zlib.net/fossils/zlib-1.3.2.tar.gz|bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16|@NO_STATIC@"
"xz|autotools|https://github.com/tukaani-project/xz/releases/download/v5.8.3/xz-5.8.3.tar.xz|fff1ffcf2b0da84d308a14de513a1aa23d4e9aa3464d17e64b9714bfdd0bbfb6|--disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo --disable-scripts"

# audio
"ogg|autotools|https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.gz|83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638"
"vorbis|autotools|https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz|-|--with-ogg=@PREFIX@"
"opus|autotools|https://github.com/xiph/opus/archive/refs/tags/v1.6.1.tar.gz|bf0b97ec7a65890b8db90ef94c4d6c18de12584c3085031953a10986f5917745|--disable-doc --disable-extra-programs"
"lame|autotools|https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz|3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb|--enable-nasm --disable-frontend --disable-decoder"
"speex|autotools|https://downloads.xiph.org/releases/speex/speex-1.2.1.tar.gz|-|--disable-examples"
"twolame|autotools|https://sourceforge.net/projects/twolame/files/twolame/0.4.0/twolame-0.4.0.tar.gz|-|--disable-nls"
"shine|autotools|https://github.com/savonet/shine/archive/refs/tags/3.1.1.tar.gz|-"
"opencore-amr|autotools|https://downloads.sourceforge.net/project/opencore-amr/opencore-amr/opencore-amr-0.1.6.tar.gz|483eb4061088e2b34b358e47540b5d495a96cd468e361050fae615b1809dc4a1"
"soxr|cmake|https://sourceforge.net/projects/soxr/files/soxr-0.1.3-Source.tar.xz|-|-DWITH_OPENMP=OFF -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF"
"rubberband|meson|https://github.com/breakfastquay/rubberband/archive/refs/tags/v4.0.0.tar.gz|24300f48a8014b7c863b573a9647e61b1b19b37875e2cdd92005e64c6424d266"
"jxl|cmake|https://github.com/libjxl/libjxl/archive/refs/tags/v0.11.2.tar.gz|ab38928f7f6248e2a98cc184956021acb927b16a0dee71b4d260dc040a4320ea|-DPROVISION_DEPENDENCIES=ON -DBUILD_TESTING=OFF -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_VIEWERS=OFF -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_ENABLE_DEVTOOLS=OFF -DJPEGXL_STATIC=ON"

# text/subtitles (chain: freetype -> harfbuzz -> fontconfig -> libass)
"freetype|autotools|https://downloads.sourceforge.net/project/freetype/freetype2/2.14.3/freetype-2.14.3.tar.xz|36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f|--with-harfbuzz=no --with-png=no --with-bzip2=no --with-brotli=no --with-zlib=no"
"expat|autotools|https://github.com/libexpat/libexpat/releases/download/R_2_8_2/expat-2.8.2.tar.xz|3ad89b8588e6644bd4e49981480d48b21289eebbcd4f0a1a4afb1c29f99b6ab4"
"fribidi|autotools|https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz|-"
"harfbuzz|cmake|https://github.com/harfbuzz/harfbuzz/releases/download/12.3.2/harfbuzz-12.3.2.tar.xz|6f6db164359a2da5a84ef826615b448b33e6306067ad829d85d5b0bf936f1bb8|-DHB_HAVE_FREETYPE=ON -DHB_BUILD_TESTS=OFF -DHB_BUILD_EXAMPLES=OFF -DHB_BUILD_UTILS=OFF"
"fontconfig|autotools|https://gitlab.freedesktop.org/fontconfig/fontconfig/-/archive/2.17.1/fontconfig-2.17.1.tar.gz|82e73b26adad651b236e5f5d4b3074daf8ff0910188808496326bd3449e5261d|--disable-docs --sysconfdir=/etc --localstatedir=/var"
"libass|autotools|https://github.com/libass/libass/releases/download/0.17.5/libass-0.17.5.tar.xz|2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc"

# misc
"snappy|cmake|https://github.com/google/snappy/archive/refs/tags/1.2.2.tar.gz|90f74bc1fbf78a6c56b3c4a082a05103b3a56bb17bca1a27e052ea11723292dc|-DSNAPPY_BUILD_TESTS=OFF -DSNAPPY_BUILD_BENCHMARKS=OFF"
"xml2|autotools|https://download.gnome.org/sources/libxml2/2.15/libxml2-2.15.3.tar.xz|78262a6e7ac170d6528ebfe2efccdf220191a5af6a6cd61ea4a9a9a5042c7a07|--without-python --without-lzma --without-zlib --sysconfdir=/etc"
"webp|cmake|https://github.com/webmproject/libwebp/archive/refs/tags/v1.5.0.tar.gz|668c9aba45565e24c27e17f7aaf7060a399f7f31dba6c97a044e1feacb930f37|-DWEBP_BUILD_ANIMATIONS=OFF -DWEBP_BUILD_EXTRAS=OFF -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_LIBWEBPMUX=OFF"
"openjpeg|cmake|https://github.com/uclouvain/openjpeg/archive/refs/tags/v2.5.4.tar.gz|a695fbe19c0165f295a8531b1e4e855cd94d0875d2f88ec4b61080677e27188a|-DBUILD_CODEC=OFF -DBUILD_TESTING=OFF -DBUILD_DOC=OFF"
"theora|autotools|https://downloads.xiph.org/releases/theora/libtheora-1.2.0.tar.gz|279327339903b544c28a92aeada7d0dcfd0397b59c2f368cc698ac56f515906e|--with-ogg=@PREFIX@ --with-vorbis=@PREFIX@ --disable-examples --disable-oggtest --disable-vorbistest"
"zimg|autotools|https://github.com/sekrit-twc/zimg/archive/refs/tags/release-3.0.6.tar.gz|be89390f13a5c9b2388ce0f44a5e89364a20c1c57ce46d382b1fcc3967057577"
"vidstab|cmake|https://github.com/georgmartius/vid.stab/archive/refs/tags/v1.1.1.tar.gz|9001b6df73933555e56deac19a0f225aae152abbc0e97dc70034814a1943f3d4|-DUSE_OMP=OFF"
"xvid|autotools|https://downloads.xvid.com/downloads/xvidcore-1.3.7.tar.gz|-|--disable-assembly @SUBDIR:build/generic@"

# video codecs
# x264 has never tagged a release — the upstream repo carries zero tags, so
# every distro ships a git snapshot. Pin the exact commit Debian testing
# packages (its 2:0.165.3223+git20250910.0480cb0 decodes to
# 0.<X264_BUILD>.<commit-count>+git<date>.<commit>), not a branch name: a
# branch URL makes the source non-reproducible and, because the stamp cache
# keys off this manifest line, would also mean x264 never rebuilds.
# Note this is master, which is where Debian takes its snapshot from; the
# stable branch lags it. Both are X264_BUILD 165, so the ABI is the same.
"x264|autotools|https://code.videolan.org/videolan/x264/-/archive/0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee/x264-0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee.tar.bz2|f05c59f2e83d494c36307025dca2d3afc6b4d185f3a3453d06cc4fecd7094057|--enable-pic --disable-cli --disable-opencl"
"x265|cmake|https://bitbucket.org/multicoreware/x265_git/get/4.2.tar.gz|-|-DENABLE_CLI=OFF -DENABLE_PIC=ON -DEXPORT_C_API=ON -DENABLE_ASSEMBLY=OFF -DENABLE_LIBNUMA=OFF @SUBDIR:source@"
"openh264|make|https://github.com/cisco/openh264/archive/refs/tags/v2.6.0.tar.gz|558544ad358283a7ab2930d69a9ceddf913f4a51ee9bf1bfb9e377322af81a69|OS=linux ARCH=x86_64 ENABLE64BIT=Yes PREFIX=@PREFIX@ @TARGET:libraries@ @INSTALL_TARGET:install-static@"
"kvazaar|autotools|https://github.com/ultravideo/kvazaar/archive/refs/tags/v2.3.2.tar.gz|ddd0038696631ca5368d8e40efee36d2bbb805854b9b1dda8b12ea9b397ea951|--disable-shared"
"dav1d|meson|https://code.videolan.org/videolan/dav1d/-/archive/1.5.4/dav1d-1.5.4.tar.gz|a1d5b63d2d38ec9bd03acf643caa51fa22edd1e89c5a109c4807717216bbec07|-Denable_tools=false -Denable_tests=false"
"vpx|autotools|https://github.com/webmproject/libvpx/archive/refs/tags/v1.16.0.tar.gz|7a479a3c66b9f5d5542a4c6a1b7d3768a983b1e5c14c60a9396edc9b649e015c|--enable-pic --disable-examples --disable-tools --disable-docs --disable-unit-tests --enable-vp8 --enable-vp9 --enable-vp9-highbitdepth"
"aom|cmake|https://storage.googleapis.com/aom-releases/libaom-3.14.1.tar.gz|44bf90dbd23e734d50e70a8c41c285193922938bd0d3bc2ee56764d181d55ef5|-DENABLE_DOCS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_TESTS=OFF -DENABLE_TOOLS=OFF -DCONFIG_PIC=1"
"svtav1|cmake|https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v4.1.0/SVT-AV1-v4.1.0.tar.gz|6c4c0c44ff0ba3d136d6f57f3a707f9de8e9c866f50f809c1d22a43f0d8c9583|-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF -DBUILD_APPS=OFF -DBUILD_TESTING=OFF"

)

# --- Debian source package names (used by scripts/deps-check-updates.py) ---
# The versions above are pinned to what Debian testing ships. The script
# verifies that by querying sources.debian.org, which indexes by *Debian source
# package* name. That name usually equals the manifest name, so a dependency
# missing from this table is looked up under its own name and only the
# exceptions are listed:
#
#   name | debian-source-package     ("-" = not packaged in Debian at all)
#
# A "-" entry means the pinned version is ours to choose and track by hand —
# it is reported as "untracked" rather than silently passing.
DEBIAN_SRC=(
# named differently in Debian
"xz|xz-utils"
"ogg|libogg"
"vorbis|libvorbis"
"soxr|libsoxr"
"jxl|jpeg-xl"
"xml2|libxml2"
"webp|libwebp"
"openjpeg|openjpeg2"
"theora|libtheora"
"vidstab|libvidstab"
"xvid|xvidcore"
"vpx|libvpx"
"svtav1|svt-av1"
)

# FFmpeg --enable-* flags corresponding to the dependencies above.
FFMPEG_ENABLE=(
    --enable-zlib
    --enable-lzma
    --enable-iconv
    --enable-libxml2
    --enable-libsoxr
    --enable-libmp3lame
    --enable-libopus
    --enable-libvorbis
    --enable-libfreetype
    --enable-libfribidi
    --enable-libharfbuzz
    --enable-libfontconfig
    --enable-libass
    --enable-libspeex
    --enable-libtwolame
    --enable-libshine
    --enable-libopencore-amrnb
    --enable-libopencore-amrwb
    --enable-libsnappy
    --enable-librubberband
    --enable-libwebp
    --enable-libopenjpeg
    --enable-libjxl
    --enable-libtheora
    --enable-libzimg
    --enable-libvidstab
    --enable-libxvid
    --enable-libx264
    --enable-libx265
    --enable-libopenh264
    --enable-libkvazaar
    --enable-libdav1d
    --enable-libvpx
    --enable-libaom
    --enable-libsvtav1
)
