#!/usr/bin/env bash
set -euo pipefail

CLI_ARGS="${CLI_ARGS:---listen 0.0.0.0 --port 8188}"
USE_CPU="${USE_CPU:-0}"
DEVICE_TYPE="${DEVICE_TYPE:-auto}"
FORCE_REINSTALL_TORCH="${FORCE_REINSTALL_TORCH:-0}"
ARCH="$(uname -m)"
OS="$(uname -s)"
VENV_DIR="${VIRTUAL_ENV:-/app/ComfyUI/.venv}"
STAMP_FILE="${VENV_DIR}/.mss_torch_backend"
MSS_DIR="/app/ComfyUI/custom_nodes/ComfyUI-MSS-Login"

echo "[comfyui-deploy] Initializing ComfyUI container runtime ($OS / $ARCH, DEVICE_TYPE=$DEVICE_TYPE)..."

# Execute pre-start user scripts if available (install custom nodes, download models, configure packages)
USER_SCRIPTS_DIR="${COMFYUI_USER_SCRIPTS_DIR:-/app/user-scripts}"
if [[ -f "${USER_SCRIPTS_DIR}/pre-start.sh" ]]; then
    echo "[comfyui-deploy] Running user pre-start scripts from ${USER_SCRIPTS_DIR}..."
    chmod +x "${USER_SCRIPTS_DIR}"/*.sh 2>/dev/null || true
    bash "${USER_SCRIPTS_DIR}/pre-start.sh" || echo "[comfyui-deploy] User pre-start scripts completed with exit code $? (continuing startup)"
fi

# Use MSS-Login's hardware detector (utils/install_deps.py) to determine the target PyTorch backend & wheel index
read -r TARGET_BACKEND TARGET_INDEX TARGET_REQ < <(
    python - <<'PY'
import os, sys
sys.path.insert(0, "/app/ComfyUI/custom_nodes/ComfyUI-MSS-Login")
from utils.install_deps import detect_torch_install_plan
plan = detect_torch_install_plan()
backend = plan.get("backend") or "cpu"
index_url = plan.get("extra_index_url") or "pypi"
req_file = plan.get("requirements_file") or "requirements.txt"
print(f"{backend} {index_url} {req_file}")
PY
)

echo "[comfyui-deploy] Detected target backend: ${TARGET_BACKEND} (index: ${TARGET_INDEX})"

CURRENT_BACKEND=""
if [[ -f "$STAMP_FILE" ]]; then
    CURRENT_BACKEND="$(cat "$STAMP_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
fi

# Verify whether torch is importable and matches the detected backend
TORCH_OK=0
if [[ "$FORCE_REINSTALL_TORCH" != "1" && "$CURRENT_BACKEND" == "$TARGET_BACKEND" ]]; then
    if python -c "import torch, torchvision, torchaudio" &>/dev/null; then
        TORCH_OK=1
    fi
fi

if [[ "$TORCH_OK" -eq 0 ]]; then
    echo "[comfyui-deploy] Applying PyTorch dependencies for backend '${TARGET_BACKEND}' (previous: '${CURRENT_BACKEND:-none}')..."
    UV_ARGS=(
        pip install
        --python "$(command -v python)"
        --reinstall-package torch
        --reinstall-package torchvision
        --reinstall-package torchaudio
        "torch>=2.13.0"
        "torchvision"
        "torchaudio"
    )
    if [[ "$TARGET_INDEX" != "pypi" && -n "$TARGET_INDEX" ]]; then
        UV_ARGS+=(--index-url "$TARGET_INDEX" --extra-index-url "https://pypi.org/simple")
    fi
    uv "${UV_ARGS[@]}"

    if [[ -f "${MSS_DIR}/${TARGET_REQ}" ]]; then
        REQ_ARGS=(pip install --python "$(command -v python)" -r "${MSS_DIR}/${TARGET_REQ}")
        if [[ "$TARGET_INDEX" != "pypi" && -n "$TARGET_INDEX" ]]; then
            REQ_ARGS+=(--extra-index-url "$TARGET_INDEX")
        fi
        uv "${REQ_ARGS[@]}" || true
    fi

    if [[ -f "/app/ComfyUI/requirements.txt" ]]; then
        COMFY_ARGS=(pip install --python "$(command -v python)" -r "/app/ComfyUI/requirements.txt")
        if [[ "$TARGET_INDEX" != "pypi" && -n "$TARGET_INDEX" ]]; then
            COMFY_ARGS+=(--extra-index-url "$TARGET_INDEX")
        fi
        uv "${COMFY_ARGS[@]}" || true
    fi

    mkdir -p "$(dirname "$STAMP_FILE")"
    echo "$TARGET_BACKEND" > "$STAMP_FILE"
    echo "[comfyui-deploy] PyTorch (${TARGET_BACKEND}) installed and verified."
else
    echo "[comfyui-deploy] PyTorch (${TARGET_BACKEND}) already matches detected hardware; skipping download."
fi

if [[ "$TARGET_BACKEND" == "cpu" ]]; then
    echo "[comfyui-deploy] Running in CPU execution mode."
    if [[ "$CLI_ARGS" != *"--cpu"* ]]; then
        CLI_ARGS="$CLI_ARGS --cpu"
    fi
fi

echo "[comfyui-deploy] Launching ComfyUI with args: $CLI_ARGS $*"
exec python main.py $CLI_ARGS "$@"
