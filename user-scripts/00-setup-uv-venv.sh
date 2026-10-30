#!/bin/bash
set -e

# ============================================================
# UV Virtual Environment Setup for ComfyUI
# ============================================================

COMFYUI_DIR="${COMFYUI_DIR:-/app/ComfyUI}"
VENV_DIR="${VIRTUAL_ENV:-$COMFYUI_DIR/.venv}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/uv-venv.log"

# Normalize INSTALL_DEBUG
DEBUG=false
case "${INSTALL_DEBUG,,}" in
    true|1|yes|on) DEBUG=true ;;
esac

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$level] $msg" >> "$LOG_FILE"
    if [ "$DEBUG" = true ] || [ "$level" = "INFO" ] || [ "$level" = "ERROR" ] || [ "$level" = "WARN" ]; then
        echo "[UV-Venv] $msg"
    fi
}

log "INFO" "Setting up UV virtual environment..."

# Ensure uv is available
if ! command -v uv &> /dev/null; then
    log "INFO" "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
fi

# Create the venv if it doesn't exist
if [ ! -d "$VENV_DIR" ]; then
    log "INFO" "Creating new virtual environment at $VENV_DIR"
    uv venv "$VENV_DIR" --python 3.13
else
    log "INFO" "Existing virtual environment found at $VENV_DIR"
fi

# Activate it for the rest of the process
export VIRTUAL_ENV="$VENV_DIR"
export PATH="$VENV_DIR/bin:$PATH"

# Prefer venv nvidia libraries if present
_VSP="$VENV_DIR/lib64/python3.13/site-packages"
if [ ! -d "$_VSP" ]; then
    _VSP="$VENV_DIR/lib/python3.13/site-packages"
fi
if [ -d "$_VSP/torch/lib" ]; then
    export LD_LIBRARY_PATH="$_VSP/torch/lib:$_VSP/nvidia/cu13/lib:$_VSP/nvidia/cu12/lib:$_VSP/nvidia/cudnn/lib:$_VSP/nvidia/cusparselt/lib:$_VSP/nvidia/nccl/lib:$_VSP/nvidia/nvshmem/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
unset _VSP

# Make sure pip/uv inside the venv are used
log "INFO" "Using Python: $(which python)"
log "INFO" "Python version: $(python --version 2>&1)"

# Sync core ComfyUI requirements into the venv if present
if [ -f "$COMFYUI_DIR/requirements.txt" ]; then
    log "INFO" "Checking core ComfyUI requirements in venv..."
    uv pip install -r "$COMFYUI_DIR/requirements.txt" >> "$LOG_FILE" 2>&1 || \
        log "WARN" "Core requirements check finished with warnings"
fi

log "INFO" "UV virtual environment is ready and activated."
