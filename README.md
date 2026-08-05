# ffmpeg-build

Build a **statically-linked FFmpeg 8.1.2** (`ffmpeg`, `ffprobe`) for
**Linux / x86_64 (amd64)**.

All third-party libraries are compiled from source and linked statically, with
versions pinned to what Debian **testing** ships. Only the core glibc/gcc
runtime (`libc`, `libm`, `libmvec`, `libgcc_s`) stays dynamic — libstdc++ is
linked statically and there is no libnuma or other third-party dependency. The
build runs in an **Ubuntu 24.04** container, so it is reproducible and
independent of the host toolchain; the resulting binaries require
**glibc ≥ 2.39** on the target host — that is the toolchain's glibc and so the
supported floor, though the highest symbol version the binaries actually
reference is currently 2.38 (`objdump -T bin/ffmpeg | grep -o 'GLIBC_[0-9.]*' |
sort -uV | tail -1`).

## Quick start

### macOS (via container)

```sh
./build/build-in-container.sh
```

Builds the Ubuntu 24.04 image, then compiles all dependencies and FFmpeg inside
it. Binaries land in `./dist/out/bin/`; caches and intermediates under `./dist/`.

The binaries are **Linux/x86_64 executables** — they do not run on macOS. Copy
`./dist/out/bin/{ffmpeg,ffprobe}` to your Linux server.

`ffplay` is deliberately not built: it exists only to open an SDL window,
which a headless server cannot do, and it was the sole consumer of the SDL2
dependency.

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

If Debian names the library's source package differently — or does not package
it at all — also add a line to `DEBIAN_SRC` in `scripts/manifest.sh` so the
version check below can find it.

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

## Keeping versions current

The manifest pins each library to the version Debian testing ships. Debian
moves and the manifest does not, so the drift needs to be visible rather than
discovered years later:

```sh
./scripts/deps-check-updates.py                 # full table
./scripts/deps-check-updates.py dav1d x265      # just these
./scripts/deps-check-updates.py --strict        # exit 1 if anything is behind Debian (CI)
./scripts/deps-check-updates.py --json          # machine-readable
```

It resolves the current testing codename from `deb.debian.org` (so it does not
rot when testing rolls over), then asks `sources.debian.org` for each source
package. Read-only, stdlib-only Python 3, no network access during a build.

Each dependency lands in one of five states:

| status | meaning |
| --- | --- |
| `ok` | pinned version equals Debian testing |
| `behind` | Debian ships newer — a bump is due |
| `ahead` | we pin newer than Debian (deliberate; e.g. tracking a release Debian hasn't taken) |
| `untracked` | not packaged in Debian — the pinned version is ours to choose and watch by hand |
| `unversioned` | in Debian, but our URL pins a branch — nothing to compare |

`untracked` is checked first, so a dependency absent from Debian reports as
`untracked` even if it is also unversioned.

**Git snapshots are compared by commit.** x264 has never tagged a release — the
upstream repo carries zero tags, so every distro ships a git snapshot. Debian
encodes the commit in its version (`2:0.165.3223+git20250910.0480cb0`, i.e.
`0.<X264_BUILD>.<commit-count>+git<date>.<commit>`), and the manifest pins that
same commit in its URL, so the two are directly comparable:

```
x264  20250910014056-0480cb05fa18  2:0.165.3223+git20250910.0480cb0-1  ok
```

Commit pins are rendered the way Go writes pseudo-versions —
`<UTC timestamp>-<12 hex>` — which sorts chronologically and reads the same on
both sides. The timestamp comes from the forge (GitLab and GitHub archive URLs
are recognised); if the forge is unknown or unreachable the bare commit is
shown instead, and the comparison is unaffected either way since it matches on
the commit. The row flips to `behind` with Debian's new pseudo-version when
Debian rebases its snapshot. Only a *branch* URL is genuinely `unversioned`.

That leaves `libiconv` as the one dependency to watch by hand — it is
`untracked` because glibc provides iconv, so Debian never packages GNU libiconv
separately.

Bumping a version is two steps — edit the URL in `DEPS`, then let the checksum
follow:

```sh
./scripts/deps-update-sha.sh dav1d              # re-download and rewrite its sha256
./scripts/deps-update-sha.sh --check --all      # verify every pinned tarball still matches
```

Dependencies whose sha is `-` are skipped: those URLs point at archives the
forge regenerates (git-archive tarballs, SourceForge redirects) and are not
byte-stable, so a pinned checksum would break the build on the next
regeneration. `--force` overrides that if a URL becomes stable.
