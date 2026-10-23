#!/usr/bin/env bash
set -euo pipefail

CLI_ARGS="${CLI_ARGS:---listen 0.0.0.0 --port 8188}"
USE_CPU="${USE_CPU:-0}"
DEVICE_TYPE="${DEVICE_TYPE:-auto}"
ARCH="$(uname -m)"
OS="$(uname -s)"

echo "[comfyui-deploy] Initializing ComfyUI container runtime ($OS / $ARCH)..."

HAS_ACCELERATOR=0

# Hardware auto-detection: check for CUDA GPU, Apple Metal MPS, or CPU fallback
if [[ "$USE_CPU" == "1" || "$DEVICE_TYPE" == "cpu" ]]; then
    echo "[comfyui-deploy] CPU mode explicitly requested via environment (USE_CPU=$USE_CPU, DEVICE_TYPE=$DEVICE_TYPE)."
elif [[ "$DEVICE_TYPE" == "metal" ]] || python -c "import torch; exit(0 if torch.backends.mps.is_available() else 1)" 2>/dev/null; then
    echo "[comfyui-deploy] Apple Silicon Metal (MPS) hardware acceleration detected."
    HAS_ACCELERATOR=1
elif command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
    CUDA_DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1 || echo "unknown")
    echo "[comfyui-deploy] NVIDIA GPU detected (driver: $CUDA_DRIVER_VER). Running with CUDA acceleration."
    HAS_ACCELERATOR=1
elif [[ "$OS" == "Darwin" && ("$ARCH" == "arm64" || "$ARCH" == "aarch64") ]]; then
    echo "[comfyui-deploy] Apple Silicon macOS host ($ARCH) detected. Enabling Metal / MPS acceleration."
    HAS_ACCELERATOR=1
elif [[ "$OS" == "Darwin" && "$ARCH" == "x86_64" ]]; then
    echo "[comfyui-deploy] Intel Mac ($ARCH) detected (no Apple Silicon Metal MPS). Using CPU execution."
else
    echo "[comfyui-deploy] No NVIDIA GPU or Metal accelerator detected in container environment."
fi

if [[ "$HAS_ACCELERATOR" -eq 0 ]]; then
    echo "[comfyui-deploy] Auto-switching to CPU execution mode."
    if [[ "$CLI_ARGS" != *"--cpu"* ]]; then
        CLI_ARGS="$CLI_ARGS --cpu"
    fi
fi

echo "[comfyui-deploy] Launching ComfyUI with args: $CLI_ARGS $@"
exec python main.py $CLI_ARGS "$@"
