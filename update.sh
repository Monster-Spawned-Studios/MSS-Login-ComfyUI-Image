#!/usr/bin/env bash
set -euo pipefail

ARCH="$(uname -m)"
OS="$(uname -s)"

echo "[comfyui-deploy] Checking for ComfyUI updates via comfy-cli..."
comfy --workspace /app/ComfyUI update comfy

echo "[comfyui-deploy] Updating ComfyUI-MSS-Login dependencies for $OS ($ARCH)..."
MSS_DIR="/app/ComfyUI/custom_nodes/ComfyUI-MSS-Login"

if [[ "$OS" == "Darwin" ]]; then
    if [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
        echo "[comfyui-deploy] Apple Silicon (arm64) detected: installing Metal/MPS dependencies..."
        if [[ -f "$MSS_DIR/requirements_metal.txt" ]]; then
            uv pip install -U -r "$MSS_DIR/requirements_metal.txt" || true
        fi
    else
        echo "[comfyui-deploy] Intel Mac (x86_64) detected: installing CPU dependencies..."
        if [[ -f "$MSS_DIR/requirements_cpu.txt" ]]; then
            uv pip install -U -r "$MSS_DIR/requirements_cpu.txt" || true
        fi
    fi
fi

uv pip install -U -e "$MSS_DIR"
echo "[comfyui-deploy] Update completed successfully."
