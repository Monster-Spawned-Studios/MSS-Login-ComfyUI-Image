#!/bin/bash
set -e

# ============================================================
# Model downloader baked into the image (root:root 0755, /usr/local/bin).
# Carried over from user-scripts/01-download-models.sh (development 9dc33b1).
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
# Skip / re-download behaviour (added 2026-10-07):
#   - If the remote side publishes a checksum (HF: LFS sha256 via X-Linked-ETag,
#     CivitAI: files[].hashes.SHA256, other URLs: md5/sha256 ETag, Content-MD5 or
#     Digest header) the local file is hashed and skipped when it matches;
#     on mismatch it is re-downloaded.
#   - Without a checksum, an existing non-empty file is skipped (unless the
#     remote size is known and differs).
#   - Downloads go to "<file>.part" and are moved into place atomically after
#     the checksum (when known) has been verified.
#   - Local hashes are cached in $MODELS_DIR/.download-hash-cache.tsv.
#
#   --force / -f  or  MODELS_FORCE_DOWNLOAD=1   re-download everything
#   MODELS_HASH_CHECK=0                         compare sizes only, never hash
#   HF_TOKEN (or HUGGING_FACE_HUB_TOKEN)        sent only to huggingface.co
#   CIVITAI_TOKEN                               sent only to civitai.com
# ============================================================

if [ "$(id -u)" -eq 0 ]; then
    echo "[Models] Refusing to run as root. The entrypoint runs this as uid 1000." >&2
    exit 1
fi

MODELS_DIR="$(realpath -m -- "${MODELS_DIR:-/app/ComfyUI/models}")"
LIST_FILE="${MSS_MODELS_LIST:-/home/comfy/user-scripts/models-to-download.txt}"

# True when $1 (resolved, may not exist yet) is MODELS_DIR or inside it.
inside_models_dir() {
    local p
    p="$(realpath -m -- "$1")" || return 1
    [[ "$p" == "$MODELS_DIR" || "$p" == "$MODELS_DIR"/* ]]
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

HASH_CHECK=true
case "${MODELS_HASH_CHECK,,}" in
    false|0|no|off) HASH_CHECK=false ;;
esac
HASH_CACHE="$MODELS_DIR/.download-hash-cache.tsv"
HF_TOKEN="${HF_TOKEN:-$HUGGING_FACE_HUB_TOKEN}"

echo "[Models] Base models directory: $MODELS_DIR"
if [ "$FORCE_DOWNLOAD" = true ]; then
    echo "[Models] Force mode: existing files will be re-downloaded"
fi

# Create common subfolders
mkdir -p \
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

# Also support environment variable (comma or newline separated)
if [ -n "$MODELS_TO_DOWNLOAD" ]; then
    ENV_LIST="$(mktemp)"
    trap 'rm -f "$ENV_LIST"' EXIT
    printf '%s\n' "$MODELS_TO_DOWNLOAD" | tr ',' '\n' > "$ENV_LIST"
    LIST_FILE="$ENV_LIST"
fi

if [ ! -f "$LIST_FILE" ]; then
    echo "[Models] No models-to-download.txt found and MODELS_TO_DOWNLOAD not set. Skipping."
    exit 0
fi

echo "[Models] Processing download list from: $LIST_FILE"
echo "------------------------------------------------------------"

# Helper: resolve target directory based on type
get_target_dir() {
    local type="$1"

    # If user forced a single download directory, always use it
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
            # Default fallback
            echo "$MODELS_DIR/checkpoints"
            ;;
    esac
}

# ------------------------------------------------------------
# Checksum / skip helpers
# ------------------------------------------------------------

# Remote metadata for the current entry (filled by the *_remote_meta helpers)
REMOTE_ALGO=""   # sha256 | md5
REMOTE_HASH=""   # lowercase hex
REMOTE_SIZE=""   # bytes, only when exact

reset_remote_meta() { REMOTE_ALGO=""; REMOTE_HASH=""; REMOTE_SIZE=""; }

file_size()  { stat -c %s "$1" 2>/dev/null || echo 0; }
file_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }

human_size() {
    awk -v b="$1" 'BEGIN { split("B KB MB GB TB", u, " "); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } printf "%.1f %s", b, u[i] }'
}

# Tokens are passed to curl through a header "file" (process substitution) so
# they never show up in the process list or in this script's output.
curl_hf() {
    if [ -n "$HF_TOKEN" ]; then
        curl -H @<(printf 'Authorization: Bearer %s\n' "$HF_TOKEN") "$@"
    else
        curl "$@"
    fi
}

curl_civitai() {
    if [ -n "$CIVITAI_TOKEN" ]; then
        curl -H @<(printf 'Authorization: Bearer %s\n' "$CIVITAI_TOKEN") "$@"
    else
        curl "$@"
    fi
}

# Header value (last occurrence, case-insensitive) from a block of headers on stdin
header_value() {
    awk -v h="$1" 'BEGIN { h = tolower(h) }
        { line = $0; sub(/\r$/, "", line); i = index(line, ":");
          if (i > 0 && tolower(substr(line, 1, i - 1)) == h) { v = substr(line, i + 1); sub(/^[ \t]+/, "", v); val = v } }
        END { if (val != "") print val }'
}

b64_to_hex() { printf '%s' "$1" | base64 -d 2>/dev/null | od -An -v -tx1 | tr -d ' \n'; }

cache_put() {  # algo path hash
    local algo="$1" path="$2" hash="$3" abs size mtime
    abs=$(readlink -f "$path") || return 0
    size=$(file_size "$abs"); mtime=$(file_mtime "$abs")
    if [ -f "$HASH_CACHE" ]; then
        if awk -F'\t' -v a="$algo" -v p="$abs" '!($1 == a && $2 == p)' "$HASH_CACHE" > "$HASH_CACHE.tmp.$$" 2>/dev/null; then
            mv -f "$HASH_CACHE.tmp.$$" "$HASH_CACHE"
        else
            rm -f "$HASH_CACHE.tmp.$$"
        fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$algo" "$abs" "$size" "$mtime" "$hash" >> "$HASH_CACHE" 2>/dev/null || true
}

local_hash() {  # algo path -> hex (cached by path+size+mtime)
    local algo="$1" path="$2" abs size mtime hit h
    abs=$(readlink -f "$path") || return 1
    size=$(file_size "$abs"); mtime=$(file_mtime "$abs")
    if [ -f "$HASH_CACHE" ]; then
        hit=$(awk -F'\t' -v a="$algo" -v p="$abs" -v s="$size" -v m="$mtime" \
            '$1 == a && $2 == p && $3 == s && $4 == m { h = $5 } END { if (h != "") print h }' "$HASH_CACHE" 2>/dev/null) || hit=""
        if [ -n "$hit" ]; then
            echo "  (cached $algo)" >&2
            echo "$hit"
            return 0
        fi
    fi
    echo "  Hashing local file ($algo, $(human_size "$size"))..." >&2
    h=$("${algo}sum" "$abs" | awk '{ print $1 }') || return 1
    [ -n "$h" ] || return 1
    cache_put "$algo" "$abs" "$h"
    echo "$h"
}

# HuggingFace resolve URL: HEAD without following the redirect. LFS files return
# X-Linked-ETag = sha256 and X-Linked-Size. Small non-LFS files only expose a git
# sha1 (not a file hash), which is ignored.
hf_remote_meta() {
    local url="$1" hdrs etag size
    hdrs=$(curl_hf -sS -I --max-time 30 "$url" 2>/dev/null) || return 0
    etag=$(printf '%s\n' "$hdrs" | header_value "x-linked-etag" | tr -d '"' | sed 's#^W/##' | tr 'A-F' 'a-f')
    size=$(printf '%s\n' "$hdrs" | header_value "x-linked-size")
    if [[ "$etag" =~ ^[0-9a-f]{64}$ ]]; then
        REMOTE_ALGO="sha256"; REMOTE_HASH="$etag"
    fi
    if [[ "$size" =~ ^[0-9]+$ ]]; then
        REMOTE_SIZE="$size"
    fi
}

# Generic URL: HEAD following redirects, use the final response only.
url_remote_meta() {
    local url="$1" hdrs etag digest cmd5 size hex
    hdrs=$(curl -sS -I -L --max-time 30 "$url" 2>/dev/null \
        | awk 'BEGIN { RS = "" } { last = $0 } END { print last }') || return 0
    etag=$(printf '%s\n' "$hdrs" | header_value "etag" | tr -d '"' | sed 's#^W/##' | tr 'A-F' 'a-f')
    digest=$(printf '%s\n' "$hdrs" | header_value "repr-digest")
    [ -n "$digest" ] || digest=$(printf '%s\n' "$hdrs" | header_value "digest")
    cmd5=$(printf '%s\n' "$hdrs" | header_value "content-md5")
    size=$(printf '%s\n' "$hdrs" | header_value "content-length")

    if [[ "$digest" =~ [Ss][Hh][Aa]-256=:?([A-Za-z0-9+/=]+) ]]; then
        hex=$(b64_to_hex "${BASH_REMATCH[1]}")
        [[ "$hex" =~ ^[0-9a-f]{64}$ ]] && { REMOTE_ALGO="sha256"; REMOTE_HASH="$hex"; }
    fi
    if [ -z "$REMOTE_HASH" ] && [ -n "$cmd5" ]; then
        hex=$(b64_to_hex "$cmd5")
        [[ "$hex" =~ ^[0-9a-f]{32}$ ]] && { REMOTE_ALGO="md5"; REMOTE_HASH="$hex"; }
    fi
    if [ -z "$REMOTE_HASH" ]; then
        if [[ "$etag" =~ ^[0-9a-f]{64}$ ]]; then
            REMOTE_ALGO="sha256"; REMOTE_HASH="$etag"
        elif [[ "$etag" =~ ^[0-9a-f]{32}$ ]]; then
            # plain 32-hex ETag (no "-N" multipart suffix) = md5 of the object
            REMOTE_ALGO="md5"; REMOTE_HASH="$etag"
        fi
    fi
    if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ]; then
        REMOTE_SIZE="$size"
    fi
}

# CivitAI: model-versions API -> "name<TAB>sha256" for the given fileId (or the primary file)
civitai_file_info() {
    local version_id="$1" file_id="$2"
    curl_civitai -sS -f --max-time 30 "https://civitai.com/api/v1/model-versions/${version_id}" 2>/dev/null \
    | python3 -c '
import json, os, sys
fid = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
files = d.get("files") or []
f = next((x for x in files if fid and str(x.get("id")) == fid), None)
if f is None and not fid:
    f = next((x for x in files if x.get("primary")), files[0] if files else None)
if f:
    name = os.path.basename(str(f.get("name") or "")).replace("\t", " ")
    sha = str((f.get("hashes") or {}).get("SHA256") or "").lower()
    print(name + "\t" + sha)
' "$file_id" 2>/dev/null || true
}

civitai_remote_meta() {
    local info sha
    info=$(civitai_file_info "$1" "$2")
    sha="${info#*$'\t'}"
    if [[ "$sha" =~ ^[0-9a-f]{64}$ ]]; then
        REMOTE_ALGO="sha256"; REMOTE_HASH="$sha"
    fi
    CIVITAI_NAME="${info%%$'\t'*}"
}

# A download name must be a plain file name: no path, no leading dot.
safe_filename() {
    local name="$1"
    [[ -n "$name" && "$name" != .* && "$name" != */* && "$name" != *$'\n'* ]]
}

# Refuse a destination that resolves outside MODELS_DIR (for example through a
# symlinked type folder) or that is a symlink itself.
safe_dest() {
    local dest="$1"
    safe_filename "$(basename "$dest")" || { echo "  ⚠ Refusing unsafe file name: $(basename "$dest")"; return 1; }
    inside_models_dir "$(dirname "$dest")" || { echo "  ⚠ Refusing destination outside ${MODELS_DIR}: $dest"; return 1; }
    [ ! -L "$dest" ] && [ ! -L "$dest.part" ] || { echo "  ⚠ Refusing symlink destination: $dest"; return 1; }
}

# Returns 0 (skip) when the file at $1 is already good.
already_downloaded() {
    local dest="$1" lsize lhash
    # An unsafe destination is never downloaded: report it and skip.
    safe_dest "$dest" || return 0
    if [ "$FORCE_DOWNLOAD" = true ]; then
        return 1
    fi
    [ -s "$dest" ] || return 1
    lsize=$(file_size "$dest")

    if [ -n "$REMOTE_SIZE" ] && [ "$REMOTE_SIZE" != "$lsize" ]; then
        echo "  ⚠ Size differs (local $lsize, remote $REMOTE_SIZE) → re-downloading"
        return 1
    fi
    if [ -n "$REMOTE_HASH" ] && [ "$HASH_CHECK" = true ]; then
        lhash=$(local_hash "$REMOTE_ALGO" "$dest") || lhash=""
        if [ "$lhash" = "$REMOTE_HASH" ]; then
            echo "  ✓ Already downloaded ($REMOTE_ALGO matches) → skipping"
            return 0
        fi
        echo "  ⚠ $REMOTE_ALGO mismatch (local ${lhash:-?}, remote $REMOTE_HASH) → re-downloading"
        return 1
    fi
    if [ -n "$REMOTE_SIZE" ]; then
        echo "  ✓ Already downloaded (size matches, no checksum compared) → skipping"
    else
        echo "  ✓ Already exists ($(human_size "$lsize"), no remote checksum) → skipping"
    fi
    return 0
}

# download_file URL DEST AUTH(hf|civitai|none)
# Downloads to DEST.part (resumable), verifies the checksum if known, then mv.
download_file() {
    local url="$1" dest="$2" auth="$3" part="$2.part" rc=0 h=""
    safe_dest "$dest" || return 1

    if [ "$FORCE_DOWNLOAD" = true ]; then
        rm -f "$part"
    fi
    if [ -n "$REMOTE_SIZE" ] && [ -f "$part" ] && [ "$(file_size "$part")" -ge "$REMOTE_SIZE" ]; then
        rm -f "$part"   # stale or complete-but-unverified partial; start clean
    fi

    if [ "$auth" = "hf" ] && [ -n "$HF_TOKEN" ]; then
        curl_hf -fL --retry 3 -C - -o "$part" "$url" || rc=$?
    elif [ "$auth" = "civitai" ]; then
        curl_civitai -fL --retry 3 -C - -o "$part" "$url" || rc=$?
    elif command -v wget &> /dev/null; then
        wget -c -O "$part" "$url" || rc=$?
    else
        curl -fL --retry 3 -C - -o "$part" "$url" || rc=$?
    fi

    if [ "$rc" -ne 0 ] || [ ! -s "$part" ]; then
        echo "  ⚠ Failed to download $url (exit $rc); partial kept at $part for resume"
        return 1
    fi

    if [ -n "$REMOTE_HASH" ]; then
        echo "  Verifying $REMOTE_ALGO..."
        h=$("${REMOTE_ALGO}sum" "$part" | awk '{ print $1 }') || h=""
        if [ "$h" != "$REMOTE_HASH" ]; then
            echo "  ⚠ Checksum mismatch after download (expected $REMOTE_HASH, got ${h:-?}); discarding"
            rm -f "$part"
            return 1
        fi
    fi

    mv -f "$part" "$dest"
    if [ -n "$h" ]; then
        cache_put "$REMOTE_ALGO" "$dest" "$h"
    fi
    echo "  ✓ Saved $(basename "$dest") ($(human_size "$(file_size "$dest")"))"
}

while IFS= read -r line || [ -n "$line" ]; do
    # Skip empty lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    line="${line#"${line%%[![:space:]]*}"}"   # trim whitespace
    line="${line%"${line##*[![:space:]]}"}"

    # ----------------------------------------------------------
    # Parse optional type prefix
    # Supported formats:
    #   type:source
    #   source                    (defaults to checkpoint)
    #
    # Examples:
    #   checkpoint:hf:stabilityai/stable-diffusion-xl-base-1.0
    #   lora:https://...
    #   lora:civitai:123456
    #   vae:hf:stabilityai/sd-vae-ft-mse-original
    #   vae:hf:user/repo/path/in/repo/file.safetensors   (single file → TARGET_DIR/file.safetensors)
    #   background_removal:https://...                    (models/background_removal)
    #   hf:black-forest-labs/FLUX.1-dev          ← defaults to checkpoint
    # ----------------------------------------------------------
    model_type="checkpoint"
    source="$line"

    if [[ "$line" == *:* ]]; then
        # Check if the first part is a known type
        possible_type="${line%%:*}"
        case "$possible_type" in
            checkpoint|ckpt|checkpoints|lora|loras|lycoris|vae|controlnet|cn|upscale|upscaler|upscale_models|embedding|embeddings|textual_inversion|clip|clip_vision|text_encoders|text_encoder|unet|diffusion|diffusion_models|background_removal|bg_removal)
                model_type="$possible_type"
                source="${line#*:}"
                ;;
        esac
    fi

    TARGET_DIR=$(get_target_dir "$model_type")
    if ! inside_models_dir "$TARGET_DIR"; then
        echo "[Models] ⚠ Target ${TARGET_DIR} resolves outside ${MODELS_DIR}; skipping: $line"
        continue
    fi
    mkdir -p "$TARGET_DIR"

    echo "[Models] Type: $model_type"
    echo "         Source: $source"
    echo "         → Target: $TARGET_DIR"

    reset_remote_meta
    CIVITAI_NAME=""

    # ----------------------------------------------------------
    # Download logic
    # ----------------------------------------------------------
    if [[ "$source" == hf:* ]]; then
        # HuggingFace
        repo_path="${source#hf:}"

        if [[ "$repo_path" == */*/* ]]; then
            # Single file: user/repo/path/to/file
            hf_repo="${repo_path%%/*}/$(echo "$repo_path" | cut -d/ -f2)"
            hf_file="$(echo "$repo_path" | cut -d/ -f3-)"
            url="https://huggingface.co/${hf_repo}/resolve/main/${hf_file}"
            filename=$(basename "$hf_file")
            echo "  Downloading file from HuggingFace: $hf_repo → $filename"
            hf_remote_meta "$url"
            if ! already_downloaded "$TARGET_DIR/$filename"; then
                download_file "$url" "$TARGET_DIR/$filename" hf || true
            fi
        else
            # Whole repo (the hf CLI itself skips files that are already up to date)
            echo "  Downloading from HuggingFace: $repo_path"
            hf_force=()
            [ "$FORCE_DOWNLOAD" = true ] && hf_force=(--force-download)

            if command -v huggingface-cli &> /dev/null; then
                huggingface-cli download "$repo_path" \
                    --local-dir "$TARGET_DIR" \
                    --local-dir-use-symlinks False "${hf_force[@]}" || \
                echo "  ⚠ Failed to download $repo_path via huggingface-cli"
            elif command -v hf &> /dev/null; then
                hf download "$repo_path" --local-dir "$TARGET_DIR" "${hf_force[@]}" || \
                echo "  ⚠ Failed to download $repo_path via hf"
            else
                echo "  ⚠ Neither huggingface-cli nor hf found. Install huggingface_hub first."
            fi
        fi

    elif [[ "$source" == civitai:* ]]; then
        # CivitAI model version ID
        model_id="${source#civitai:}"
        echo "  Downloading from CivitAI model version ID: $model_id"

        if [ -z "$CIVITAI_TOKEN" ]; then
            echo "  ⚠ CIVITAI_TOKEN not set – some models may fail or be restricted"
        fi

        # Keep the historical file name so earlier downloads are recognised
        filename="civitai_${model_id}.safetensors"

        civitai_remote_meta "$model_id" ""
        if ! already_downloaded "$TARGET_DIR/$filename"; then
            download_file "https://civitai.com/api/download/models/${model_id}" "$TARGET_DIR/$filename" civitai || \
            echo "  ⚠ Failed to download CivitAI model $model_id"
        fi

    elif [[ "$source" == http* ]]; then
        # Direct URL
        filename=$(basename "$source" | cut -d'?' -f1)
        auth="none"

        if [[ "$source" =~ ^https://huggingface\.co/[^/]+/[^/]+/resolve/ ]]; then
            auth="hf"
            hf_remote_meta "$source"
        elif [[ "$source" =~ ^https://(www\.)?civitai\.com/api/download/models/([0-9]+) ]]; then
            auth="civitai"
            cv_version="${BASH_REMATCH[2]}"
            cv_file=""
            [[ "$source" =~ [?\&]fileId=([0-9]+) ]] && cv_file="${BASH_REMATCH[1]}"
            civitai_remote_meta "$cv_version" "$cv_file"
            [ -n "$CIVITAI_NAME" ] && filename="$CIVITAI_NAME"
        else
            url_remote_meta "$source"
        fi

        echo "  Downloading direct link → $filename"
        if ! already_downloaded "$TARGET_DIR/$filename"; then
            download_file "$source" "$TARGET_DIR/$filename" "$auth" || true
        fi

    else
        echo "  ⚠ Unknown source format: $source"
    fi

    echo "------------------------------------------------------------"

done < "$LIST_FILE"

echo "[Models] Finished processing download list."
