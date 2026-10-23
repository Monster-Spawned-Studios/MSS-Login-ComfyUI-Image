#!/usr/bin/env bash
set -euo pipefail

echo "[comfyui-deploy] Checking for ComfyUI updates via comfy-cli..."
comfy --workspace /app/ComfyUI update comfy

echo "[comfyui-deploy] Updating ComfyUI-MSS-Login dependencies..."
uv pip install -U -e /app/ComfyUI/custom_nodes/ComfyUI-MSS-Login

echo "[comfyui-deploy] Update completed successfully."
