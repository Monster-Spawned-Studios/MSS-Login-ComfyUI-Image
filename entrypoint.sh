#!/usr/bin/env bash
# Container entrypoint.
# Starts as root only long enough to chown root-owned volume data to uid 1000
# and to seed the MSS-Login shadow. The host custom_nodes/MSS-Login checkout
# is never read, imported, or modified. ComfyUI loads the folder named by
# MSS_LOGIN_DIR only when that path is a tmpfs; root copies the baked tree
# onto it, locks it root:root, and checks the baked manifest before setpriv.
# Custom-node requirements are installed only for names in the baked allowlist,
# as uid 1000, under image constraints.
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

# Package name or the plugin entry module, read only from this directory root.
is_mss_login_tree() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  if [[ -f "${dir}/pyproject.toml" && ! -L "${dir}/pyproject.toml" ]] && grep -E -q '^[[:space:]]*name[[:space:]]*=[[:space:]]*["'\'']MSS-Login["'\''][[:space:]]*$' "${dir}/pyproject.toml"; then
    return 0
  fi
  if [[ -f "${dir}/mss_login.py" && ! -L "${dir}/mss_login.py" ]] && grep -q 'create_mss_login_middleware' "${dir}/mss_login.py"; then
    return 0
  fi
  return 1
}

declare -gA MSS_FP_HASHES=()

# Hashes of regular files that sit in the baked package root. Nested trees
# such as .venv or node_modules are not fingerprints: ComfyUI does not import
# those as separate custom nodes.
load_root_fingerprints() {
  local root file base hash
  MSS_FP_HASHES=()
  root="$(mss_login_baked_root)"
  [[ -d "$root" ]] || return 0
  shopt -s nullglob
  for file in "${root}"/*; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    base="$(basename "$file")"
    [[ "$base" == README* || "$base" == LICENSE* ]] && continue
    [[ -s "$file" ]] || continue
    hash="$(sha256sum -- "$file" | awk '{print $1}')"
    MSS_FP_HASHES["$hash"]="$base"
  done
  shopt -u nullglob
}

git_remote_matches_mss_login() {
  local dir="$1"
  local canon top url
  [[ -d "$dir" && ! -L "$dir" ]] || return 1
  canon="$(realpath "$dir")"
  top="$(git -C "$canon" -c safe.directory="$canon" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$top" ]] || return 1
  top="$(realpath "$top")"
  [[ "$top" == "$canon" ]] || return 1
  url="$(git -C "$canon" -c safe.directory="$canon" remote get-url origin 2>/dev/null || true)"
  [[ "$url" == *ComfyUI-MSS-Login* || "$url" == *"/MSS-Login"* || "$url" == *":MSS-Login"* ]]
}

# ComfyUI nodes.py init_external_custom_nodes at
# 0dbfd493b4cc604db743c699f0f7ce01348e54a4, lines 2371-2380.
# https://github.com/comfyanonymous/ComfyUI/blob/0dbfd493b4cc604db743c699f0f7ce01348e54a4/nodes.py
# The image installs ComfyUI with --version latest, so this is the loader
# that was matched, not a pin of the installed tree. It skips __pycache__,
# non-.py files, and paths ending in .disabled. Hidden directories are not skipped.
loader_would_import() {
  local path="$1"
  local name
  name="$(basename "$path")"
  [[ "$name" == "__pycache__" ]] && return 1
  [[ "$path" == *.disabled ]] && return 1
  if [[ -f "$path" ]]; then
    [[ "${path##*.}" == "py" ]] || return 1
  fi
  [[ -e "$path" || -L "$path" ]]
}

# Markers and hashes at the entry root only. Does not walk .venv, node_modules,
# or __pycache__ inside the candidate.
entry_has_mss_login_signal() {
  local path="$1"
  local target file base hash
  if [[ -L "$path" ]]; then
    target="$(realpath "$path" 2>/dev/null || true)"
    [[ -n "$target" ]] || return 1
  else
    target="$path"
  fi
  if [[ -f "$target" && ! -L "$target" ]]; then
    hash="$(sha256sum -- "$target" | awk '{print $1}')"
    [[ -n "${MSS_FP_HASHES[$hash]:-}" ]] && return 0
    grep -q 'create_mss_login_middleware' "$target"
    return
  fi
  [[ -d "$target" ]] || return 1
  if is_mss_login_tree "$target"; then
    return 0
  fi
  if git_remote_matches_mss_login "$target"; then
    return 0
  fi
  shopt -s nullglob
  for file in "${target}"/*; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    base="$(basename "$file")"
    [[ "$base" == README* || "$base" == LICENSE* ]] && continue
    hash="$(sha256sum -- "$file" | awk '{print $1}')"
    if [[ -n "${MSS_FP_HASHES[$hash]:-}" ]]; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

mss_login_break_glass() {
  # Emergency only via the process environment (docker run -e). A file on the
  # mss-data volume is ignored; uid 1000 can write that mount. The variable
  # does not select the host tree and does not skip the shadow checks.
  is_truthy "${MSS_LOGIN_ALLOW_UNPINNED:-false}"
}

refuse_mss_login() {
  echo "[comfyui-deploy] Refusing to start. $*" >&2
  echo "[comfyui-deploy] The host checkout was not modified." >&2
  exit 1
}

mss_login_shadow_dest() {
  local nodes_root base
  nodes_root="${NODES_DIR:-/app/ComfyUI/custom_nodes}"
  base="${MSS_LOGIN_DIR:-MSS-Login}"
  if [[ -z "$base" || "$base" == "." || "$base" == ".." || "$base" == *"/"* || "$base" == *$'\n'* ]]; then
    echo "[comfyui-deploy] MSS_LOGIN_DIR must be a single folder name." >&2
    return 1
  fi
  printf '%s\n' "${nodes_root}/${base}"
}

mss_mountinfo_file() {
  if [[ "${MSS_LOGIN_TEST_MODE:-}" == "1" && -n "${MSS_MOUNTINFO:-}" ]]; then
    printf '%s\n' "$MSS_MOUNTINFO"
  else
    printf '%s\n' "/proc/self/mountinfo"
  fi
}

unescape_mount_field() {
  local value="$1"
  value="${value//\\040/ }"
  value="${value//\\011/$'\t'}"
  value="${value//\\012/$'\n'}"
  value="${value//\\134/\\}"
  printf '%s' "$value"
}

# Last mountinfo entry whose mount point is exactly $1. Field 5 is the
# mount point; the fstype is the token after " - ".
mount_fstype() {
  local want="$1"
  local info line point fstype last=""
  info="$(mss_mountinfo_file)"
  [[ -r "$info" ]] || return 1
  want="$(realpath -m "$want")"
  while IFS= read -r line; do
    [[ "$line" == *" - "* ]] || continue
    point="$(awk '{print $5}' <<<"$line")"
    point="$(unescape_mount_field "$point")"
    point="$(realpath -m "$point")"
    [[ "$point" == "$want" ]] || continue
    fstype="${line#* - }"
    fstype="${fstype%% *}"
    last="$fstype"
  done <"$info"
  [[ -n "$last" ]] || return 1
  printf '%s\n' "$last"
}

mss_login_manifest_file() {
  if [[ "${MSS_LOGIN_TEST_MODE:-}" == "1" && -n "${MSS_LOGIN_MANIFEST:-}" ]]; then
    printf '%s\n' "$MSS_LOGIN_MANIFEST"
  else
    printf '%s\n' "/opt/mss-login/MANIFEST"
  fi
}

resolve_manifest() {
  local path tmp
  path="$(mss_login_manifest_file)"
  if [[ -f "$path" ]]; then
    printf '%s\n' "$path"
    return 0
  fi
  if [[ "${MSS_LOGIN_TEST_MODE:-}" == "1" ]]; then
    tmp="$(mktemp)"
    bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/scripts/write-mss-login-manifest.sh" "$(mss_login_baked_root)" "$tmp"
    printf '%s\n' "$tmp"
    return 0
  fi
  echo "[comfyui-deploy] Baked manifest missing at ${path}." >&2
  return 1
}

manifest_rel_path() {
  local line="$1" hash rel
  hash="${line%% *}"
  rel="${line#"${hash}"}"
  rel="${rel#"${rel%%[![:space:]]*}"}"
  printf '%s\n' "$rel"
}

manifest_path_ok() {
  local rel="$1"
  [[ -n "$rel" ]] || return 1
  [[ "$rel" != /* ]] || return 1
  [[ "$rel" != ".." && "$rel" != ../* && "$rel" != */.. && "$rel" != */../* ]] || return 1
  return 0
}

copy_manifest_tree() {
  local src="$1" dest="$2" manifest="$3"
  local line hash rel parent
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    hash="${line%% *}"
    rel="$(manifest_rel_path "$line")"
    manifest_path_ok "$rel" || return 1
    [[ -f "${src}/${rel}" && ! -L "${src}/${rel}" ]] || return 1
    parent="$(dirname "$rel")"
    mkdir -p "${dest}/${parent}" || return 1
    cp -P -- "${src}/${rel}" "${dest}/${rel}" || return 1
  done <"$manifest"
}

verify_manifest() {
  local dest="$1" manifest="$2"
  local list_got list_want line rel
  list_got="$(mktemp)"
  list_want="$(mktemp)"
  (
    cd "$dest" || exit 1
    find . -type f -print | sed 's|^\./||' | sort
  ) >"$list_got"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    rel="$(manifest_rel_path "$line")"
    printf '%s\n' "$rel"
  done <"$manifest" | sort >"$list_want"
  if ! diff -q "$list_want" "$list_got" >/dev/null 2>&1; then
    echo "[comfyui-deploy] Shadow file list does not match the baked manifest." >&2
    diff -u "$list_want" "$list_got" >&2 || true
    rm -f "$list_got" "$list_want"
    return 1
  fi
  rm -f "$list_got" "$list_want"
  if ! (cd "$dest" && sha256sum --quiet -c "$manifest"); then
    echo "[comfyui-deploy] Shadow hashes do not match the baked manifest." >&2
    return 1
  fi
  return 0
}

lock_shadow_root() {
  local dest="$1"
  chown -R root:root "$dest"
  find "$dest" -type d -exec chmod 0755 {} +
  find "$dest" -type f -exec chmod 0644 {} +
}

assert_uid1000_cannot_write() {
  local dest="$1" file rc
  file="$(find "$dest" -type f -print -quit)"
  [[ -n "$file" ]] || return 1
  set +e
  setpriv --reuid="${COMFY_UID}" --regid="${COMFY_GID}" --init-groups --inh-caps=-all -- test -w "$dest"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "[comfyui-deploy] uid ${COMFY_UID} can write the shadow directory ${dest}." >&2
    return 1
  fi
  if [[ "$rc" -ne 1 ]]; then
    echo "[comfyui-deploy] Could not check shadow directory writability (setpriv exit ${rc})." >&2
    return 1
  fi
  set +e
  setpriv --reuid="${COMFY_UID}" --regid="${COMFY_GID}" --init-groups --inh-caps=-all -- test -w "$file"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "[comfyui-deploy] uid ${COMFY_UID} can write ${file}." >&2
    return 1
  fi
  if [[ "$rc" -ne 1 ]]; then
    echo "[comfyui-deploy] Could not check shadow file writability (setpriv exit ${rc})." >&2
    return 1
  fi
  return 0
}

try_remount_shadow_ro() {
  local dest="$1"
  if mount -o remount,ro,noexec,nosuid "$dest"; then
    echo "[comfyui-deploy] Remounted ${dest} read-only (noexec, nosuid)."
    return 0
  fi
  echo "[comfyui-deploy] Could not remount ${dest} read-only. root:root with mode 0755 directories and 0644 files is the write barrier. uid ${COMFY_UID} cannot modify it." >&2
  return 0
}

install_shadow_tree() {
  local dest="$1"
  local src manifest
  src="$(mss_login_baked_root)"
  if ! manifest="$(resolve_manifest)"; then
    refuse_mss_login "Baked MSS-Login manifest is missing."
  fi
  if dir_has_entries "$dest"; then
    refuse_mss_login "tmpfs at ${dest} is not empty before seeding."
  fi
  if ! is_mss_login_tree "$src"; then
    refuse_mss_login "Baked MSS-Login at ${src} does not contain the package marker."
  fi
  echo "[comfyui-deploy] Seeding MSS-Login into tmpfs ${dest} from the image pin."
  if ! copy_manifest_tree "$src" "$dest" "$manifest"; then
    refuse_mss_login "Copy onto ${dest} failed. The host checkout was not used."
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    lock_shadow_root "$dest"
  elif [[ "${MSS_LOGIN_TEST_MODE:-}" == "1" ]]; then
    echo "[comfyui-deploy] Test mode is not root; skipping chown. Production seeds as root and locks root:root."
  else
    refuse_mss_login "The shadow must be seeded as root before privileges are dropped."
  fi
  if ! verify_manifest "$dest" "$manifest"; then
    refuse_mss_login "Shadow at ${dest} does not match the baked manifest."
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    if ! assert_uid1000_cannot_write "$dest"; then
      refuse_mss_login "uid ${COMFY_UID} would be able to modify the shadow at ${dest}."
    fi
    try_remount_shadow_ro "$dest"
  fi
  echo "[comfyui-deploy] MSS-Login shadow at ${dest} matches the baked manifest."
}

verify_existing_shadow() {
  local dest="$1"
  local manifest owner
  if ! manifest="$(resolve_manifest)"; then
    refuse_mss_login "Baked MSS-Login manifest is missing."
  fi
  if ! verify_manifest "$dest" "$manifest"; then
    refuse_mss_login "Shadow at ${dest} does not match the baked manifest."
  fi
  if [[ "${MSS_LOGIN_TEST_MODE:-}" != "1" ]]; then
    owner="$(stat -c '%u' "$dest")"
    if [[ "$owner" != "0" ]]; then
      refuse_mss_login "Shadow at ${dest} is owned by uid ${owner}. Expected root."
    fi
    if [[ -w "$dest" ]]; then
      refuse_mss_login "Shadow directory ${dest} is writable by uid $(id -u)."
    fi
  fi
  echo "[comfyui-deploy] MSS-Login shadow at ${dest} matches the baked manifest."
}

reject_other_mss_login_copies() {
  local dest="$1"
  local nodes_root path name canon_dest canon
  local -a found=()
  nodes_root="$(dirname "$dest")"
  [[ -d "$nodes_root" ]] || return 0
  load_root_fingerprints
  canon_dest="$(realpath -m "$dest")"
  shopt -s nullglob dotglob
  for path in "${nodes_root}"/*; do
    name="$(basename "$path")"
    [[ "$name" == "." || "$name" == ".." ]] && continue
    canon="$(realpath -m "$path")"
    [[ "$canon" == "$canon_dest" ]] && continue
    loader_would_import "$path" || continue
    if entry_has_mss_login_signal "$path"; then
      found+=("$path")
    fi
  done
  shopt -u nullglob dotglob
  if ((${#found[@]} > 0)); then
    echo "[comfyui-deploy] Refusing to start: ${#found[@]} other MSS-Login copies would load twice." >&2
    for path in "${found[@]}"; do
      echo "[comfyui-deploy]   ${path}" >&2
    done
    echo "[comfyui-deploy] The host checkout was not modified." >&2
    exit 1
  fi
}

prepare_mss_login() {
  local dest fstype
  dest="$(mss_login_shadow_dest)" || exit 1
  if ! fstype="$(mount_fstype "$dest")"; then
    refuse_mss_login "MSS-Login shadow at ${dest} is not mounted. Refusing to read or import the host directory."
  fi
  if [[ "$fstype" != "tmpfs" ]]; then
    refuse_mss_login "MSS-Login shadow at ${dest} is fstype ${fstype}, not tmpfs. Refusing to read or import the host directory."
  fi
  reject_other_mss_login_copies "$dest"
  if [[ "$(id -u)" -eq 0 ]]; then
    install_shadow_tree "$dest"
  elif [[ "${MSS_LOGIN_TEST_MODE:-}" == "1" ]] && ! dir_has_entries "$dest"; then
    install_shadow_tree "$dest"
  else
    verify_existing_shadow "$dest"
  fi
  if mss_login_break_glass; then
    echo "[comfyui-deploy] WARNING: MSS_LOGIN_ALLOW_UNPINNED=true is set. The host MSS-Login tree is not loaded. The shadow at ${dest} is the image pin. This variable does not skip the tmpfs or manifest check." >&2
  fi
  export MSS_DIR="$dest"
  export MSS_LOGIN_RUNTIME_DIR="$dest"
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
    echo "[comfyui-deploy] Skipping requirement for node ${node_name}: ${trimmed}" >&2
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
  local dest fstype
  export HOME=/home/comfy
  export USER=comfy
  export LOGNAME=comfy

  # Confirm the shadow mount before chown -R. A missing tmpfs would otherwise
  # let chown walk the host MSS-Login checkout that the mount is supposed to hide.
  dest="$(mss_login_shadow_dest)" || exit 1
  if ! fstype="$(mount_fstype "$dest")"; then
    refuse_mss_login "MSS-Login shadow at ${dest} is not mounted. Refusing to read or import the host directory."
  fi
  if [[ "$fstype" != "tmpfs" ]]; then
    refuse_mss_login "MSS-Login shadow at ${dest} is fstype ${fstype}, not tmpfs. Refusing to read or import the host directory."
  fi
  if dir_has_entries "$dest"; then
    refuse_mss_login "tmpfs at ${dest} is not empty before seeding."
  fi

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

  # ensure_owned chowns the empty tmpfs to uid 1000. Seed after that and
  # lock the copy back to root:root before setpriv.
  prepare_mss_login
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
