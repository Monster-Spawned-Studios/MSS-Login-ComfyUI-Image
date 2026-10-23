#!/usr/bin/env bash
set -euo pipefail

CLI_ARGS="${CLI_ARGS:---listen 0.0.0.0 --port 8188}"
USE_CPU="${USE_CPU:-0}"
DEVICE_TYPE="${DEVICE_TYPE:-auto}"

echo "[comfyui-deploy] Initializing ComfyUI container runtime..."

# Hardware auto-detection: check for NVIDIA GPU access inside the container
HAS_GPU=0
if [[ "$USE_CPU" == "1" || "$DEVICE_TYPE" == "cpu" ]]; then
    echo "[comfyui-deploy] CPU mode explicitly forced via environment (USE_CPU=$USE_CPU, DEVICE_TYPE=$DEVICE_TYPE)."
elif command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
    CUDA_DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1 || echo "unknown")
    echo "[comfyui-deploy] NVIDIA GPU detected (driver: $CUDA_DRIVER_VER). Running with CUDA acceleration."
    HAS_GPU=1
else
    echo "[comfyui-deploy] No NVIDIA GPU access detected in container environment."
fi

if [[ "$HAS_GPU" -eq 0 ]]; then
    echo "[comfyui-deploy] Auto-switching to CPU execution mode."
    if [[ "$CLI_ARGS" != *"--cpu"* ]]; then
        CLI_ARGS="$CLI_ARGS --cpu"
    fi
fi

echo "[comfyui-deploy] Launching ComfyUI with args: $CLI_ARGS $@"
exec python main.py $CLI_ARGS "$@"
