# ffmpeg-build

Build a **statically-linked FFmpeg 8.1.2** (`ffmpeg`, `ffprobe`, `ffplay`) for
**Linux / x86_64 (amd64)**.

All third-party libraries are compiled from source and linked statically, with
versions pinned to what Debian **testing** ships. Only the core glibc/gcc
runtime (`libc`, `libm`, `libmvec`, `libgcc_s`) stays dynamic — libstdc++ is
linked statically and there is no libnuma or other third-party dependency. The
build runs in an **Ubuntu 24.04** container, so it is reproducible and
independent of the host toolchain; the resulting binaries require
**glibc ≥ 2.39** on the target host.

## Quick start

### macOS (via container)

```sh
./build/build-in-container.sh
```

Builds the Ubuntu 24.04 image, then compiles all dependencies and FFmpeg inside
it. Binaries land in `./dist/out/bin/`; caches and intermediates under `./dist/`.

The binaries are **Linux/x86_64 executables** — they do not run on macOS. Copy
`./dist/out/bin/{ffmpeg,ffprobe,ffplay}` to your Linux server.

> On Apple Silicon the amd64 image runs under emulation, so the first build is
> slow. This is expected — the target is x86_64 Linux.

### Linux (native)

Install the apt dependencies listed in `build/Dockerfile`, then:

```sh
./scripts/build.sh          # full build (all deps + ffmpeg)
```

## How it works

Two entry points, one build implementation:

- **`build/build-in-container.sh`** (macOS) only builds the image and runs
  `scripts/build.sh` inside it — no macOS-specific build logic.
- **`scripts/build.sh`** (Linux) does the actual work and knows nothing about
  containers. It runs `build-deps.sh` (all static dependencies) then
  `build-ffmpeg.sh` (FFmpeg linked against them).

All output goes under `./dist/` by default; override with the `WORK_DIR`
environment variable.

Adding a library is declarative — no new files:

1. add one line to `DEPS` in `scripts/manifest.sh`,
2. add the matching `--enable-*` flag to `FFMPEG_ENABLE` (same file),
3. add its name to a build batch in `scripts/build-deps.sh`.

## Build a subset of dependencies

```sh
./build/build-in-container.sh x264 x265                # only these deps, in the container
WORK_DIR=$PWD/work ./scripts/build-deps.sh x264 x265   # same, natively
```

Passing dependency names builds **only those dependencies** and then stops —
FFmpeg is skipped, since a partial dependency set would fail its `configure`
(which expects every `--enable-*` library to be present). Run with **no
arguments** for the full build that also compiles FFmpeg.

## Faster builds

Three mechanisms keep rebuilds fast:

**ccache** — compilation is cached in `dist/ccache/` (mounted into the container
as `/ccache`), so it survives container teardown. `CC`/`CXX` are wrapped as
`ccache gcc` / `ccache g++`, which all three build systems (autotools, cmake,
meson) honor. Inspect with `ccache -d dist/ccache -s`; wipe with
`rm -rf dist/ccache`.

**Dependency stamps** — each dependency records its manifest line
(version/url/flags) in `dist/prefix/stamps/<name>.stamp`. On rebuild a matching
stamp skips the dependency entirely (no re-extract, reconfigure, or recompile);
changing a version or flag invalidates just that one. Force a rebuild of
everything with `rm -rf dist/prefix/stamps`, or of one dependency with
`rm dist/prefix/stamps/<name>.stamp`.

**Parallel builds** — within a dependency, `make -j` / `ninja -j` uses `JOBS`
(default: the host core count); across dependencies, independent ones build in
parallel (`DEP_JOBS`, default 2) in batches, with the
`freetype → harfbuzz → fontconfig → libass` and `ogg → vorbis → theora` chains
serialized. Tune with `JOBS=10 DEP_JOBS=4 ./build/build-in-container.sh` (raise
`DEP_JOBS` if you have RAM to spare; lower `JOBS` if linking OOMs); set
`MEM_BASED_JOBS=1` for a memory-capped job count.
