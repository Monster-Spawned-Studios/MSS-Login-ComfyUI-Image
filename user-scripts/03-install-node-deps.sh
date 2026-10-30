#!/bin/bash
set -e

# ============================================================
# Logging setup
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/node-deps.log"

# Normalize INSTALL_DEBUG (accepts true/false/1/0)
DEBUG=false
case "${INSTALL_DEBUG,,}" in
    true|1|yes|on) DEBUG=true ;;
esac

log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Always write to log file
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"

    # Console output
    if [ "$DEBUG" = true ] || [ "$level" = "INFO" ] || [ "$level" = "ERROR" ] || [ "$level" = "WARN" ]; then
        echo "[NodeDeps] $msg"
    fi
}

log_debug() {
    if [ "$DEBUG" = true ]; then
        log "DEBUG" "$*"
    fi
}

# ============================================================
# Main logic
# ============================================================

CUSTOM_NODES_DIR="${COMFYUI_CUSTOM_NODES_DIR:-/app/ComfyUI/custom_nodes}"

log "INFO" "Scanning $CUSTOM_NODES_DIR for requirements.txt files..."
log_debug "INSTALL_DEBUG is enabled"
log_debug "Log file: $LOG_FILE"

# Ensure uv is available
if ! command -v uv &> /dev/null; then
    log "INFO" "uv not found – installing uv..."
    if curl -LsSf https://astral.sh/uv/install.sh | sh >> "$LOG_FILE" 2>&1; then
        export PATH="$HOME/.local/bin:$PATH"
        log "INFO" "uv installed successfully."
    else
        log "WARN" "Failed to install uv. Will fall back to pip."
    fi
else
    log_debug "uv is already available."
fi

# Prefer uv, fall back to pip
if command -v uv &> /dev/null; then
    INSTALL_CMD="uv pip install --no-cache"
    log "INFO" "Using uv as package manager."
else
    INSTALL_CMD="pip install --no-cache-dir"
    log "INFO" "uv not available – falling back to pip."
fi

log_debug "Install command: $INSTALL_CMD"

# Count how many requirements files we find
req_count=0
success_count=0
fail_count=0
skip_count=0

while IFS= read -r -d '' req_file; do
    ((req_count++)) || true
    node_name=$(basename "$(dirname "$req_file")")

    log "INFO" "Processing: $node_name"
    log_debug "requirements.txt path: $req_file"

    # Skip empty requirements files
    if [ ! -s "$req_file" ]; then
        log "INFO" "  → Empty requirements.txt – skipping."
        ((skip_count++)) || true
        continue
    fi

    log_debug "  Installing dependencies for $node_name..."

    if $INSTALL_CMD -r "$req_file" >> "$LOG_FILE" 2>&1; then
        log "INFO" "  → Successfully installed dependencies for $node_name"
        ((success_count++)) || true
    else
        log "WARN" "  → Failed to install some packages for $node_name (see log for details)"
        ((fail_count++)) || true
    fi

done < <(find "$CUSTOM_NODES_DIR" -maxdepth 2 -name "requirements.txt" -print0 2>/dev/null)

log "INFO" "Finished updating custom node dependencies."
log "INFO" "Summary: $req_count found | $success_count success | $fail_count failed | $skip_count skipped"

if [ "$DEBUG" = true ]; then
    log_debug "Full log available at: $LOG_FILE"
fi
