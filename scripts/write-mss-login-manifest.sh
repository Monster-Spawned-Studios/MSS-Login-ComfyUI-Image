#!/usr/bin/env bash
# Write a sha256 manifest of the baked MSS-Login tree.
# Excludes .git, __pycache__, and bytecode. Those paths are not copied onto
# the runtime shadow and are not part of the verified file list.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: write-mss-login-manifest.sh SOURCE_DIR MANIFEST_OUT" >&2
  exit 2
fi

src="$1"
out="$2"

if [[ ! -d "$src" ]]; then
  echo "manifest source is not a directory: ${src}" >&2
  exit 1
fi

tmp="$(mktemp)"
(
  cd "$src"
  find . \
    \( -path './.git' -o -path '*/__pycache__' \) -prune -o \
    -type f ! -name '*.pyc' ! -name '*.pyo' -print \
    | sed 's|^\./||' \
    | sort \
    | while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        sum="$(sha256sum -- "$rel" | awk '{print $1}')"
        printf '%s  %s\n' "$sum" "$rel"
      done
) >"$tmp"
mv "$tmp" "$out"
