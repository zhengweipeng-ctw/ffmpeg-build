#!/usr/bin/env bash
# Recompute the sha256 field in manifest.sh for one or more dependencies.
#
# Closes the loop on a version bump: edit the URL in manifest.sh, run this, and
# the checksum follows. Without it the tempting shortcut is to set the sha to
# "-", which silently drops download verification for that dependency.
#
# Dependencies whose sha is already "-" are skipped by design: those URLs point
# at archives the forge regenerates (git archive tarballs, SourceForge
# redirects) and are not byte-stable, so pinning a checksum would break the
# build on the next regeneration. Use --force to set one anyway.
#
# Runs on macOS and Linux; only needs curl and a sha256 tool. It does not build
# anything and touches nothing but manifest.sh.
#
# Usage:
#   scripts/deps-update-sha.sh dav1d x265     # refresh these
#   scripts/deps-update-sha.sh --all          # every dependency with a pinned sha
#   scripts/deps-update-sha.sh --force x264   # also (re)pin a "-" entry
#   scripts/deps-update-sha.sh --check dav1d  # report mismatches, change nothing
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MANIFEST:=${HERE}/manifest.sh}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'   # macOS
    fi
}

FORCE=0
CHECK=0
ALL=0
names=()
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --check) CHECK=1 ;;
        --all)   ALL=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        -*)      die "unknown option: $arg" ;;
        *)       names+=("$arg") ;;
    esac
done

[ "$ALL" = 1 ] || [ "${#names[@]}" -gt 0 ] || die "no dependencies given (use --all for every one)"

# Pull "name|system|url|sha" out of the DEPS array without sourcing manifest.sh.
# Every awk pass below is scoped to the DEPS block: manifest.sh has a second
# pipe-separated array (DEBIAN_SRC) whose lines would otherwise match too, and
# assigning $4 on a two-field line would pad it with empty fields.
# The last field of a DEPS line carries the array element's closing quote
# (a dep with no extra args ends "...|<sha>"), so strip it off the value.
dep_field() {
    local name="$1" field="$2"
    awk -F'|' -v n="\"${name}" -v f="$field" '
        /^DEPS=\(/         { indeps = 1; next }
        indeps && /^\)/    { exit }
        indeps && $1 == n  { v = $f; sub(/"$/, "", v); print v; exit }
    ' "$MANIFEST"
}

if [ "$ALL" = 1 ]; then
    while IFS= read -r n; do names+=("$n"); done < <(
        awk -F'|' '
            /^DEPS=\(/      { indeps = 1; next }
            indeps && /^\)/ { exit }
            indeps && /^"/  { sub(/^"/, "", $1); print $1 }
        ' "$MANIFEST"
    )
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

changed=0
mismatched=0
for name in "${names[@]}"; do
    url="$(dep_field "$name" 3)"
    [ -n "$url" ] || { warn "unknown dependency: ${name} (skipped)"; continue; }
    old="$(dep_field "$name" 4)"

    if [ "$old" = "-" ] && [ "$FORCE" != 1 ]; then
        log "${name}: sha intentionally unpinned (-), skipping — use --force to pin"
        continue
    fi

    log "${name}: fetching ${url}"
    if ! curl -fsSL --retry 3 --retry-delay 2 -o "${TMP}/${name}" "$url"; then
        warn "${name}: download failed, leaving manifest untouched"
        continue
    fi
    new="$(sha256_of "${TMP}/${name}")"

    if [ "$new" = "$old" ]; then
        log "${name}: unchanged (${new})"
        continue
    fi

    if [ "$CHECK" = 1 ]; then
        warn "${name}: MISMATCH"
        warn "  manifest: ${old}"
        warn "  actual:   ${new}"
        mismatched=$((mismatched + 1))
        continue
    fi

    # Rewrite field 4 of this dependency's line only. Write back through the
    # existing file so its permissions and inode survive.
    # Re-attach the closing quote when the sha is the line's last field,
    # otherwise the rewritten array element loses it and manifest.sh stops
    # being valid bash.
    awk -F'|' -v OFS='|' -v n="\"${name}" -v s="$new" '
        /^DEPS=\(/         { indeps = 1; print; next }
        indeps && /^\)/    { indeps = 0 }
        indeps && $1 == n  { $4 = s ($4 ~ /"$/ ? "\"" : "") }
                           { print }
    ' "$MANIFEST" > "${TMP}/manifest.sh"
    cat "${TMP}/manifest.sh" > "$MANIFEST"
    log "${name}: ${old} -> ${new}"
    changed=$((changed + 1))
done

if [ "$CHECK" = 1 ]; then
    [ "$mismatched" -eq 0 ] || die "${mismatched} checksum mismatch(es)"
    log "all checked dependencies match their manifest checksum"
else
    log "${changed} checksum(s) updated in manifest.sh"
fi
