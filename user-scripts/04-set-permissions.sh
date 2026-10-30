#!/bin/bash

# ============================================================
# Set ownership on ComfyUI shared folders
# ============================================================
# Configurable via environment:
#   COMFYUI_DIR       Base ComfyUI directory (default: /root/ComfyUI)
#   HOST_UID          Owner UID (default: 1000)
#   HOST_GID          Owner GID (default: 1000)
#   PERMS_DIRS        Space-separated relative paths under COMFYUI_DIR
#                     (overrides the default list when set)
#   PERMS_STRICT      If true/1, exit non-zero when any path fails
#                     (default: true)
# ============================================================

COMFYUI_DIR="${COMFYUI_DIR:-/app/ComfyUI}"
HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"
OWNER="${HOST_UID}:${HOST_GID}"

# Default shared folders relative to COMFYUI_DIR
DEFAULT_PERMS_DIRS=(
    "custom_nodes"
    "models"
    "${MSS_LOGIN_DATA_DIR:-/data/mss-login}"
    "${CACHE_DIR:-/data/cache}"
    "output"
    "user-scripts"
)

STRICT=true
case "${PERMS_STRICT,,}" in
    false|0|no|off) STRICT=false ;;
esac

# Build path list (absolute)
PATHS=()
if [ -n "$PERMS_DIRS" ]; then
    # shellcheck disable=SC2206
    REL_DIRS=($PERMS_DIRS)
else
    REL_DIRS=("${DEFAULT_PERMS_DIRS[@]}")
fi

for rel in "${REL_DIRS[@]}"; do
    # Allow absolute paths as-is; otherwise resolve under COMFYUI_DIR
    if [[ "$rel" == /* ]]; then
        PATHS+=("$rel")
    else
        PATHS+=("$COMFYUI_DIR/$rel")
    fi
done

echo "[Perms] Base directory: $COMFYUI_DIR"
echo "[Perms] Owner:          $OWNER"
echo "[Perms] Paths:          ${#PATHS[@]}"
echo "------------------------------------------------------------"

SUCCESS=0
FAILED=0
SKIPPED=0
FAILURES=()

# Bash "try/catch": run a command, capture stderr, return status
try() {
    local description="$1"
    shift
    local err_file
    local status=0

    err_file=$(mktemp)
    if "$@" 2>"$err_file"; then
        echo "  ✓ $description"
        rm -f "$err_file"
        return 0
    else
        status=$?
        echo "  ✗ $description (exit $status)"
        if [ -s "$err_file" ]; then
            # Indent error output for readability
            sed 's/^/      /' "$err_file"
        fi
        rm -f "$err_file"
        return "$status"
    fi
}

# Apply ownership to one path; create directory if missing
set_path_permissions() {
    local path="$1"
    local label

    label="${path#"$COMFYUI_DIR"/}"
    [ "$label" = "$path" ] && label="$path"

    echo "[Perms] → $label"

    # Ensure directory exists
    if [ ! -e "$path" ]; then
        if ! try "create missing directory: $path" mkdir -p "$path"; then
            FAILURES+=("$path (mkdir failed)")
            FAILED=$((FAILED + 1))
            return 1
        fi
    elif [ ! -d "$path" ]; then
        echo "  ⚠ Not a directory — skipping: $path"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    if ! try "chown -R $OWNER $path" chown -R "$OWNER" "$path"; then
        FAILURES+=("$path (chown failed)")
        FAILED=$((FAILED + 1))
        return 1
    fi

    SUCCESS=$((SUCCESS + 1))
    return 0
}

# Process each path independently (one failure does not abort the rest)
for path in "${PATHS[@]}"; do
    set_path_permissions "$path" || true
    echo "------------------------------------------------------------"
done

echo "[Perms] Done — success: $SUCCESS, failed: $FAILED, skipped: $SKIPPED"

if [ "$FAILED" -gt 0 ]; then
    echo "[Perms] Failures:"
    for f in "${FAILURES[@]}"; do
        echo "  - $f"
    done
    if [ "$STRICT" = true ]; then
        exit 1
    fi
fi

exit 0
