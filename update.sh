#!/usr/bin/env bash
set -euo pipefail

ARCH="$(uname -m)"
OS="$(uname -s)"
VENV_DIR="${VIRTUAL_ENV:-/app/ComfyUI/.venv}"
STAMP_FILE="${VENV_DIR}/.mss_torch_backend"
MSS_DIR="/app/ComfyUI/custom_nodes/ComfyUI-MSS-Login"

echo "[comfyui-deploy] Checking for ComfyUI updates via comfy-cli..."
comfy --skip-prompt --no-enable-telemetry --workspace /app/ComfyUI update comfy

echo "[comfyui-deploy] Detecting GPU backend and updating dependencies for $OS ($ARCH)..."
read -r TARGET_BACKEND TARGET_INDEX TARGET_REQ < <(
    python - <<'PY'
import sys
sys.path.insert(0, "/app/ComfyUI/custom_nodes/ComfyUI-MSS-Login")
from utils.install_deps import detect_torch_install_plan
plan = detect_torch_install_plan()
print(f"{plan.get('backend') or 'cpu'} {plan.get('extra_index_url') or 'pypi'} {plan.get('requirements_file') or 'requirements.txt'}")
PY
)

echo "[comfyui-deploy] Updating PyTorch & MSS-Login dependencies for backend '${TARGET_BACKEND}'..."
UV_ARGS=(pip install -U --python "$(command -v python)" "torch>=2.13.0" torchvision torchaudio)
if [[ "$TARGET_INDEX" != "pypi" && -n "$TARGET_INDEX" ]]; then
    UV_ARGS+=(--index-url "$TARGET_INDEX" --extra-index-url "https://pypi.org/simple")
fi
uv "${UV_ARGS[@]}"

if [[ -f "${MSS_DIR}/${TARGET_REQ}" ]]; then
    REQ_ARGS=(pip install -U --python "$(command -v python)" -r "${MSS_DIR}/${TARGET_REQ}")
    if [[ "$TARGET_INDEX" != "pypi" && -n "$TARGET_INDEX" ]]; then
        REQ_ARGS+=(--extra-index-url "$TARGET_INDEX")
    fi
    uv "${REQ_ARGS[@]}"
fi

mkdir -p "$(dirname "$STAMP_FILE")"
echo "$TARGET_BACKEND" > "$STAMP_FILE"
echo "[comfyui-deploy] Update completed successfully (backend: ${TARGET_BACKEND})."
