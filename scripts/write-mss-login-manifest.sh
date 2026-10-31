#!/usr/bin/env bash
# Write the baked MSS-Login lists.
# MANIFEST is sha256 of regular files. MANIFEST.entries is every non-directory
# (files, symlinks, fifos). MANIFEST.dirs is every directory except the root.
# .git, __pycache__, and bytecode names are omitted from all three.
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
entries="$(mktemp)"
dirs="$(mktemp)"
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
(
  cd "$src"
  find . \
    \( -path './.git' -o -path '*/__pycache__' \) -prune -o \
    ! -type d ! -name '*.pyc' ! -name '*.pyo' -print \
    | sed 's|^\./||' \
    | sort
) >"$entries"
(
  cd "$src"
  find . \
    \( -path './.git' -o -path '*/__pycache__' \) -prune -o \
    -type d -print \
    | sed 's|^\./||' \
    | sed '/^$/d' \
    | sort
) >"$dirs"
mv "$tmp" "$out"
mv "$entries" "${out}.entries"
mv "$dirs" "${out}.dirs"
