#!/bin/bash
set -e

echo "========================================"
echo "[MSS] Running pre-start scripts..."
echo "========================================"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null || true

# 0. Setup / activate UV venv (MUST be first)
if [ -f "$SCRIPT_DIR/00-setup-uv-venv.sh" ]; then
    echo "[MSS] → Setting up UV virtual environment..."
    # Important: source it so PATH and VIRTUAL_ENV persist
    source "$SCRIPT_DIR/00-setup-uv-venv.sh"
fi

# 0b. Persistent dependency pins (added 2026-10-16, accelerate/boto3 fix).
#     Exported here (pre-start.sh is *sourced* by the entrypoint) so they apply to
#     03-install-node-deps.sh, step 5 below, AND runtime installers started by ComfyUI
#     (MSS-Login install_deps, ComfyUI-Manager). See uv-constraints.txt / uv-overrides.txt.
#     unsafe-best-match stops the PyTorch extra index (old urllib3 1.26.13 mirror) from
#     forcing ancient boto3 1.7.84, which breaks "import accelerate" on Python 3.13.
if [ -f "$SCRIPT_DIR/uv-constraints.txt" ]; then export UV_CONSTRAINT="$SCRIPT_DIR/uv-constraints.txt"; fi
if [ -f "$SCRIPT_DIR/uv-overrides.txt" ]; then export UV_OVERRIDE="$SCRIPT_DIR/uv-overrides.txt"; fi
export UV_INDEX_STRATEGY="unsafe-best-match"
export UV_EXTRA_INDEX_URL="https://download.pytorch.org/whl/cu130"
echo "[MSS] → uv pins active: UV_CONSTRAINT=${UV_CONSTRAINT:-none} UV_OVERRIDE=${UV_OVERRIDE:-none}"

# 1. Models
if [ -f "$SCRIPT_DIR/01-download-models.sh" ]; then
    echo "[MSS] → Checking models to download..."
    bash "$SCRIPT_DIR/01-download-models.sh"
fi

# 2. Download nodes from Git repository URLs in custom-nodes.txt
#    (must run before dependency install so new nodes get requirements.txt)
if [ -f "$SCRIPT_DIR/02-download-nodes.sh" ]; then
    echo "[MSS] → Downloading nodes from Git repository URLs in the custom-nodes.txt file..."
    bash "$SCRIPT_DIR/02-download-nodes.sh"
fi

# 3. Node dependencies (after clones so newly downloaded nodes are included)
if [ -f "$SCRIPT_DIR/03-install-node-deps.sh" ]; then
    echo "[MSS] → Updating custom node dependencies..."
    bash "$SCRIPT_DIR/03-install-node-deps.sh"
fi

# 4. Set permissions for the custom_nodes directory, models directory, mss-data, output,
# and user-scripts directories so that the host OS user can access them
if [ -f "$SCRIPT_DIR/04-set-permissions.sh" ]; then
    echo "[MSS] → Setting permissions for shared folders..."
    bash "$SCRIPT_DIR/04-set-permissions.sh"
fi

# 4b. Re-apply ComfyUI-MultiGPU fp8 cross-device fix (MSS-FP8-XDEV-FIX; added 2026-10-17).
#     Idempotent; skips if already applied or upstream changed; never fails startup.
#     Files: $SCRIPT_DIR/05-reapply-multigpu-fp8.sh + $SCRIPT_DIR/multigpu-fp8/ (diff, python fallback, docs).
if [ -f "$SCRIPT_DIR/05-reapply-multigpu-fp8.sh" ]; then
    echo "[MSS] → Re-applying ComfyUI-MultiGPU fp8 cross-device fix..."
    bash "$SCRIPT_DIR/05-reapply-multigpu-fp8.sh" || echo "[MSS] WARNING: MultiGPU fp8 reapply step errored (ignored)"
fi

# 5. Install latest sqlalchemy for ComfyUI-Copilot
if command -v uv &> /dev/null; then
    echo "[MSS] → Installing/upgrading sqlalchemy and sageattention..."
    uv pip install -U "sqlalchemy>=2.0" sageattention
else
    echo "[MSS] → Skipping sqlalchemy/sageattention install (uv not found in path)"
fi

# 6. Post-install guard (added 2026-10-16): verify pinned stack still imports; log versions.
PY_BIN="${VIRTUAL_ENV:-/app/ComfyUI/.venv}/bin/python"
if [ ! -x "$PY_BIN" ] && [ -x /root/ComfyUI/.venv/bin/python ]; then
    PY_BIN="/root/ComfyUI/.venv/bin/python"
fi
if [ -x "$PY_BIN" ]; then
    "$PY_BIN" -c "import torch, accelerate, transformers, diffusers, huggingface_hub, boto3, numpy; from accelerate.big_modeling import dispatch_model; print('[MSS] pin check OK: torch', torch.__version__, 'accelerate', accelerate.__version__, 'transformers', transformers.__version__, 'diffusers', diffusers.__version__, 'hub', huggingface_hub.__version__, 'boto3', boto3.__version__, 'numpy', numpy.__version__)" 2>&1 | grep -v pynvml | tail -3 || echo "[MSS] WARNING: pin check failed"
fi

echo "========================================"
echo "[MSS] Pre-start scripts finished."
echo "========================================"
