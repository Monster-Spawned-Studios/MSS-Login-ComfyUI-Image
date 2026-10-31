#!/usr/bin/env bash
# Container entrypoint.
# Starts as root (compose user 0:0) only long enough to give uid 1000 ownership
# of root-owned volume data, seeds MSS-Login when the custom_nodes volume has
# no checkout, then drops to uid 1000. An existing checkout is never replaced.
# user-scripts/00-setup-uv-venv.sh is not executed; the cuDNN library path is
# baked into the nvidia image for /app/ComfyUI/.venv.
set -euo pipefail

COMFY_UID=1000
COMFY_GID=1000
CLI_ARGS="${CLI_ARGS:---listen 0.0.0.0 --port 9008}"
DEVICE_TYPE="${DEVICE_TYPE:-auto}"
USE_CPU="${USE_CPU:-0}"
FORCE_REINSTALL_TORCH="${FORCE_REINSTALL_TORCH:-0}"
ARCH="$(uname -m)"
OS="$(uname -s)"
VENV_DIR="${VIRTUAL_ENV:-/app/ComfyUI/.venv}"
STAMP_FILE="${VENV_DIR}/.mss_torch_backend"

dir_has_entries() {
  local path="$1"
  local entry
  [[ -d "$path" ]] || return 1
  shopt -s nullglob dotglob
  for entry in "${path}"/*; do
    if [[ -e "${entry}" || -L "${entry}" ]]; then
      shopt -u nullglob dotglob
      return 0
    fi
  done
  shopt -u nullglob dotglob
  return 1
}

ensure_owned() {
  local path="$1"
  local kind="${2:-dir}"
  local owner

  if [[ "$kind" == "file" ]]; then
    [[ -e "$path" ]] || return 0
  else
    mkdir -p "$path"
  fi

  owner="$(stat -c '%u' "$path")"
  if [[ "$owner" == "$COMFY_UID" ]]; then
    return 0
  fi

  echo "[comfyui-deploy] Changing ownership of ${path} from uid ${owner} to ${COMFY_UID}."
  chown -R "${COMFY_UID}:${COMFY_GID}" "$path"
}

seed_mss_login() {
  local nodes_root dest seed
  nodes_root="${NODES_DIR:-/app/ComfyUI/custom_nodes}"
  dest="${nodes_root}/ComfyUI-MSS-Login"
  seed="${MSS_LOGIN_SEED:-/opt/mss-login/ComfyUI-MSS-Login}"

  mkdir -p "$nodes_root"
  if dir_has_entries "$dest"; then
    echo "[comfyui-deploy] MSS-Login checkout at ${dest} is already present; leaving it unchanged."
    return 0
  fi

  if [[ ! -f "${seed}/__init__.py" ]]; then
    echo "[comfyui-deploy] MSS-Login seed is missing at ${seed}." >&2
    exit 1
  fi

  echo "[comfyui-deploy] Seeding MSS-Login into ${dest} from the image pin."
  mkdir -p "$dest"
  cp -a "${seed}/." "${dest}/"
}

prepare_as_root() {
  export HOME=/home/comfy
  export USER=comfy
  export LOGNAME=comfy

  ensure_owned "${MODELS_DIR:-/app/ComfyUI/models}"
  ensure_owned "${NODES_DIR:-/app/ComfyUI/custom_nodes}"
  ensure_owned "${MSS_LOGIN_DATA_DIR:-/data/mss-login}"
  ensure_owned /app/ComfyUI/output
  ensure_owned /app/ComfyUI/input
  ensure_owned /app/ComfyUI/user
  ensure_owned /home/comfy/user-scripts
  ensure_owned /home/comfy/.cache/huggingface/hub
  ensure_owned /home/comfy/.cache/torch/hub
  ensure_owned /home/comfy/.bashrc file

  seed_mss_login
  ensure_owned "${NODES_DIR:-/app/ComfyUI/custom_nodes}/ComfyUI-MSS-Login"
}

require_writable() {
  local path="$1"
  if [[ ! -w "$path" ]]; then
    echo "[comfyui-deploy] ${path} is not writable by uid $(id -u)." >&2
    echo "[comfyui-deploy] Start as root so ownership can be repaired, then privileges are dropped. portainer-stack.yml sets user: \"0:0\"." >&2
    exit 1
  fi
}

prepend_cuda_library_path() {
  local site candidate
  local -a found=()
  shopt -s nullglob
  for site in \
    /app/ComfyUI/.venv/lib/python3.13/site-packages \
    /app/ComfyUI/.venv/lib64/python3.13/site-packages
  do
    [[ -d "$site" ]] || continue
    for candidate in "${site}/torch/lib" "${site}/nvidia/"*/lib; do
      [[ -d "$candidate" ]] || continue
      found+=("$candidate")
    done
  done
  shopt -u nullglob

  if [[ "${#found[@]}" -eq 0 ]]; then
    return 0
  fi

  local prefix
  prefix="$(IFS=:; printf '%s' "${found[*]}")"
  if [[ -n "${LD_LIBRARY_PATH:-}" ]]; then
    export LD_LIBRARY_PATH="${prefix}:${LD_LIBRARY_PATH}"
  else
    export LD_LIBRARY_PATH="${prefix}"
  fi
  echo "[comfyui-deploy] CUDA/cuDNN libraries prefer the venv wheels."
}

launch_comfyui() {
  local detect_line
  export MSS_DIR="${NODES_DIR:-/app/ComfyUI/custom_nodes}/ComfyUI-MSS-Login"

  echo "[comfyui-deploy] Initializing ComfyUI (${OS} / ${ARCH}, DEVICE_TYPE=${DEVICE_TYPE}, USE_CPU=${USE_CPU})."

  require_writable "${MODELS_DIR:-/app/ComfyUI/models}"
  require_writable "${NODES_DIR:-/app/ComfyUI/custom_nodes}"
  require_writable "${MSS_LOGIN_DATA_DIR:-/data/mss-login}"
  require_writable /app/ComfyUI/output
  require_writable /app/ComfyUI/input
  require_writable /app/ComfyUI/user

  seed_mss_login

  detect_line="$(
    python - <<'PY'
import os
import sys

mss = os.environ["MSS_DIR"]
sys.path.insert(0, mss)
from utils.install_deps import detect_torch_install_plan

plan = detect_torch_install_plan()
backend = plan.get("backend") or "cpu"
index_url = plan.get("extra_index_url") or "pypi"
req_file = plan.get("requirements_file") or "requirements.txt"
print(f"{backend} {index_url} {req_file}")
PY
  )"
  read -r TARGET_BACKEND TARGET_INDEX TARGET_REQ <<<"${detect_line}"

  echo "[comfyui-deploy] Detected target backend: ${TARGET_BACKEND} (index: ${TARGET_INDEX})."

  local current_backend=""
  if [[ -f "$STAMP_FILE" ]]; then
    current_backend="$(tr -d '[:space:]' <"$STAMP_FILE" 2>/dev/null || true)"
  fi

  local torch_ok=0
  if [[ "$FORCE_REINSTALL_TORCH" != "1" && "$current_backend" == "$TARGET_BACKEND" ]]; then
    if python -c "import torch, torchvision, torchaudio" &>/dev/null; then
      torch_ok=1
    fi
  fi

  if [[ "$torch_ok" -eq 0 ]]; then
    echo "[comfyui-deploy] Applying PyTorch for backend '${TARGET_BACKEND}' (previous: '${current_backend:-none}')."
    local -a uv_args=(
      pip install
      --python "$(command -v python)"
      --reinstall-package torch
      --reinstall-package torchvision
      --reinstall-package torchaudio
      "torch>=2.13.0"
      torchvision
      torchaudio
    )
    if [[ "$TARGET_INDEX" != "pypi" && -n "$TARGET_INDEX" ]]; then
      uv_args+=(--index-url "$TARGET_INDEX" --extra-index-url "https://pypi.org/simple")
    fi
    uv "${uv_args[@]}"

    if [[ -f "${MSS_DIR}/${TARGET_REQ}" ]]; then
      local -a req_args=(pip install --python "$(command -v python)" -r "${MSS_DIR}/${TARGET_REQ}")
      if [[ "$TARGET_INDEX" != "pypi" && -n "$TARGET_INDEX" ]]; then
        req_args+=(--extra-index-url "$TARGET_INDEX")
      fi
      uv "${req_args[@]}" || true
    fi

    if [[ -f /app/ComfyUI/requirements.txt ]]; then
      local -a comfy_args=(pip install --python "$(command -v python)" -r /app/ComfyUI/requirements.txt)
      if [[ "$TARGET_INDEX" != "pypi" && -n "$TARGET_INDEX" ]]; then
        comfy_args+=(--extra-index-url "$TARGET_INDEX")
      fi
      uv "${comfy_args[@]}" || true
    fi

    mkdir -p "$(dirname "$STAMP_FILE")"
    printf '%s\n' "$TARGET_BACKEND" >"$STAMP_FILE"
    echo "[comfyui-deploy] PyTorch (${TARGET_BACKEND}) installed."
  else
    echo "[comfyui-deploy] PyTorch (${TARGET_BACKEND}) already matches this host."
  fi

  if [[ "$TARGET_BACKEND" == "cpu" && "$CLI_ARGS" != *"--cpu"* ]]; then
    CLI_ARGS="${CLI_ARGS} --cpu"
    echo "[comfyui-deploy] Running in CPU execution mode."
  fi

  prepend_cuda_library_path

  cd /app/ComfyUI
  echo "[comfyui-deploy] Launching ComfyUI with args: ${CLI_ARGS} $*"
  # CLI_ARGS is a space-separated argument string from the compose file.
  # shellcheck disable=SC2086
  exec python main.py $CLI_ARGS "$@"
}

main() {
  if [[ "$(id -u)" -eq 0 ]]; then
    prepare_as_root
    cd /app/ComfyUI
    exec setpriv \
      --reuid="${COMFY_UID}" \
      --regid="${COMFY_GID}" \
      --init-groups \
      --inh-caps=-all \
      -- "$0" "$@"
  fi

  export HOME="${HOME:-/home/comfy}"
  export USER="${USER:-comfy}"
  export LOGNAME="${LOGNAME:-comfy}"
  launch_comfyui "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
