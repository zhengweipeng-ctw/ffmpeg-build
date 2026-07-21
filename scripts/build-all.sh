#!/usr/bin/env bash
# Backwards-compatible alias for the Linux build entry point.
# See scripts/build.sh for the real implementation.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build.sh" "$@"
