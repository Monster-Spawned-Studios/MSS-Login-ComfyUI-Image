#!/usr/bin/env bash
# Container entrypoint.
# Starts as root only long enough to give uid 1000 ownership of root-owned
# volume data, then drops privileges. MSS-Login is detected by its package
# (pyproject name or mss_login.py), never by folder name alone. An existing
# checkout is never overwritten. Its git HEAD must match /opt/mss-login/REVISION
# unless MSS_LOGIN_ALLOW_UNPINNED is set.
# Custom-node requirements are installed as uid 1000, constrained to the torch
# and CUDA wheels baked into the image.
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
MSS_TORCH_CONSTRAINTS="${MSS_TORCH_CONSTRAINTS:-/opt/comfy-constraints/torch.txt}"
MSS_LOGIN_REVISION_FILE="${MSS_LOGIN_REVISION_FILE:-/opt/mss-login/REVISION}"

is_truthy() {
  local value="${1:-}"
  value="${value,,}"
  case "$value" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

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

# Primary detection: pyproject package name or the plugin entry module.
# A git remote is not sufficient on its own.
is_mss_login_tree() {
  local dir="$1"
  if [[ -f "${dir}/pyproject.toml" ]] && grep -E -q '^[[:space:]]*name[[:space:]]*=[[:space:]]*["'\'']MSS-Login["'\''][[:space:]]*$' "${dir}/pyproject.toml"; then
    return 0
  fi
  if [[ -f "${dir}/mss_login.py" ]] && grep -q 'create_mss_login_middleware' "${dir}/mss_login.py"; then
    return 0
  fi
  return 1
}

discover_mss_login_dirs() {
  local nodes_root="$1"
  local dir name
  [[ -d "$nodes_root" ]] || return 0
  shopt -s nullglob
  for dir in "${nodes_root}"/*; do
    [[ -d "$dir" ]] || continue
    name="$(basename "$dir")"
    [[ "$name" == .* ]] && continue
    if is_mss_login_tree "$dir"; then
      printf '%s\n' "$dir"
    fi
  done
  shopt -u nullglob
}

log_mss_login_remote() {
  local dir="$1"
  local canon url
  canon="$(realpath "$dir")"
  url="$(git -C "$canon" -c safe.directory="$canon" remote get-url origin 2>/dev/null || true)"
  if [[ -n "$url" ]]; then
    echo "[comfyui-deploy] MSS-Login at ${canon} git remote (not used for detection): ${url}"
  fi
}

seed_mss_login_into() {
  local dest="$1"
  local seed="${MSS_LOGIN_SEED:-/opt/mss-login/ComfyUI-MSS-Login}"
  if dir_has_entries "$dest"; then
    echo "[comfyui-deploy] ${dest} is not empty and is not an MSS-Login package; not overwriting it." >&2
    return 1
  fi
  if ! is_mss_login_tree "$seed"; then
    echo "[comfyui-deploy] MSS-Login seed at ${seed} does not contain the package marker." >&2
    return 1
  fi
  echo "[comfyui-deploy] Seeding MSS-Login into ${dest} from the image pin."
  mkdir -p "$dest"
  cp -a "${seed}/." "${dest}/"
}

enforce_mss_login_pin() {
  local dir="$1"
  local expected="" actual="" canon
  if [[ ! -f "$MSS_LOGIN_REVISION_FILE" ]]; then
    echo "[comfyui-deploy] Image pin file ${MSS_LOGIN_REVISION_FILE} is missing." >&2
    exit 1
  fi
  expected="$(tr -d '[:space:]' <"$MSS_LOGIN_REVISION_FILE")"
  expected="${expected,,}"
  canon="$(realpath "$dir")"
  if ! actual="$(git -C "$canon" -c safe.directory="$canon" rev-parse HEAD 2>/dev/null)"; then
    actual=""
  fi
  actual="$(printf '%s' "$actual" | tr -d '[:space:]')"
  actual="${actual,,}"
  if [[ -n "$actual" && "$actual" == "$expected" ]]; then
    echo "[comfyui-deploy] MSS-Login at ${canon} matches image pin ${expected}."
    return 0
  fi
  echo "[comfyui-deploy] MSS-Login pin mismatch at ${canon}." >&2
  echo "[comfyui-deploy] Image REVISION: ${expected:-<empty>}" >&2
  if [[ -n "$actual" ]]; then
    echo "[comfyui-deploy] Checkout HEAD: ${actual}" >&2
  else
    echo "[comfyui-deploy] Checkout HEAD: (none; no git checkout)" >&2
  fi
  if is_truthy "${MSS_LOGIN_ALLOW_UNPINNED:-false}"; then
    echo "[comfyui-deploy] WARNING: MSS_LOGIN_ALLOW_UNPINNED is enabled. Continuing with this checkout instead of image pin ${expected}. The host checkout was not modified." >&2
    return 0
  fi
  echo "[comfyui-deploy] Refusing to start. The host checkout was not modified. Set MSS_LOGIN_ALLOW_UNPINNED=true to run it anyway, or rebuild with MSS_LOGIN_REF set to the checkout sha." >&2
  exit 1
}

prepare_mss_login() {
  local nodes_root dest base line
  local -a found=()
  nodes_root="${NODES_DIR:-/app/ComfyUI/custom_nodes}"
  base="${MSS_LOGIN_DIR:-MSS-Login}"
  if [[ -z "$base" || "$base" == */* || "$base" == .* || "$base" == *..* ]]; then
    echo "[comfyui-deploy] MSS_LOGIN_DIR must be a single folder name." >&2
    exit 1
  fi
  mkdir -p "$nodes_root"
  while IFS= read -r line; do
    [[ -n "$line" ]] && found+=("$line")
  done < <(discover_mss_login_dirs "$nodes_root")

  if ((${#found[@]} > 1)); then
    echo "[comfyui-deploy] Refusing to start: ${#found[@]} MSS-Login copies would load twice." >&2
    for line in "${found[@]}"; do
      echo "[comfyui-deploy]   ${line}" >&2
    done
    exit 1
  fi

  if ((${#found[@]} == 1)); then
    MSS_LOGIN_RUNTIME_DIR="${found[0]}"
    export MSS_DIR="$MSS_LOGIN_RUNTIME_DIR"
    if [[ "$(basename "$MSS_LOGIN_RUNTIME_DIR")" != "$base" ]]; then
      echo "[comfyui-deploy] MSS-Login package is at ${MSS_LOGIN_RUNTIME_DIR}, not ${nodes_root}/${base}. Using the existing checkout and not seeding another copy."
    else
      echo "[comfyui-deploy] MSS-Login checkout at ${MSS_LOGIN_RUNTIME_DIR} is already present; leaving it unchanged."
    fi
    log_mss_login_remote "$MSS_LOGIN_RUNTIME_DIR"
  else
    dest="${nodes_root}/${base}"
    seed_mss_login_into "$dest"
    MSS_LOGIN_RUNTIME_DIR="$dest"
    export MSS_DIR="$dest"
  fi
  enforce_mss_login_pin "$MSS_LOGIN_RUNTIME_DIR"
}

requirement_line_forbidden() {
  local line="$1"
  [[ "$line" =~ (^|[[:space:]])(-i|--index-url|--extra-index-url|--trusted-host|--find-links)([[:space:]=]|$) ]] && return 0
  [[ "$line" =~ (^|[[:space:]])-f[[:space:]] ]] && return 0
  [[ "$line" =~ (^|[[:space:]])(-r|--requirement)([[:space:]=]|$) ]] && return 0
  return 1
}

requirement_line_is_url() {
  local line="$1"
  [[ "$line" == *git+* ]] && return 0
  [[ "$line" =~ ^[[:space:]]*(https?|ssh|git):// ]] && return 0
  [[ "$line" =~ @[[:space:]]*(https?|ssh|git):// ]] && return 0
  [[ "$line" =~ @[[:space:]]*git\+ ]] && return 0
  return 1
}

filter_requirements_file() {
  local src="$1" dest="$2" node_name="$3" allow_urls="$4"
  local line trimmed
  : >"$dest"
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    if [[ -z "$trimmed" || "${trimmed}" == \#* ]]; then
      continue
    fi
    if requirement_line_forbidden "$trimmed"; then
      echo "[comfyui-deploy] ${node_name}: ignoring requirement option: ${trimmed}" >&2
      continue
    fi
    if requirement_line_is_url "$trimmed" && ! is_truthy "$allow_urls"; then
      echo "[comfyui-deploy] ${node_name}: ignoring URL or git requirement: ${trimmed}" >&2
      continue
    fi
    printf '%s\n' "$trimmed" >>"$dest"
  done <"$src"
}

install_one_node_requirements() {
  local node="$1" req="$2" name="$3" allow_urls="$4" constraints="$5" con_hash="$6"
  local req_hash stamp current filtered uv_log uv_status
  local -a only_bin=()
  local spec pkg key

  req_hash="$(sha256sum "$req" | awk '{print $1}')"
  stamp="${node}/.mss-dep-stamp"
  if [[ -f "$stamp" ]]; then
    current="$(tr -d '[:space:]' <"$stamp")"
    if [[ "$current" == "${req_hash}${con_hash}" ]]; then
      echo "[comfyui-deploy] Custom node ${name} requirements unchanged; skipping install."
      return 0
    fi
  fi

  filtered="$(mktemp)"
  filter_requirements_file "$req" "$filtered" "$name" "$allow_urls"
  if [[ ! -s "$filtered" ]]; then
    echo "[comfyui-deploy] Custom node ${name} has no installable requirements after filtering."
    printf '%s %s\n' "$req_hash" "$con_hash" >"$stamp" || true
    rm -f "$filtered"
    return 0
  fi

  only_bin=(--only-binary torch --only-binary torchvision --only-binary torchaudio)
  while IFS= read -r spec || [[ -n "$spec" ]]; do
    [[ -z "$spec" || "$spec" == \#* ]] && continue
    pkg="${spec%%==*}"
    key="${pkg,,}"
    if [[ "$key" == nvidia-* || "$key" == cuda-* || "$key" == triton || "$key" == triton-* ]]; then
      only_bin+=(--only-binary "$pkg")
    fi
  done <"$constraints"

  set +e
  uv_log="$(uv pip install \
    --python "${VENV_DIR}/bin/python" \
    --constraint "$constraints" \
    "${only_bin[@]}" \
    -r "$filtered" 2>&1)"
  uv_status=$?
  set -e
  rm -f "$filtered"
  if [[ "$uv_status" -ne 0 ]]; then
    echo "[comfyui-deploy] Custom node ${name} dependency install failed (exit ${uv_status}). Startup continues." >&2
    printf '%s\n' "$uv_log" | tail -n 40 >&2
    return 0
  fi
  if ! printf '%s %s\n' "$req_hash" "$con_hash" >"$stamp"; then
    echo "[comfyui-deploy] Custom node ${name} installed, but the cache stamp could not be written." >&2
  fi
  echo "[comfyui-deploy] Custom node ${name} requirements installed."
}

install_custom_node_deps() {
  local nodes_root node req name allow constraints con_hash
  if ! is_truthy "${INSTALL_CUSTOM_NODE_DEPS:-true}"; then
    echo "[comfyui-deploy] INSTALL_CUSTOM_NODE_DEPS is off; skipping custom-node installs."
    return 0
  fi
  if [[ "$(id -u)" -ne "$COMFY_UID" ]]; then
    echo "[comfyui-deploy] Refusing custom-node installs as uid $(id -u); they run only as uid ${COMFY_UID}." >&2
    return 0
  fi
  constraints="$MSS_TORCH_CONSTRAINTS"
  if [[ ! -f "$constraints" ]]; then
    echo "[comfyui-deploy] Torch constraints file missing at ${constraints}; skipping custom-node installs." >&2
    return 0
  fi
  con_hash="$(sha256sum "$constraints" | awk '{print $1}')"
  nodes_root="${NODES_DIR:-/app/ComfyUI/custom_nodes}"
  shopt -s nullglob
  for req in "${nodes_root}"/*/requirements.txt; do
    node="$(dirname "$req")"
    name="$(basename "$node")"
    [[ "$name" == .* ]] && continue
    allow="false"
    if [[ -n "${MSS_LOGIN_RUNTIME_DIR:-}" && "$(realpath "$node")" == "$(realpath "$MSS_LOGIN_RUNTIME_DIR")" ]]; then
      allow="true"
    fi
    install_one_node_requirements "$node" "$req" "$name" "$allow" "$constraints" "$con_hash" || true
  done
  shopt -u nullglob
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
  echo "[comfyui-deploy] Initializing ComfyUI (${OS} / ${ARCH}, DEVICE_TYPE=${DEVICE_TYPE}, USE_CPU=${USE_CPU})."

  require_writable "${MODELS_DIR:-/app/ComfyUI/models}"
  require_writable "${NODES_DIR:-/app/ComfyUI/custom_nodes}"
  require_writable "${MSS_LOGIN_DATA_DIR:-/data/mss-login}"
  require_writable /app/ComfyUI/output
  require_writable /app/ComfyUI/input
  require_writable /app/ComfyUI/user

  prepare_mss_login

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

  install_custom_node_deps

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
