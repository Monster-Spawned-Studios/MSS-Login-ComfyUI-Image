#!/bin/bash
set -o pipefail

# ============================================================
# Model downloader baked into the image (root:root 0755, /usr/local/bin).
# Carried over from user-scripts/01-download-models.sh (development 9dc33b1).
# Hardened for strict HTTPS, SHA-256 pinning, pickle restrictions, safe paths,
# collision protection, resumable downloads, resource limits, and log hygiene.
#
# entrypoint.sh runs it only as uid 1000, after the MSS-Login shadow and
# pin checks and the custom-node dependency step, right before ComfyUI starts.
# It never runs host scripts. The host user-scripts directory supplies DATA
# only: the download list. Every write stays under the models directory.
#
#   Download list   MSS_MODELS_LIST (default /home/comfy/user-scripts/models-to-download.txt)
#                   or MODELS_TO_DOWNLOAD (comma or newline separated).
#   Models dir      MODELS_DIR (default /app/ComfyUI/models).
#   MODELS_DOWNLOAD_DIR  force one folder; must be inside MODELS_DIR.
#
# Manifest & Pinning:
#   - Every entry MUST specify an exact 64-character SHA-256 checksum.
#   - Unpinned entries are refused.
#   - Pickle formats (.ckpt, .pt, .pth, .bin, .pkl, .pickle, .joblib) are allowed ONLY from
#     huggingface.co or civitai.com (verified after redirects via url_effective).
#   - Downloads go to "<dest>.part" and are atomically renamed after sha256 check.
#   - Failed downloads are logged per-entry; startup is never blocked (exits 0).
# ============================================================

if [ "$(id -u)" -eq 0 ]; then
    echo "[Models] Refusing to run as root. The entrypoint runs this as uid 1000." >&2
    exit 1
fi

MODELS_DIR="$(realpath -m -- "${MODELS_DIR:-/app/ComfyUI/models}")"
LIST_FILE="${MSS_MODELS_LIST:-/home/comfy/user-scripts/models-to-download.txt}"

# True when $1 (may be a symlink or inside a symlinked subfolder) resolves or logically sits inside MODELS_DIR.
inside_models_dir() {
    local p="$1"
    local p_deref p_logical base_deref base_logical
    base_deref="$(realpath -m -- "$MODELS_DIR")" || return 1
    base_logical="$(realpath -s -m -- "$MODELS_DIR")" || return 1
    p_deref="$(realpath -m -- "$p")" || return 1
    p_logical="$(realpath -s -m -- "$p")" || return 1

    # Allowed if canonical path is within canonical MODELS_DIR
    if [[ "$p_deref" == "$base_deref" || "$p_deref" == "$base_deref"/* ]]; then
        return 0
    fi
    # Allowed if logical path is within logical MODELS_DIR (e.g. symlinked model subfolders)
    if [[ "$p_logical" == "$base_logical" || "$p_logical" == "$base_logical"/* ]]; then
        return 0
    fi
    return 1
}

if [ -n "${MODELS_DOWNLOAD_DIR:-}" ] && ! inside_models_dir "$MODELS_DOWNLOAD_DIR"; then
    echo "[Models] MODELS_DOWNLOAD_DIR must be inside ${MODELS_DIR}; ignoring ${MODELS_DOWNLOAD_DIR}." >&2
    MODELS_DOWNLOAD_DIR=""
fi

FORCE_DOWNLOAD=false
case "${MODELS_FORCE_DOWNLOAD,,}" in
    true|1|yes|on) FORCE_DOWNLOAD=true ;;
esac

for arg in "$@"; do
    case "$arg" in
        -f|--force) FORCE_DOWNLOAD=true ;;
        -h|--help)
            echo "Usage: $0 [--force]   (see header comments for environment variables)"
            exit 0
            ;;
        *) echo "[Models] ⚠ Unknown argument ignored: $arg" ;;
    esac
done

HASH_CACHE="$MODELS_DIR/.download-hash-cache.tsv"

# Safe token fallback: read key-value pair from .env without sourcing or eval
load_token_from_env_file() {
    local var_name="$1" candidate val
    for candidate in "${ENV_FILE:-}" "/home/comfy/user-scripts/.env" "/app/ComfyUI/.env" "/data/mss-login/.env" "/data/.env" ".env"; do
        if [ -n "$candidate" ] && [ -f "$candidate" ]; then
            val="$(grep -E "^[[:space:]]*${var_name}=" "$candidate" 2>/dev/null | tail -n 1 | cut -d= -f2-)"
            val="$(printf '%s' "$val" | sed -E -e 's/^[[:space:]]*["'"'"']?//' -e 's/["'"'"']?[[:space:]]*$//')"
            if [ -n "$val" ]; then
                printf '%s' "$val"
                return 0
            fi
        fi
    done
    return 1
}

HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
if [ -z "$HF_TOKEN" ]; then
    HF_TOKEN="$(load_token_from_env_file "HF_TOKEN" || load_token_from_env_file "HUGGING_FACE_HUB_TOKEN" || true)"
fi
CIVITAI_TOKEN="${CIVITAI_TOKEN:-}"
if [ -z "$CIVITAI_TOKEN" ]; then
    CIVITAI_TOKEN="$(load_token_from_env_file "CIVITAI_TOKEN" || true)"
fi

# Nit 1: Validate MODELS_MAX_FILESIZE and MODELS_DISK_HEADROOM_KB against ^[0-9]+[KMG]?$
parse_size_bytes() {
    local raw="${1:-}" default_val="$2"
    [ -z "$raw" ] && raw="$default_val"
    raw="$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]')"
    if ! [[ "$raw" =~ ^[0-9]+[KMG]?$ ]]; then
        echo "[Models] ⚠ Invalid MODELS_MAX_FILESIZE: '$1'; using default $default_val" >&2
        raw="$default_val"
    fi
    local num unit mult=1
    if [[ "$raw" =~ ^([0-9]+)([KMG])?$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
        case "$unit" in
            K) mult=1024 ;;
            M) mult=$(( 1024 * 1024 )) ;;
            G) mult=$(( 1024 * 1024 * 1024 )) ;;
            *) mult=1 ;;
        esac
        if [ "$num" -gt 1099511627776 ] 2>/dev/null; then
            echo 53687091200
        else
            echo $(( num * mult ))
        fi
    else
        echo "$default_val"
    fi
}

parse_headroom_kb() {
    local raw="${1:-}" default_val="$2"
    [ -z "$raw" ] && raw="$default_val"
    raw="$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]')"
    if ! [[ "$raw" =~ ^[0-9]+[KMG]?$ ]]; then
        echo "[Models] ⚠ Invalid MODELS_DISK_HEADROOM_KB: '$1'; using default $default_val" >&2
        raw="$default_val"
    fi
    local num unit mult=1
    if [[ "$raw" =~ ^([0-9]+)([KMG])?$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
        case "$unit" in
            K) mult=1 ;;
            M) mult=1024 ;;
            G) mult=$(( 1024 * 1024 )) ;;
            *) mult=1 ;;
        esac
        if [ "$num" -gt 1073741824 ] 2>/dev/null; then
            echo 1048576
        else
            echo $(( num * mult ))
        fi
    else
        echo "$default_val"
    fi
}

MAX_FILESIZE_BYTES="$(parse_size_bytes "${MODELS_MAX_FILESIZE:-}" "53687091200")" # Default 50GB
MAX_TIME="${MODELS_MAX_TIME:-7200}"
CONNECT_TIMEOUT="${MODELS_CONNECT_TIMEOUT:-30}"
DISK_HEADROOM_KB="$(parse_headroom_kb "${MODELS_DISK_HEADROOM_KB:-}" "1048576")" # Default 1GB headroom

# Strict HTTPS enforcement for curl
CURL_HTTPS_OPTS=(--proto "=https" --proto-redir "=https" --fail --location)

# Log sanitizer: strip user credentials, tokens, query parameters, auth headers
sanitize_url() {
    local u="$1"
    # Remove userinfo (https://user:pass@host -> https://host)
    u="$(printf '%s' "$u" | sed -E 's#(https?://)[^/@]+@#\1#g')"
    # Strip query string
    u="${u%%\?*}"
    # Redact any leftover token=, key=, secret=
    u="$(printf '%s' "$u" | sed -E 's/(token|key|secret|authorization)=[^&[:space:]]+/\1=[REDACTED]/gI')"
    if [ -n "$HF_TOKEN" ]; then
        u="${u//"$HF_TOKEN"/\[REDACTED\]}"
    fi
    if [ -n "$CIVITAI_TOKEN" ]; then
        u="${u//"$CIVITAI_TOKEN"/\[REDACTED\]}"
    fi
    printf '%s' "$u"
}

file_size() {
    stat -c %s -- "$1" 2>/dev/null || stat -f %z -- "$1" 2>/dev/null || echo 0
}

file_mtime() {
    stat -c %Y -- "$1" 2>/dev/null || stat -f %m -- "$1" 2>/dev/null || echo 0
}

human_size() {
    local bytes="$1"
    awk -v b="$bytes" 'BEGIN {
        split("B KB MB GB TB", u, " ");
        i = 1;
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        if (i == 1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i]
    }'
}

# Header value (last occurrence, case-insensitive) from headers on stdin
header_value() {
    awk -v h="$1" 'BEGIN { h = tolower(h) }
        { line = $0; sub(/\r$/, "", line); i = index(line, ":");
          if (i > 0 && tolower(substr(line, 1, i - 1)) == h) { v = substr(line, i + 1); sub(/^[ \t]+/, "", v); val = v } }
        END { if (val != "") print val }'
}

cache_put() {  # algo path hash
    local algo="$1" path="$2" hash="$3" abs size mtime
    abs="$(readlink -f -- "$path")" || return 0
    size="$(file_size "$abs")"; mtime="$(file_mtime "$abs")"
    if [ -f "$HASH_CACHE" ]; then
        if awk -F'\t' -v a="$algo" -v p="$abs" '!($1 == a && $2 == p)' "$HASH_CACHE" > "$HASH_CACHE.tmp.$$" 2>/dev/null; then
            mv -f -- "$HASH_CACHE.tmp.$$" "$HASH_CACHE"
        else
            rm -f -- "$HASH_CACHE.tmp.$$"
        fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$algo" "$abs" "$size" "$mtime" "$hash" >> "$HASH_CACHE" 2>/dev/null || true
}

local_hash() {  # algo path -> hex (cached by path+size+mtime)
    local algo="$1" path="$2" abs size mtime hit h
    abs="$(readlink -f -- "$path")" || return 1
    size="$(file_size "$abs")"; mtime="$(file_mtime "$abs")"
    if [ -f "$HASH_CACHE" ]; then
        hit="$(awk -F'\t' -v a="$algo" -v p="$abs" -v s="$size" -v m="$mtime" \
            '$1 == a && $2 == p && $3 == s && $4 == m { h = $5 } END { if (h != "") print h }' "$HASH_CACHE" 2>/dev/null)" || hit=""
        if [ -n "$hit" ]; then
            echo "$hit"
            return 0
        fi
    fi
    # Nit 2: Hardcode sha256sum
    h="$(sha256sum -- "$abs" 2>/dev/null | awk '{ print $1 }')" || return 1
    [ -n "$h" ] || return 1
    cache_put "$algo" "$abs" "$h"
    echo "$h"
}

# Fetch remote headers and effective URL over HTTPS
# F1: Inline -H @<(printf ...) to keep process substitution FD alive for curl
remote_head() {
    local url="$1" auth="$2"
    if [ "$auth" = "hf" ] && [ -n "$HF_TOKEN" ]; then
        curl -sS -I "${CURL_HTTPS_OPTS[@]}" \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time 30 \
            -H @<(printf 'Authorization: Bearer %s' "$HF_TOKEN") \
            -w '%{url_effective}' \
            -- "$url" 2>/dev/null || true
    elif [ "$auth" = "civitai" ] && [ -n "$CIVITAI_TOKEN" ]; then
        curl -sS -I "${CURL_HTTPS_OPTS[@]}" \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time 30 \
            -H @<(printf 'Authorization: Bearer %s' "$CIVITAI_TOKEN") \
            -w '%{url_effective}' \
            -- "$url" 2>/dev/null || true
    else
        curl -sS -I "${CURL_HTTPS_OPTS[@]}" \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time 30 \
            -w '%{url_effective}' \
            -- "$url" 2>/dev/null || true
    fi
}

# Extract host from URL
extract_host() {
    local u="$1"
    printf '%s' "$u" | awk -F/ '{print $3}' | cut -d: -f1
}

# CivitAI: fetch model version info via HTTPS
# F1: Inline -H @<(printf ...) to keep process substitution FD alive for curl
civitai_file_info() {
    local version_id="$1" file_id="$2"
    local py_filter='
import json, os, sys
fid = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
files = d.get("files") or []
match = None
if fid:
    for f in files:
        if str(f.get("id")) == str(fid):
            match = f
            break
if not match and files:
    match = files[0]
if match:
    name = os.path.basename(str(match.get("name") or "")).replace("\t", " ")
    sha = str((match.get("hashes") or {}).get("SHA256") or "").lower()
    print(name + "\t" + sha)
'
    if [ -n "$CIVITAI_TOKEN" ]; then
        curl -sS "${CURL_HTTPS_OPTS[@]}" \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time 30 \
            -H @<(printf 'Authorization: Bearer %s' "$CIVITAI_TOKEN") \
            -- "https://civitai.com/api/v1/model-versions/${version_id}" 2>/dev/null \
        | python3 -c "$py_filter" "$file_id" 2>/dev/null || true
    else
        curl -sS "${CURL_HTTPS_OPTS[@]}" \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time 30 \
            -- "https://civitai.com/api/v1/model-versions/${version_id}" 2>/dev/null \
        | python3 -c "$py_filter" "$file_id" 2>/dev/null || true
    fi
}

# Nit 6: Safe filename validation rejecting bidi override/isolate marks and control characters
safe_filename() {
    local name="$1"
    [ -z "$name" ] && return 1
    if [[ "$name" == .* || "$name" == */* || "$name" == *"\\"* || "$name" == -* ]]; then
        return 1
    fi
    if [[ "$name" =~ [[:cntrl:]] ]]; then
        return 1
    fi
    # Check for C0/C1 control characters and Unicode bidi overrides/isolates:
    # C0 (0x01-0x1F), DEL (0x7F), C1 (\xC2[\x80-\x9F]),
    # Bidi Marks: U+200E/U+200F (\xE2\x80[\x8E\x8F]), U+202A-U+202E (\xE2\x80[\xAA-\xAE]),
    # Bidi Isolates: U+2066-U+2069 (\xE2\x81[\xA6-\xA9]), ALM: U+061C (\xD8\x9C)
    if printf '%s' "$name" | LC_ALL=C grep -qE $'[\x01-\x1f\x7f]|\xc2[\x80-\x9f]|\xe2\x80[\x8e\x8f\xaa-\xae]|\xe2\x81[\xa6-\xa9]|\xd8\x9c' 2>/dev/null; then
        return 1
    fi
    return 0
}

# Nit 4: Check original destination for symlinks
safe_dest() {
    local dest="$1" filename parent
    filename="$(basename -- "$dest")"
    parent="$(dirname -- "$dest")"
    if ! safe_filename "$filename"; then
        echo "  ⚠ Refusing unsafe file name: $filename" >&2
        return 1
    fi
    if [ -L "$dest" ] || [ -L "$dest.part" ]; then
        echo "  ⚠ Refusing symlink destination: $dest" >&2
        return 1
    fi
    if ! inside_models_dir "$parent"; then
        echo "  ⚠ Refusing destination outside ${MODELS_DIR}: $dest" >&2
        return 1
    fi
    return 0
}

# Free disk space check with headroom
check_disk_space() {
    local target_dir="$1" expected_bytes="${2:-0}"
    local avail_kb needed_kb
    avail_kb="$(df -k -- "$target_dir" 2>/dev/null | awk 'NR==2 {print $4}')" || return 0
    if [ -z "$avail_kb" ] || ! [[ "$avail_kb" =~ ^[0-9]+$ ]]; then
        return 0
    fi
    if ! [[ "$expected_bytes" =~ ^[0-9]+$ ]]; then
        expected_bytes=0
    fi

    if [ "$expected_bytes" -gt 0 ]; then
        needed_kb=$(( (expected_bytes + 1023) / 1024 + DISK_HEADROOM_KB ))
    else
        needed_kb="$DISK_HEADROOM_KB"
    fi

    if [ "$avail_kb" -lt "$needed_kb" ]; then
        echo "  ⚠ Insufficient disk space in $target_dir (need ${needed_kb} KB, available ${avail_kb} KB); skipping" >&2
        return 1
    fi
    return 0
}

# Nit 5: Approved pickle host check
is_approved_pickle_host() {
    local h="$1"
    case "$h" in
        huggingface.co|*.huggingface.co|civitai.com|*.civitai.com) return 0 ;;
        127.0.0.1|localhost)
            [ "${MSS_ALLOW_TEST_HOSTS:-}" = "true" ] && return 0
            return 1
            ;;
        *) return 1 ;;
    esac
}

# Download file with resume to .part, sha256 check, and atomic rename
# F1: Inline -H @<(printf ...) to keep process substitution FD alive for curl
download_file() {
    local url="$1" dest="$2" auth="$3" pinned_sha="$4" expected_size="${5:-0}"
    local part="$dest.part" rc=0 actual_sha=""

    safe_dest "$dest" || return 1

    if ! check_disk_space "$(dirname -- "$dest")" "$expected_size"; then
        return 1
    fi

    if [ "$FORCE_DOWNLOAD" = true ]; then
        rm -f -- "$part"
    fi

    if [ -f "$part" ]; then
        local psize
        psize="$(file_size "$part")"
        if [ "$psize" -ge "$MAX_FILESIZE_BYTES" ]; then
            rm -f -- "$part"
        elif [ "$expected_size" -gt 0 ] && [ "$psize" -ge "$expected_size" ]; then
            rm -f -- "$part"
        fi
    fi

    if [ "$auth" = "hf" ] && [ -n "$HF_TOKEN" ]; then
        curl "${CURL_HTTPS_OPTS[@]}" \
            --retry 3 \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time "$MAX_TIME" \
            --max-filesize "$MAX_FILESIZE_BYTES" \
            -C - \
            -H @<(printf 'Authorization: Bearer %s' "$HF_TOKEN") \
            -o "$part" \
            -- "$url" || rc=$?
    elif [ "$auth" = "civitai" ] && [ -n "$CIVITAI_TOKEN" ]; then
        curl "${CURL_HTTPS_OPTS[@]}" \
            --retry 3 \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time "$MAX_TIME" \
            --max-filesize "$MAX_FILESIZE_BYTES" \
            -C - \
            -H @<(printf 'Authorization: Bearer %s' "$CIVITAI_TOKEN") \
            -o "$part" \
            -- "$url" || rc=$?
    else
        curl "${CURL_HTTPS_OPTS[@]}" \
            --retry 3 \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time "$MAX_TIME" \
            --max-filesize "$MAX_FILESIZE_BYTES" \
            -C - \
            -o "$part" \
            -- "$url" || rc=$?
    fi

    # Nit 7: on junk .part and no range support (curl exit 33), delete only that validated
    # destination's partial file and retry cleanly once.
    if [ "$rc" -eq 33 ] && [ -f "$part" ]; then
        echo "  ⚠ Server does not support resume or .part corrupted (curl exit 33); removing partial file and retrying cleanly once..." >&2
        rm -f -- "$part"
        rc=0
        if [ "$auth" = "hf" ] && [ -n "$HF_TOKEN" ]; then
            curl "${CURL_HTTPS_OPTS[@]}" \
                --connect-timeout "$CONNECT_TIMEOUT" \
                --max-time "$MAX_TIME" \
                --max-filesize "$MAX_FILESIZE_BYTES" \
                -H @<(printf 'Authorization: Bearer %s' "$HF_TOKEN") \
                -o "$part" \
                -- "$url" || rc=$?
        elif [ "$auth" = "civitai" ] && [ -n "$CIVITAI_TOKEN" ]; then
            curl "${CURL_HTTPS_OPTS[@]}" \
                --connect-timeout "$CONNECT_TIMEOUT" \
                --max-time "$MAX_TIME" \
                --max-filesize "$MAX_FILESIZE_BYTES" \
                -H @<(printf 'Authorization: Bearer %s' "$CIVITAI_TOKEN") \
                -o "$part" \
                -- "$url" || rc=$?
        else
            curl "${CURL_HTTPS_OPTS[@]}" \
                --connect-timeout "$CONNECT_TIMEOUT" \
                --max-time "$MAX_TIME" \
                --max-filesize "$MAX_FILESIZE_BYTES" \
                -o "$part" \
                -- "$url" || rc=$?
        fi
    fi

    if [ "$rc" -ne 0 ] || [ ! -s "$part" ]; then
        echo "  ⚠ Failed to download $(sanitize_url "$url") (exit $rc); partial kept at $(sanitize_url "$part") for resume" >&2
        return 1
    fi

    echo "  Verifying sha256..."
    # Nit 2: Hardcode sha256sum
    actual_sha="$(sha256sum -- "$part" 2>/dev/null | awk '{ print $1 }')" || actual_sha=""
    if [ "$actual_sha" != "$pinned_sha" ]; then
        echo "  ⚠ Checksum mismatch after download (expected $pinned_sha, got ${actual_sha:-unknown}); deleting partial file" >&2
        rm -f -- "$part"
        return 1
    fi

    mv -f -- "$part" "$dest"
    cache_put "sha256" "$dest" "$actual_sha"
    echo "  ✓ Saved $(basename -- "$dest") ($(human_size "$(file_size "$dest")"))"
    return 0
}

# Resolve target directory based on model type
get_target_dir() {
    local type="$1"
    if [ -n "$MODELS_DOWNLOAD_DIR" ]; then
        echo "$MODELS_DOWNLOAD_DIR"
        return
    fi

    case "$type" in
        checkpoint|ckpt|checkpoints)
            echo "$MODELS_DIR/checkpoints"
            ;;
        lora|loras|lycoris)
            echo "$MODELS_DIR/loras"
            ;;
        vae)
            echo "$MODELS_DIR/vae"
            ;;
        controlnet|cn)
            echo "$MODELS_DIR/controlnet"
            ;;
        upscale|upscaler|upscale_models)
            echo "$MODELS_DIR/upscale_models"
            ;;
        embedding|embeddings|textual_inversion)
            echo "$MODELS_DIR/embeddings"
            ;;
        clip)
            echo "$MODELS_DIR/clip"
            ;;
        clip_vision)
            echo "$MODELS_DIR/clip_vision"
            ;;
        text_encoders|text_encoder)
            echo "$MODELS_DIR/text_encoders"
            ;;
        unet)
            echo "$MODELS_DIR/unet"
            ;;
        diffusion|diffusion_models)
            echo "$MODELS_DIR/diffusion_models"
            ;;
        background_removal|bg_removal)
            echo "$MODELS_DIR/background_removal"
            ;;
        *)
            echo "$MODELS_DIR/$type"
            ;;
    esac
}

echo "[Models] Base models directory: $MODELS_DIR"
if [ "$FORCE_DOWNLOAD" = true ]; then
    echo "[Models] Force mode: existing files will be re-downloaded"
fi

# Create common subfolders
mkdir -p -- \
  "$MODELS_DIR/checkpoints" \
  "$MODELS_DIR/loras" \
  "$MODELS_DIR/vae" \
  "$MODELS_DIR/controlnet" \
  "$MODELS_DIR/upscale_models" \
  "$MODELS_DIR/embeddings" \
  "$MODELS_DIR/clip" \
  "$MODELS_DIR/clip_vision" \
  "$MODELS_DIR/text_encoders" \
  "$MODELS_DIR/unet" \
  "$MODELS_DIR/diffusion_models" \
  "$MODELS_DIR/background_removal"

# Support MODELS_TO_DOWNLOAD environment variable
if [ -n "$MODELS_TO_DOWNLOAD" ]; then
    ENV_LIST="$(mktemp)"
    printf '%s\n' "$MODELS_TO_DOWNLOAD" | tr ',' '\n' > "$ENV_LIST"
    LIST_FILE="$ENV_LIST"
fi

if [ ! -f "$LIST_FILE" ]; then
    echo "[Models] No models-to-download.txt found and MODELS_TO_DOWNLOAD not set. Skipping."
    [ -n "${ENV_LIST:-}" ] && rm -f -- "$ENV_LIST"
    exit 0
fi

echo "[Models] Processing download list from: $LIST_FILE"
echo "------------------------------------------------------------"

declare -A SEEN_MANIFEST=()

while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    # Strip Windows CRLF line endings
    raw_line="${raw_line%$'\r'}"

    # Skip empty lines and comments
    [[ -z "$raw_line" || "$raw_line" =~ ^[[:space:]]*# ]] && continue

    line="${raw_line#"${raw_line%%[![:space:]]*}"}"   # trim leading
    line="${line%"${line##*[![:space:]]}"}"           # trim trailing
    [ -z "$line" ] && continue

    # Reject leading option injection on the raw line
    if [[ "$line" == -* ]]; then
        echo "[Models] ⚠ Refusing entry starting with '-': $(sanitize_url "$line")" >&2
        continue
    fi

    # Parse pinning sha256 and source
    pinned_sha=""
    work_line="$line"

    # Format A: url#sha256=... or url#...
    if [[ "$work_line" =~ \#([0-9a-fA-F]{64})$ ]]; then
        pinned_sha="${BASH_REMATCH[1],,}"
        work_line="${work_line%#*}"
    elif [[ "$work_line" =~ \#sha256=([0-9a-fA-F]{64})$ ]]; then
        pinned_sha="${BASH_REMATCH[1],,}"
        work_line="${work_line%#*}"
    else
        # Format B: space-separated: <sha256> <source> OR <source> <sha256>
        first_token="${work_line%%[[:space:]]*}"
        last_token="${work_line##*[[:space:]]}"
        if [[ "$first_token" =~ ^[0-9a-fA-F]{64}$ ]]; then
            pinned_sha="${first_token,,}"
            work_line="${work_line#*[[:space:]]}"
            work_line="${work_line#"${work_line%%[![:space:]]*}"}"
        elif [[ "$last_token" =~ ^[0-9a-fA-F]{64}$ ]]; then
            pinned_sha="${last_token,,}"
            work_line="${work_line%[[:space:]]*}"
            work_line="${work_line%"${work_line##*[![:space:]]}"}"
        fi
    fi

    # Parse optional type prefix
    model_type="checkpoint"
    source="$work_line"

    if [[ "$work_line" == *:* ]]; then
        possible_type="${work_line%%:*}"
        case "$possible_type" in
            checkpoint|ckpt|checkpoints|lora|loras|lycoris|vae|controlnet|cn|upscale|upscaler|upscale_models|embedding|embeddings|textual_inversion|clip|clip_vision|text_encoders|text_encoder|unet|diffusion|diffusion_models|background_removal|bg_removal)
                model_type="$possible_type"
                source="${work_line#*:}"
                ;;
        esac
    fi

    # Option injection check on source/URL
    if [[ "$source" == -* ]]; then
        echo "[Models] ⚠ Refusing URL starting with '-': $(sanitize_url "$source")" >&2
        continue
    fi

    TARGET_DIR="$(get_target_dir "$model_type")"
    if ! inside_models_dir "$TARGET_DIR"; then
        # Nit 3: Sanitize line before printing
        echo "[Models] ⚠ Target ${TARGET_DIR} resolves outside ${MODELS_DIR}; skipping: $(sanitize_url "$line")" >&2
        continue
    fi
    mkdir -p -- "$TARGET_DIR"

    # Determine URL, auth, and filename
    url=""
    auth="none"
    filename=""

    if [[ "$source" == hf:* ]]; then
        repo_path="${source#hf:}"
        if [[ "$repo_path" == */*/* ]]; then
            hf_repo="${repo_path%%/*}/$(printf '%s' "$repo_path" | cut -d/ -f2)"
            hf_file="$(printf '%s' "$repo_path" | cut -d/ -f3-)"
            url="https://huggingface.co/${hf_repo}/resolve/main/${hf_file}"
            filename="$(basename -- "$hf_file")"
            auth="hf"
        else
            # Nit 3: Sanitize source before printing
            echo "[Models] ⚠ HuggingFace whole-repository downloads are unpinned; refusing: $(sanitize_url "$source")" >&2
            continue
        fi

    elif [[ "$source" == civitai:* ]]; then
        model_id="${source#civitai:}"
        url="https://civitai.com/api/download/models/${model_id}"
        auth="civitai"
        civitai_info="$(civitai_file_info "$model_id" "")"
        cv_name="${civitai_info%%$'\t'*}"
        if [ -n "$cv_name" ]; then
            filename="$cv_name"
        else
            filename="civitai_${model_id}.safetensors"
        fi

    elif [[ "$source" == https://* ]]; then
        url="$source"
        if [[ "$source" =~ ^https://huggingface\.co/[^/]+/[^/]+/resolve/ ]]; then
            auth="hf"
            filename="$(basename -- "$source" | cut -d'?' -f1)"
        elif [[ "$source" =~ ^https://(www\.)?civitai\.com/api/download/models/([0-9]+) ]]; then
            auth="civitai"
            cv_ver="${BASH_REMATCH[2]}"
            cv_fid=""
            [[ "$source" =~ [?\&]fileId=([0-9]+) ]] && cv_fid="${BASH_REMATCH[1]}"
            civitai_info="$(civitai_file_info "$cv_ver" "$cv_fid")"
            cv_name="${civitai_info%%$'\t'*}"
            if [ -n "$cv_name" ]; then
                filename="$cv_name"
            else
                filename="$(basename -- "$source" | cut -d'?' -f1)"
            fi
        else
            filename="$(basename -- "$source" | cut -d'?' -f1)"
        fi

    elif [[ "$source" == http://* ]]; then
        echo "[Models] ⚠ Refusing non-HTTPS URL: $(sanitize_url "$source")" >&2
        # Extract filename so unsafe name checks can still be reported if applicable
        filename="$(basename -- "$source" | cut -d'?' -f1)"
        if ! safe_filename "$filename"; then
            echo "  ⚠ Refusing unsafe file name: $filename" >&2
        fi
        continue

    else
        echo "[Models] ⚠ Unknown source format: $(sanitize_url "$source")" >&2
        continue
    fi

    # Decode %2F, %5C, %2E to prevent URL-encoding filter bypass
    filename="${filename//%2[fF]/\/}"
    filename="${filename//%5[cC]/\\}"
    filename="${filename//%2[eE]/\.}"

    # Validate filename
    if ! safe_filename "$filename"; then
        echo "  ⚠ Refusing unsafe file name: $filename" >&2
        continue
    fi

    # Nit 4: Check original destination for symlinks BEFORE realpath resolves it
    if [ -L "$TARGET_DIR/$filename" ] || [ -L "$TARGET_DIR/$filename.part" ]; then
        echo "  ⚠ Refusing symlink destination: $TARGET_DIR/$filename" >&2
        continue
    fi

    dest="$TARGET_DIR/$filename"
    if ! inside_models_dir "$dest"; then
        echo "  ⚠ Refusing destination outside ${MODELS_DIR}: $dest" >&2
        continue
    fi

    # Pinning check: sha256 is required for every entry
    if [ -z "$pinned_sha" ]; then
        echo "[Models] ⚠ Refusing unpinned entry (sha256 required): $(sanitize_url "$source")" >&2
        continue
    fi

    # Nit 5: Pickle formats (.ckpt, .pt, .pth, .bin, .pkl, .pickle, .joblib) restriction
    file_ext=".${filename##*.}"
    file_ext="${file_ext,,}"
    case "$file_ext" in
        .ckpt|.pt|.pth|.bin|.pkl|.pickle|.joblib)
            url_host="$(extract_host "$url")"
            if ! is_approved_pickle_host "$url_host"; then
                echo "[Models] ⚠ Refusing pickle file from disallowed host: $url_host" >&2
                continue
            fi
            effective_output="$(remote_head "$url" "$auth")"
            effective_url="${effective_output##*$'\n'}"
            [ -z "$effective_url" ] && effective_url="$url"
            effective_host="$(extract_host "$effective_url")"
            if ! is_approved_pickle_host "$effective_host"; then
                echo "[Models] ⚠ Refusing pickle file from disallowed redirect host: $effective_host" >&2
                continue
            fi
            ;;
    esac

    # Manifest collision check
    if [ -n "${SEEN_MANIFEST["$filename"]:-}" ]; then
        if [ "${SEEN_MANIFEST["$filename"]}" != "$pinned_sha" ]; then
            echo "[Models] ⚠ Refusing name collision in manifest for $filename (conflicting sha256)" >&2
        else
            echo "[Models] ⚠ Refusing duplicate manifest entry: $filename" >&2
        fi
        continue
    fi
    SEEN_MANIFEST["$filename"]="$pinned_sha"

    # Disk collision check
    if [ -s "$dest" ]; then
        local_sha="$(local_hash "sha256" "$dest" || true)"
        if [ "$local_sha" = "$pinned_sha" ]; then
            if [ "$FORCE_DOWNLOAD" != true ]; then
                echo "  ✓ Already downloaded (sha256 matches) → skipping: $filename"
                continue
            fi
        else
            echo "[Models] ⚠ Refusing name collision: $filename already exists with a different hash" >&2
            continue
        fi
    fi

    echo "[Models] Type: $model_type"
    echo "         Source: $(sanitize_url "$source")"
    echo "         → Target: $TARGET_DIR/$filename"

    # Fetch remote size if available
    remote_size=0
    head_output="$(remote_head "$url" "$auth")"
    clength="$(printf '%s\n' "$head_output" | header_value "content-length")"
    if [[ "$clength" =~ ^[0-9]+$ ]]; then
        remote_size="$clength"
    fi

    download_file "$url" "$dest" "$auth" "$pinned_sha" "$remote_size" || true
    echo "------------------------------------------------------------"

done < "$LIST_FILE"

[ -n "${ENV_LIST:-}" ] && rm -f -- "$ENV_LIST"
echo "[Models] Finished processing download list."
exit 0
