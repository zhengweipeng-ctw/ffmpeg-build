#!/usr/bin/env python3
"""Report dependencies whose pinned version has drifted from Debian testing.

The manifest pins every third-party library to the version Debian testing
ships (see README). Debian moves; the manifest does not. This script makes the
drift visible so a version bump is a deliberate act instead of an oversight.

It reads scripts/manifest.sh directly (no sourcing — plain parsing), derives the
pinned version from each tarball URL, and asks sources.debian.org what the
matching source package carries in testing.

Nothing here touches the build: it is a read-only reporting tool, safe to run
from a laptop or CI. Requires only Python 3 stdlib and network access.

Usage:
    scripts/deps-check-updates.py             # table for every dependency
    scripts/deps-check-updates.py x264 dav1d  # only these
    scripts/deps-check-updates.py --strict    # exit 1 if anything is behind Debian
    scripts/deps-check-updates.py --json      # machine-readable, for CI
    scripts/deps-check-updates.py --suite sid # compare against a different suite
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(REPO_ROOT, "scripts", "manifest.sh")

RELEASE_URL = "https://deb.debian.org/debian/dists/{suite}/Release"
SOURCES_API = "https://sources.debian.org/api/src/{pkg}/"
USER_AGENT = "ffmpeg-build-deps-check-updates/1.0 (+https://sources.debian.org/doc/api/)"
TIMEOUT = 30

# Status values, ordered worst-first for the summary.
BEHIND, AHEAD, OK, UNTRACKED, UNVERSIONED, ERROR = (
    "behind",
    "ahead",
    "ok",
    "untracked",
    "unversioned",
    "error",
)


# --- manifest parsing -------------------------------------------------------

def _array_entries(text: str, name: str) -> list[str]:
    """Return the quoted string entries of a bash array literal NAME=( ... )."""
    m = re.search(rf"^{name}=\(\s*$(.*?)^\)\s*$", text, re.S | re.M)
    if not m:
        return []
    return re.findall(r'^"(.*)"\s*$', m.group(1), re.M)


def parse_manifest(path: str) -> tuple[list[dict], dict[str, str]]:
    with open(path, encoding="utf-8") as fh:
        text = fh.read()

    deps = []
    fv = re.search(r'^FFMPEG_VERSION="([^"]+)"', text, re.M)
    if fv:
        deps.append({"name": "ffmpeg", "url": "", "pinned": fv.group(1),
                     "commit": None})

    for line in _array_entries(text, "DEPS"):
        fields = line.split("|")
        if len(fields) < 3:
            continue
        name, url = fields[0], fields[2]
        deps.append({
            "name": name,
            "url": url,
            "pinned": pinned_version(url),
            "commit": pinned_commit(url),
        })

    debian_src = {}
    for line in _array_entries(text, "DEBIAN_SRC"):
        dep, _, pkg = line.partition("|")
        debian_src[dep.strip()] = pkg.strip()

    return deps, debian_src


ARCHIVE_EXT = re.compile(r"\.(?:tar\.(?:gz|xz|bz2)|tgz|tbz2|zip)$")
DOTTED_VERSION = re.compile(r"\d+(?:\.\d+)+")


def pinned_version(url: str) -> str | None:
    """Extract the version from a tarball URL, or None if it carries none.

    Handles the shapes present in the manifest: `foo-1.2.3.tar.xz`,
    `v1.2.3.tar.gz`, `release-3.0.6.tar.gz`, `SVT-AV1-v4.1.0.tar.gz`,
    `soxr-0.1.3-Source.tar.xz`. Returns None for URLs that pin a branch
    (`x264-stable.tar.bz2`) or a git commit; for the latter, pinned_commit()
    below can still produce a comparison.
    """
    tail = url.rsplit("/", 1)[-1]
    tail = ARCHIVE_EXT.sub("", tail)
    matches = DOTTED_VERSION.findall(tail)
    return matches[-1] if matches else None


HEX_RUN = re.compile(r"\b([0-9a-f]{7,40})\b")
# Debian encodes git snapshots as ...+git<date>.<short-sha> (or ~git<date><sha>),
# e.g. x264's 2:0.165.3223+git20250910.0480cb0-1.
# Tried in order, most specific first. The dotted form is what Debian actually
# uses (`+git20250910.0480cb0`) and is unambiguous; the others are fallbacks.
# A date run directly against a sha is inherently ambiguous when the sha starts
# with digits, so it is only attempted after the dotted form fails.
DEBIAN_GIT_PATTERNS = (
    re.compile(r"git(\d{8})\.([0-9a-f]{7,40})\b"),   # +git20250910.0480cb0
    re.compile(r"git(\d{8})([0-9a-f]{7,40})\b"),     # +git202509100480cb0
    re.compile(r"git()[.-]?([0-9a-f]{7,40})\b"),     # +git.0480cb0 / +git0480cb0
)


def pinned_commit(url: str) -> str | None:
    """Extract the git commit a URL pins, or None.

    Forge archive endpoints carry the commit in the path
    (`.../-/archive/<sha>/x264-<sha>.tar.bz2`). At least one hex *letter* is
    required so that plain digit runs — dates, long version numbers — are not
    mistaken for a sha.
    """
    for cand in HEX_RUN.findall(url.lower()):
        if any(c in "abcdef" for c in cand):
            return cand
    return None


def debian_snapshot(debver: str) -> tuple[str | None, str | None]:
    """Split a Debian git-snapshot version into (yyyymmdd, commit).

    Either half may be None: not every snapshot carries a date, and most
    versions are not snapshots at all.
    """
    low = debver.lower()
    for pat in DEBIAN_GIT_PATTERNS:
        m = pat.search(low)
        if m:
            return (m.group(1) or None), m.group(2)
    return None, None


def debian_commit(debver: str) -> str | None:
    """Just the commit half of debian_snapshot()."""
    return debian_snapshot(debver)[1]


def same_commit(ours: str, theirs: str) -> bool:
    """Debian abbreviates the sha, so compare on the shorter of the two."""
    n = min(len(ours), len(theirs))
    return ours[:n] == theirs[:n]


# Render commit pins the way Go writes pseudo-versions: <UTC timestamp>-<12 hex>.
# Sortable, unambiguous, and it reads the same on both sides of the comparison.
GITLAB_ARCHIVE = re.compile(r"^https://([^/]+)/(.+?)/-/archive/")
GITHUB_ARCHIVE = re.compile(r"^https://github\.com/([^/]+)/([^/]+)/archive/")


def forge_commit_date(url: str, sha: str) -> str | None:
    """Ask the forge when a commit was authored -> 'yyyymmddhhmmss', or None.

    Only GitLab- and GitHub-style archive URLs are recognised; anything else
    (or any network/API failure) simply degrades to a bare commit id.
    """
    m = GITLAB_ARCHIVE.match(url)
    if m:
        host, project = m.group(1), urllib.parse.quote(m.group(2), safe="")
        api = f"https://{host}/api/v4/projects/{project}/repository/commits/{sha}"
        key = ("committed_date",)
    else:
        m = GITHUB_ARCHIVE.match(url)
        if not m:
            return None
        api = f"https://api.github.com/repos/{m.group(1)}/{m.group(2)}/commits/{sha}"
        key = ("commit", "committer", "date")
    try:
        data = json.loads(_fetch(api))
        for k in key:
            data = data[k]
    except (urllib.error.URLError, OSError, ValueError, KeyError, TypeError):
        return None
    # Both forges answer ISO-8601 with an offset; normalise to UTC.
    try:
        dt = datetime.datetime.fromisoformat(str(data))
    except ValueError:
        return None
    if dt.tzinfo is not None:
        dt = dt.astimezone(datetime.timezone.utc)
    return dt.strftime("%Y%m%d%H%M%S")


def pseudo_version(sha: str, date: str | None) -> str:
    """Go-style pseudo-version: 20250910094056-0480cb05fa18."""
    short = sha[:12]
    return f"{date}-{short}" if date else short


# --- Debian lookups ---------------------------------------------------------

def _fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return resp.read()


def resolve_codename(suite: str) -> str:
    """Map a suite alias (testing/stable/unstable) to its Debian codename.

    sources.debian.org indexes by codename (forky, trixie, sid), so tracking
    "testing" without resolving it would silently pin us to whatever codename
    was current when this script was written.
    """
    if suite not in ("testing", "stable", "oldstable", "unstable"):
        return suite  # already a codename
    body = _fetch(RELEASE_URL.format(suite=suite)).decode("utf-8", "replace")
    m = re.search(r"^Codename:\s*(\S+)", body, re.M)
    if not m:
        raise RuntimeError(f"could not resolve codename for suite '{suite}'")
    return m.group(1)


def debian_version(pkg: str, codename: str) -> tuple[str | None, str | None]:
    """Return (version-in-suite, error). Unknown packages are not an error."""
    try:
        data = json.loads(_fetch(SOURCES_API.format(pkg=pkg)))
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return None, str(exc)
    # The API answers 200 with {"error": 404} for unknown packages, so the HTTP
    # status is not usable as a signal here.
    if "error" in data:
        return None, None
    for entry in data.get("versions", []):
        if codename in entry.get("suites", []):
            return entry["version"], None
    return None, None


# --- version handling -------------------------------------------------------

def upstream_of(debver: str) -> str:
    """Strip Debian packaging noise down to the upstream version.

    2:6.3.0+dfsg-5              -> 6.3.0
    1:1.3.dfsg+really1.3.2-3    -> 1.3.2
    3.101~svn6531+dfsg-1        -> 3.101
    0.165.3223+git20250910.x-1  -> 0.165.3223
    """
    v = re.sub(r"^\d+:", "", debver)          # epoch
    v = re.sub(r"-[^-]*$", "", v)             # Debian revision
    if "+really" in v:                        # zlib's rename workaround
        v = v.split("+really", 1)[1]
    return re.split(r"[+~]", v)[0]            # +dfsg / +ds1 / ~svn...


def version_key(v: str) -> tuple[int, ...]:
    return tuple(int(x) for x in re.findall(r"\d+", v))


def compare(pinned: str, debian: str) -> str:
    a, b = version_key(pinned), version_key(debian)
    width = max(len(a), len(b))
    a += (0,) * (width - len(a))
    b += (0,) * (width - len(b))
    if a == b:
        return OK
    return BEHIND if b > a else AHEAD


# --- reporting --------------------------------------------------------------

def check(dep: dict, debian_src: dict[str, str], codename: str) -> dict:
    name: str = dep["name"]
    pkg: str = debian_src.get(name) or name
    row = {
        "name": name,
        "pinned": dep["pinned"],
        "debian_source": None if pkg == "-" else pkg,
        "debian_version": None,
        "debian_upstream": None,
        "status": None,
        "note": "",
    }

    if pkg == "-":
        row["status"] = UNTRACKED
        row["note"] = "not packaged in Debian"
        return row

    debver, err = debian_version(pkg, codename)
    if err:
        row["status"] = ERROR
        row["note"] = err
        return row
    if debver is None:
        row["status"] = UNTRACKED
        row["note"] = f"'{pkg}' not in {codename}"
        return row

    row["debian_version"] = debver
    row["debian_upstream"] = upstream_of(debver)

    if dep["pinned"] is None:
        # No version in our URL — but if we pin a git commit and Debian ships a
        # git snapshot, its version string carries the commit too, so the two
        # are still comparable (this is what makes x264 trackable at all).
        ours = dep.get("commit")
        their_date, theirs = debian_snapshot(debver)
        if ours and theirs:
            row["pinned"] = pseudo_version(ours, forge_commit_date(dep["url"], ours))
            row["debian_upstream"] = pseudo_version(theirs, their_date)
            if same_commit(ours, theirs):
                row["status"] = OK
            else:
                row["status"] = BEHIND
                row["note"] = f"Debian moved to {row['debian_upstream']}"
            return row
        row["status"] = UNVERSIONED
        row["note"] = "URL pins a branch, not a version or commit"
        return row

    row["status"] = compare(dep["pinned"], row["debian_upstream"])
    return row


COLORS = {BEHIND: "1;33", AHEAD: "1;36", OK: "0;32", ERROR: "1;31"}


def paint(text: str, status: str, enabled: bool) -> str:
    code = COLORS.get(status)
    return f"\033[{code}m{text}\033[0m" if enabled and code else text


def print_table(rows: list[dict], codename: str, color: bool) -> None:
    widths = {
        "name": max(4, *(len(r["name"]) for r in rows)),
        "pinned": max(6, *(len(r["pinned"] or "-") for r in rows)),
        "debian": max(14, *(len(r["debian_version"] or "-") for r in rows)),
    }
    header = (
        f"{'dep':<{widths['name']}}  "
        f"{'pinned':<{widths['pinned']}}  "
        f"{'debian/' + codename:<{widths['debian']}}  status"
    )
    print(header)
    print("-" * len(header))
    for r in rows:
        line = (
            f"{r['name']:<{widths['name']}}  "
            f"{r['pinned'] or '-':<{widths['pinned']}}  "
            f"{r['debian_version'] or '-':<{widths['debian']}}  "
            f"{paint(r['status'], r['status'], color)}"
        )
        if r["note"]:
            line += f"  ({r['note']})"
        print(line)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Compare pinned dependency versions against Debian testing."
    )
    ap.add_argument("deps", nargs="*", help="only check these dependencies")
    ap.add_argument("--suite", default="testing",
                    help="Debian suite or codename to compare against (default: testing)")
    ap.add_argument("--strict", action="store_true",
                    help="exit 1 if any dependency is behind Debian")
    ap.add_argument("--json", action="store_true", help="emit JSON instead of a table")
    ap.add_argument("--jobs", type=int, default=8, help="concurrent HTTP requests (default: 8)")
    args = ap.parse_args()

    deps, debian_src = parse_manifest(MANIFEST)
    if not deps:
        print(f"ERROR: no dependencies parsed from {MANIFEST}", file=sys.stderr)
        return 2

    if args.deps:
        wanted = set(args.deps)
        unknown = wanted - {d["name"] for d in deps}
        if unknown:
            print(f"ERROR: unknown dependencies: {', '.join(sorted(unknown))}", file=sys.stderr)
            return 2
        deps = [d for d in deps if d["name"] in wanted]

    try:
        codename = resolve_codename(args.suite)
    except (urllib.error.URLError, OSError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        rows = list(pool.map(lambda d: check(d, debian_src, codename), deps))

    if args.json:
        json.dump({"suite": args.suite, "codename": codename, "results": rows},
                  sys.stdout, indent=2)
        print()
    else:
        print_table(rows, codename, color=sys.stdout.isatty())
        counts = {}
        for r in rows:
            counts[r["status"]] = counts.get(r["status"], 0) + 1
        summary = ", ".join(f"{counts[s]} {s}" for s in
                            (BEHIND, AHEAD, OK, UNTRACKED, UNVERSIONED, ERROR) if s in counts)
        noun = "dependency" if len(rows) == 1 else "dependencies"
        print(f"\n{len(rows)} {noun}: {summary}")

    if any(r["status"] == ERROR for r in rows):
        return 2
    if args.strict and any(r["status"] == BEHIND for r in rows):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
