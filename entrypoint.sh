#!/usr/bin/env bash
# Container entrypoint.
# Starts as root only long enough to give uid 1000 ownership of root-owned
# volume data, then drops privileges. A host MSS-Login tree is accepted only
# when its files match the image copy and its git checkout is the baked
# revision with a clean status. Custom-node requirements are installed only
# for names in the baked allowlist, as uid 1000, under image constraints.
set -euo pipefail

# Bytecode must not be written next to mounted source. This is container-local
# and is not under custom_nodes, models, or mss-data. Set before any Python.
export PYTHONPYCACHEPREFIX=/tmp/comfy-pycache
mkdir -p "$PYTHONPYCACHEPREFIX"
chmod 1777 "$PYTHONPYCACHEPREFIX" 2>/dev/null || true

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

# Production paths are fixed. Tests set MSS_LOGIN_TEST_MODE=1 to redirect them.
mss_login_revision_file() {
  if [[ "${MSS_LOGIN_TEST_MODE:-}" == "1" && -n "${MSS_LOGIN_REVISION_FILE:-}" ]]; then
    printf '%s\n' "$MSS_LOGIN_REVISION_FILE"
  else
    printf '%s\n' "/opt/mss-login/REVISION"
  fi
}

mss_login_baked_root() {
  if [[ "${MSS_LOGIN_TEST_MODE:-}" == "1" && -n "${MSS_LOGIN_SEED:-}" ]]; then
    printf '%s\n' "$MSS_LOGIN_SEED"
  else
    printf '%s\n' "/opt/mss-login/ComfyUI-MSS-Login"
  fi
}

mss_torch_constraints_file() {
  if [[ "${MSS_LOGIN_TEST_MODE:-}" == "1" && -n "${MSS_TORCH_CONSTRAINTS:-}" ]]; then
    printf '%s\n' "$MSS_TORCH_CONSTRAINTS"
  else
    printf '%s\n' "/opt/comfy-constraints/torch.txt"
  fi
}

mss_node_allowlist_file() {
  if [[ "${MSS_LOGIN_TEST_MODE:-}" == "1" && -n "${MSS_NODE_DEPS_ALLOWLIST:-}" ]]; then
    printf '%s\n' "$MSS_NODE_DEPS_ALLOWLIST"
  else
    printf '%s\n' "/opt/mss-login/custom-node-deps-allowlist.txt"
  fi
}

mss_build_id_file() {
  if [[ "${MSS_LOGIN_TEST_MODE:-}" == "1" && -n "${MSS_TEST_VENV_DIR:-}" ]]; then
    printf '%s\n' "${MSS_TEST_VENV_DIR}/.mss-build-id"
  else
    printf '%s\n' "${VENV_DIR}/.mss-build-id"
  fi
}

mss_stamp_dir() {
  if [[ "${MSS_LOGIN_TEST_MODE:-}" == "1" && -n "${MSS_TEST_VENV_DIR:-}" ]]; then
    printf '%s\n' "${MSS_TEST_VENV_DIR}/.mss-node-dep-stamps"
  else
    printf '%s\n' "${VENV_DIR}/.mss-node-dep-stamps"
  fi
}

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

# Package name or the plugin entry module. Folder name is not consulted.
is_mss_login_tree() {
  local dir="$1"
  [[ -e "$dir" ]] || return 1
  if [[ -f "${dir}/pyproject.toml" ]] && grep -E -q '^[[:space:]]*name[[:space:]]*=[[:space:]]*["'\'']MSS-Login["'\''][[:space:]]*$' "${dir}/pyproject.toml"; then
    return 0
  fi
  if [[ -f "${dir}/mss_login.py" ]] && grep -q 'create_mss_login_middleware' "${dir}/mss_login.py"; then
    return 0
  fi
  return 1
}

declare -gA MSS_FP_HASHES=()

load_mss_login_fingerprints() {
  local root file hash
  MSS_FP_HASHES=()
  root="$(mss_login_baked_root)"
  [[ -d "$root" ]] || return 0
  while IFS= read -r file; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    hash="$(sha256sum "$file" | awk '{print $1}')"
    MSS_FP_HASHES["$hash"]=1
  done < <(find -P "$root" \
    \( -name .git -o -name __pycache__ -o -name docs -o -name readme -o -name .github \) -prune -o \
    -type f ! -name '*.pyc' ! -name 'README*' ! -name 'LICENSE*' -size +0c -print)
}

git_remote_matches_mss_login() {
  local dir="$1"
  local canon top url
  [[ -e "$dir" ]] || return 1
  canon="$(realpath "$dir")"
  top="$(git -C "$canon" -c safe.directory="$canon" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$top" ]] || return 1
  top="$(realpath "$top")"
  [[ "$top" == "$canon" ]] || return 1
  url="$(git -C "$canon" -c safe.directory="$canon" remote get-url origin 2>/dev/null || true)"
  [[ "$url" == *ComfyUI-MSS-Login* || "$url" == *"/MSS-Login"* || "$url" == *":MSS-Login"* ]]
}

dir_has_baked_file() {
  local dir="$1"
  local file hash
  [[ -d "$dir" ]] || return 1
  [[ "${#MSS_FP_HASHES[@]}" -gt 0 ]] || return 1
  while IFS= read -r file; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    hash="$(sha256sum "$file" | awk '{print $1}')"
    if [[ -n "${MSS_FP_HASHES[$hash]:-}" ]]; then
      return 0
    fi
  done < <(find -P "$dir" \( -name .git -o -name __pycache__ \) -prune -o -type f ! -name '*.pyc' -print)
  return 1
}

dir_has_mss_login_signal() {
  local dir="$1"
  local target="$dir"
  if [[ -L "$dir" ]]; then
    target="$(realpath "$dir" 2>/dev/null || true)"
    [[ -n "$target" ]] || return 1
  fi
  if is_mss_login_tree "$target"; then
    return 0
  fi
  if git_remote_matches_mss_login "$target"; then
    return 0
  fi
  if dir_has_baked_file "$target"; then
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
    if dir_has_mss_login_signal "$dir"; then
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
  local seed
  seed="$(mss_login_baked_root)"
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

mss_login_break_glass() {
  # Emergency only via the process environment (docker run -e). A file on the
  # mss-data volume is ignored; uid 1000 can write that mount.
  is_truthy "${MSS_LOGIN_ALLOW_UNPINNED:-false}"
}

host_tree_has_bytecode() {
  local dir="$1"
  local hit
  hit="$(find -P "$dir" \( -name .git -prune \) -o \( -type d -name __pycache__ -o -type f -iname '*.pyc' -o -type f -iname '*.pyo' \) -print -quit)"
  [[ -n "$hit" ]]
}

# Content plus a real commit. HEAD text alone is not enough.
exact_mss_login_copy() {
  local dir="$1"
  local baked expected actual canon top status
  [[ -d "$dir" && ! -L "$dir" ]] || return 1
  canon="$(realpath "$dir")"
  baked="$(mss_login_baked_root)"
  [[ -d "$baked" ]] || return 1
  if host_tree_has_bytecode "$canon"; then
    return 1
  fi
  if ! diff -rq --exclude=.git --no-dereference "$baked" "$canon" >/dev/null 2>&1; then
    return 1
  fi
  if [[ ! -f "$(mss_login_revision_file)" ]]; then
    return 1
  fi
  expected="$(tr -d '[:space:]' <"$(mss_login_revision_file)")"
  expected="${expected,,}"
  [[ -n "$expected" ]] || return 1
  if ! top="$(git -C "$canon" -c safe.directory="$canon" rev-parse --show-toplevel 2>/dev/null)"; then
    return 1
  fi
  top="$(realpath "$top")"
  [[ "$top" == "$canon" ]] || return 1
  if ! git -C "$canon" -c safe.directory="$canon" cat-file -e "${expected}^{commit}" 2>/dev/null; then
    return 1
  fi
  if ! actual="$(git -C "$canon" -c safe.directory="$canon" rev-parse HEAD 2>/dev/null)"; then
    return 1
  fi
  actual="$(printf '%s' "$actual" | tr -d '[:space:]')"
  actual="${actual,,}"
  [[ "$actual" == "$expected" ]] || return 1
  status="$(git -C "$canon" -c safe.directory="$canon" status --porcelain --untracked-files=all --ignored 2>/dev/null || true)"
  [[ -z "$status" ]] || return 1
  return 0
}

log_pin_facts() {
  local dir="$1"
  local expected="" actual="" canon
  [[ -e "$dir" ]] || return 0
  canon="$(realpath "$dir")"
  if [[ -f "$(mss_login_revision_file)" ]]; then
    expected="$(tr -d '[:space:]' <"$(mss_login_revision_file)")"
  fi
  actual="$(git -C "$canon" -c safe.directory="$canon" rev-parse HEAD 2>/dev/null || true)"
  actual="$(printf '%s' "$actual" | tr -d '[:space:]')"
  echo "[comfyui-deploy] Image REVISION: ${expected:-<empty>}" >&2
  if [[ -n "$actual" ]]; then
    echo "[comfyui-deploy] Checkout HEAD: ${actual}" >&2
  else
    echo "[comfyui-deploy] Checkout HEAD: (none; no git checkout)" >&2
  fi
}

refuse_mss_login() {
  echo "[comfyui-deploy] Refusing to start. $*" >&2
  echo "[comfyui-deploy] The host checkout was not modified." >&2
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
  load_mss_login_fingerprints
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
    if exact_mss_login_copy "$MSS_LOGIN_RUNTIME_DIR"; then
      if [[ "$(basename "$MSS_LOGIN_RUNTIME_DIR")" != "$base" ]]; then
        echo "[comfyui-deploy] MSS-Login package is at ${MSS_LOGIN_RUNTIME_DIR}, not ${nodes_root}/${base}. Using the existing checkout and not seeding another copy."
      else
        echo "[comfyui-deploy] MSS-Login checkout at ${MSS_LOGIN_RUNTIME_DIR} is already present; leaving it unchanged."
      fi
      log_mss_login_remote "$MSS_LOGIN_RUNTIME_DIR"
      echo "[comfyui-deploy] MSS-Login at ${MSS_LOGIN_RUNTIME_DIR} matches image pin $(tr -d '[:space:]' <"$(mss_login_revision_file)")."
      return 0
    fi
    if mss_login_break_glass; then
      log_pin_facts "$MSS_LOGIN_RUNTIME_DIR"
      echo "[comfyui-deploy] WARNING: MSS_LOGIN_ALLOW_UNPINNED=true is set for ${MSS_LOGIN_RUNTIME_DIR}. The tree does not match the image pin. This environment variable is an emergency bypass, not a normal start. The host checkout was not modified." >&2
      return 0
    fi
    log_pin_facts "$MSS_LOGIN_RUNTIME_DIR"
    refuse_mss_login "MSS-Login content at ${MSS_LOGIN_RUNTIME_DIR} does not exactly match the image pin (tree, commit object, or git status)."
  fi

  dest="${nodes_root}/${base}"
  seed_mss_login_into "$dest"
  MSS_LOGIN_RUNTIME_DIR="$dest"
  export MSS_DIR="$dest"
  if ! exact_mss_login_copy "$MSS_LOGIN_RUNTIME_DIR"; then
    refuse_mss_login "Seeded MSS-Login at ${dest} failed the image pin check."
  fi
  echo "[comfyui-deploy] MSS-Login at ${MSS_LOGIN_RUNTIME_DIR} matches image pin $(tr -d '[:space:]' <"$(mss_login_revision_file)")."
}

requirement_line_rejected() {
  local line="$1"
  local lower
  lower="${line,,}"
  [[ "$line" == -* ]] && return 0
  [[ "$lower" == *index-url* || "$lower" == *trusted-host* || "$lower" == *find-links* || "$lower" == *no-index* ]] && return 0
  [[ "$lower" == *"--constraint"* || "$lower" == *" constraint "* ]] && return 0
  [[ "$line" =~ (^|[[:space:]])-[cirfe]([^[:alnum:]]|$) ]] && return 0
  [[ "$lower" =~ (^|[[:space:]])--(constraint|requirement|editable)([[:space:]=]|$) ]] && return 0
  [[ "$line" == *"://"* || "$line" == *git+* || "$line" == *"@"* || "$line" == *\\* ]] && return 0
  [[ "$line" == /* || "$line" == ./* || "$line" == ../* || "$line" == "~"* ]] && return 0
  [[ "$line" == *"/../"* || "$line" == *"../"* ]] && return 0
  [[ "$lower" =~ \.(whl|zip|tar\.gz|tgz|tar\.bz2|tar\.xz)$ ]] && return 0
  local token
  local -a tokens=()
  read -r -a tokens <<< "$line"
  for token in "${tokens[@]}"; do
    [[ "$token" == */* || "$token" == *\\* ]] && return 0
  done
  return 1
}

requirement_line_is_safe_spec() {
  local line="$1"
  [[ "$line" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(\[[A-Za-z0-9_,.\-]+\])?([[:space:]]*(===|==|~=|!=|<=|>=|<|>)[[:space:]]*[A-Za-z0-9.*+!_-]+)*$ ]]
}

consider_requirement_line() {
  local logical="$1" dest="$2" node_name="$3"
  local trimmed
  trimmed="${logical#"${logical%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
  if [[ -z "$trimmed" || "${trimmed}" == \#* ]]; then
    return 0
  fi
  if requirement_line_rejected "$trimmed" || ! requirement_line_is_safe_spec "$trimmed"; then
    echo "[comfyui-deploy] ${node_name}: ignoring requirement line: ${trimmed}" >&2
    return 0
  fi
  printf '%s\n' "$trimmed" >>"$dest"
}

filter_requirements_file() {
  local src="$1" dest="$2" node_name="$3"
  local line logical=""
  : >"$dest"
  # Fourth argument is ignored. URL and option lines are never installed.
  while IFS= read -r line || [[ -n "${line:-}" ]]; do
    line="${line//$'\r'/}"
    if [[ "$line" == *\\ ]]; then
      logical+="${line%\\}"
      continue
    fi
    logical+="$line"
    consider_requirement_line "$logical" "$dest" "$node_name"
    logical=""
  done <"$src"
  if [[ -n "$logical" ]]; then
    consider_requirement_line "$logical" "$dest" "$node_name"
  fi
}

install_one_node_requirements() {
  local node="$1" req="$2" name="$3" constraints="$4" con_hash="$5" revision="$6" build_id="$7"
  local req_hash stamp current filtered uv_log uv_status stamp_key
  local -a only_bin=()
  local spec pkg key

  req_hash="$(sha256sum "$req" | awk '{print $1}')"
  stamp="$(mss_stamp_dir)/${name}"
  stamp_key="${req_hash} ${con_hash} ${revision} ${build_id}"
  mkdir -p "$(mss_stamp_dir)"
  if [[ -f "$stamp" ]]; then
    current="$(tr -d '\n' <"$stamp")"
    if [[ "$current" == "$stamp_key" ]]; then
      echo "[comfyui-deploy] Custom node ${name} requirements unchanged; skipping install."
      return 0
    fi
  fi

  filtered="$(mktemp)"
  filter_requirements_file "$req" "$filtered" "$name" false
  if [[ ! -s "$filtered" ]]; then
    echo "[comfyui-deploy] Custom node ${name} has no installable requirements after filtering."
    printf '%s\n' "$stamp_key" >"$stamp" || true
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
  if ! printf '%s\n' "$stamp_key" >"$stamp"; then
    echo "[comfyui-deploy] Custom node ${name} installed, but the cache stamp could not be written." >&2
  fi
  echo "[comfyui-deploy] Custom node ${name} requirements installed."
}

install_custom_node_deps() {
  local nodes_root node req name constraints con_hash revision build_id allowlist allow_name
  if ! is_truthy "${INSTALL_CUSTOM_NODE_DEPS:-true}"; then
    echo "[comfyui-deploy] INSTALL_CUSTOM_NODE_DEPS is off; skipping custom-node installs."
    return 0
  fi
  if [[ "$(id -u)" -ne "$COMFY_UID" ]]; then
    echo "[comfyui-deploy] Refusing custom-node installs as uid $(id -u); they run only as uid ${COMFY_UID}." >&2
    return 0
  fi
  constraints="$(mss_torch_constraints_file)"
  if [[ ! -f "$constraints" ]]; then
    echo "[comfyui-deploy] Torch constraints file missing at ${constraints}; skipping custom-node installs." >&2
    return 0
  fi
  con_hash="$(sha256sum "$constraints" | awk '{print $1}')"
  revision="none"
  if [[ -f "$(mss_login_revision_file)" ]]; then
    revision="$(tr -d '[:space:]' <"$(mss_login_revision_file)")"
  fi
  build_id="none"
  if [[ -f "$(mss_build_id_file)" ]]; then
    build_id="$(tr -d '[:space:]' <"$(mss_build_id_file)")"
  fi
  allowlist="$(mss_node_allowlist_file)"
  if [[ ! -f "$allowlist" ]]; then
    echo "[comfyui-deploy] Custom-node allowlist missing at ${allowlist}; skipping installs." >&2
    return 0
  fi
  declare -A allowed=()
  local allow_name
  while IFS= read -r allow_name || [[ -n "$allow_name" ]]; do
    allow_name="${allow_name#"${allow_name%%[![:space:]]*}"}"
    allow_name="${allow_name%"${allow_name##*[![:space:]]}"}"
    [[ -z "$allow_name" || "$allow_name" == \#* ]] && continue
    allowed["$allow_name"]=1
  done <"$allowlist"
  nodes_root="${NODES_DIR:-/app/ComfyUI/custom_nodes}"
  shopt -s nullglob
  for req in "${nodes_root}"/*/requirements.txt; do
    node="$(dirname "$req")"
    name="$(basename "$node")"
    [[ "$name" == .* ]] && continue
    if [[ -L "$node" ]]; then
      echo "[comfyui-deploy] Skipping custom node ${name}: path is a symlink." >&2
      continue
    fi
    if is_mss_login_tree "$node" || { [[ -n "${MSS_LOGIN_RUNTIME_DIR:-}" ]] && [[ "$(realpath "$node")" == "$(realpath "$MSS_LOGIN_RUNTIME_DIR")" ]]; }; then
      echo "[comfyui-deploy] Skipping ${name}: MSS-Login dependencies are installed at image build."
      continue
    fi
    if [[ -z "${allowed[$name]:-}" ]]; then
      echo "[comfyui-deploy] Skipping custom node ${name}: not on the dependency allowlist."
      continue
    fi
    install_one_node_requirements "$node" "$req" "$name" "$constraints" "$con_hash" "$revision" "$build_id" || true
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

warn_if_insightface_models_missing() {
  local dir="/app/ComfyUI/models/insightface"
  if [[ ! -d "$dir" ]]; then
    echo "[comfyui-deploy] WARNING: ${dir} is not mounted. InstantID and PuLID load faces from ComfyUI's models/insightface (antelopev2 and buffalo_l). The host directory must already exist; this stack does not create it." >&2
    return 0
  fi
  if ! dir_has_entries "$dir"; then
    echo "[comfyui-deploy] WARNING: ${dir} is empty. Expected the existing verified antelopev2 and buffalo_l packs. The image does not download them." >&2
  fi
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

  warn_if_insightface_models_missing
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
