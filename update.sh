#!/bin/bash
# Manual in-container updater for ComfyUI core and PyTorch wheels.
# Does not fetch, reset, or overwrite MSS-Login. That pin changes only when
# a new image is built with a new MSS_LOGIN_REF. See README "Updating MSS-Login".
# If docker exec starts this script as root, it drops to uid 1000 before
# writing into the venv. It does not re-check the shadow mount: the running
# container already seeded it, and an empty-tmpfs check would refuse here.
set -euo pipefail

if [[ "$(/usr/bin/id -u)" -eq 0 ]]; then
  export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT PYTHONPATH PYTHONHOME PYTHONSTARTUP \
    PYTHONUSERBASE BASH_ENV ENV
  export HOME="${HOME:-/home/comfy}"
  export USER=comfy
  export LOGNAME=comfy
  exec /usr/bin/env \
    PATH="/app/ComfyUI/.venv/bin:${PATH}" \
    /usr/bin/setpriv --reuid=1000 --regid=1000 --init-groups --inh-caps=-all -- "$0" "$@"
fi

ARCH="$(uname -m)"
OS="$(uname -s)"
VENV_DIR="${VIRTUAL_ENV:-/app/ComfyUI/.venv}"
STAMP_FILE="${VENV_DIR}/.mss_torch_backend"
# shellcheck source=entrypoint.sh
source "$(dirname "$(readlink -f "$0")")/entrypoint.sh"
export MSS_DIR="${NODES_DIR:-/app/ComfyUI/custom_nodes}/MSS-Login"
echo "[comfyui-deploy] MSS-Login is not updated by this script. Rebuild the image with a new MSS_LOGIN_REF."
echo "[comfyui-deploy] Checking for ComfyUI updates via comfy-cli (${OS} / ${ARCH})..."
comfy --skip-prompt --no-enable-telemetry --workspace /app/ComfyUI update comfy

detect_line="$(
  comfy_python - <<'PY'
import os
import sys

sys.path.insert(0, os.environ["MSS_DIR"])
from utils.install_deps import detect_torch_install_plan

plan = detect_torch_install_plan()
print(
    f"{plan.get('backend') or 'cpu'} {plan.get('extra_index_url') or 'pypi'} {plan.get('requirements_file') or 'requirements.txt'}"
)
PY
)"
read -r TARGET_BACKEND TARGET_INDEX TARGET_REQ <<<"${detect_line}"

echo "[comfyui-deploy] Updating PyTorch and MSS-Login dependencies for backend '${TARGET_BACKEND}'..."
uv_args=(
  pip install -U
  --python "$(command -v python)"
  "torch>=2.13.0"
  torchvision
  torchaudio
)
if [[ "$TARGET_INDEX" != "pypi" && -n "$TARGET_INDEX" ]]; then
  uv_args+=(--index-url "$TARGET_INDEX" --extra-index-url "https://pypi.org/simple")
fi
uv "${uv_args[@]}"

if [[ -f "${MSS_DIR}/${TARGET_REQ}" ]]; then
  req_args=(pip install -U --python "$(command -v python)" -r "${MSS_DIR}/${TARGET_REQ}")
  if [[ "$TARGET_INDEX" != "pypi" && -n "$TARGET_INDEX" ]]; then
    req_args+=(--extra-index-url "$TARGET_INDEX")
  fi
  uv "${req_args[@]}"
fi

mkdir -p "$(dirname "$STAMP_FILE")"
printf '%s\n' "$TARGET_BACKEND" >"$STAMP_FILE"
echo "[comfyui-deploy] Update completed (backend: ${TARGET_BACKEND}). MSS-Login was not changed."
