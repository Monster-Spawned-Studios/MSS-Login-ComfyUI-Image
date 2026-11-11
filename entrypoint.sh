#!/bin/bash
# Container entrypoint.
# Starts as root only long enough to chown root-owned volume data to uid 1000
# and to seed the MSS-Login shadow. The host custom_nodes/MSS-Login checkout
# is never read, imported, or modified. ComfyUI loads the folder named by
# custom_nodes/MSS-Login only when that path is a tmpfs; root copies the baked tree
# onto it, locks it root:root, and checks the baked manifest before setpriv.
# Custom-node requirements are installed only for names in the baked allowlist,
# as uid 1000, under image constraints.
set -euo pipefail

# Root must not honor a caller-supplied PATH or loader variables. A planted
# .venv/bin/setpriv or LD_LIBRARY_PATH library would otherwise run as root.
# The venv bin directory is added back only on the setpriv that drops to uid 1000.
sanitize_root_execution_env() {
  export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT LD_DEBUG LD_PROFILE LD_ORIGIN_PATH \
    LD_USE_LOAD_BIAS LD_DYNAMIC_WEAK LD_BIND_NOW \
    PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONUSERBASE PYTHONINSPECT \
    PYTHONEXECUTABLE PYTHONWARNINGS PYTHONMALLOC PYTHONDEVMODE PYTHONSAFEPATH \
    PYTHONPLATLIBDIR \
    BASH_ENV ENV \
    PERL5OPT PERL5LIB RUBYOPT RUBYLIB NODE_OPTIONS \
    GCONV_PATH LOCPATH NLSPATH
}

# Production root always execs /usr/bin/setpriv. The security harness stubs the
# shell function because a user namespace cannot map uid 1000; honor that stub
# only when MSS_LOGIN_TEST_MODE=1.
invoke_setpriv() {
  if [[ "${MSS_LOGIN_TEST_MODE:-}" == "1" ]] && declare -F setpriv >/dev/null 2>&1; then
    setpriv "$@"
    return
  fi
  /usr/bin/setpriv "$@"
}

if [[ "$(/usr/bin/id -u)" -eq 0 ]]; then
  sanitize_root_execution_env
else
  # Bytecode stays off mounted source. Set only for the uid 1000 process.
  export PYTHONPYCACHEPREFIX=/tmp/comfy-pycache
fi

comfy_python() {
  if command -v python >/dev/null 2>&1; then
    python --check-hash-based-pycs always "$@"
  else
    python3 --check-hash-based-pycs always "$@"
  fi
}

reset_comfy_pycache() {
  if [[ -n "${PYTHONPYCACHEPREFIX:-}" && "${PYTHONPYCACHEPREFIX}" != "/tmp/comfy-pycache" ]]; then
    echo "[comfyui-deploy] Refusing PYTHONPYCACHEPREFIX=${PYTHONPYCACHEPREFIX}. Only /tmp/comfy-pycache is allowed." >&2
    exit 1
  fi
  export PYTHONPYCACHEPREFIX=/tmp/comfy-pycache
  if [[ "$(/usr/bin/id -u)" -ne 0 ]]; then
    return 0
  fi
  rm -rf /tmp/comfy-pycache
  mkdir -p /tmp/comfy-pycache
  chown "${COMFY_UID}:${COMFY_GID}" /tmp/comfy-pycache
  chmod 0700 /tmp/comfy-pycache
}

COMFY_UID=1000
COMFY_GID=1000
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
  local owner sub target_owner

  if [[ "$kind" == "file" ]]; then
    [[ -e "$path" ]] || return 0
  else
    if [[ ! -L "$path" ]]; then
      mkdir -p "$path"
    fi
  fi

  owner="$(stat -L -c '%u' "$path" 2>/dev/null || stat -c '%u' "$path" 2>/dev/null || echo "$COMFY_UID")"
  if [[ "$owner" != "$COMFY_UID" ]]; then
    echo "[comfyui-deploy] Changing ownership of ${path} from uid ${owner} to ${COMFY_UID}."
    chown -R -H "${COMFY_UID}:${COMFY_GID}" "$path" 2>/dev/null || chown -R "${COMFY_UID}:${COMFY_GID}" "$path" 2>/dev/null || true
  fi

  if [[ -d "$path" ]]; then
    shopt -s nullglob
    for sub in "${path}"/*; do
      if [[ -L "$sub" && -d "$sub" ]]; then
        target_owner="$(stat -L -c '%u' "$sub" 2>/dev/null || echo "$COMFY_UID")"
        if [[ "$target_owner" != "$COMFY_UID" ]]; then
          echo "[comfyui-deploy] Changing ownership of symlinked subfolder ${sub} from uid ${target_owner} to ${COMFY_UID}."
          chown -R -H "${COMFY_UID}:${COMFY_GID}" "$sub" 2>/dev/null || chown -R "${COMFY_UID}:${COMFY_GID}" "$sub" 2>/dev/null || true
        fi
      fi
    done
    shopt -u nullglob
  fi
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

# git as uid 1000. Root must not read node git metadata. safe.directory is
# only the directory being inspected, not a global wildcard.
git_as_comfy() {
  local dir="$1"
  shift
  if [[ "$(id -u)" -eq 0 ]]; then
    invoke_setpriv --reuid="${COMFY_UID}" --regid="${COMFY_GID}" --init-groups --inh-caps=-all -- \
      git -C "$dir" -c "safe.directory=${dir}" "$@"
    return
  fi
  git -C "$dir" -c "safe.directory=${dir}" "$@"
}

git_remote_matches_mss_login() {
  local dir="$1"
  local canon top url
  [[ -d "$dir" && ! -L "$dir" ]] || return 1
  canon="$(realpath "$dir")"
  top="$(git_as_comfy "$canon" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$top" ]] || return 1
  top="$(realpath "$top")"
  [[ "$top" == "$canon" ]] || return 1
  url="$(git_as_comfy "$canon" remote get-url origin 2>/dev/null || true)"
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

mss_login_folder_name() {
  # Production always loads custom_nodes/MSS-Login. Tests may set MSS_LOGIN_DIR.
  if [[ "${MSS_LOGIN_TEST_MODE:-}" == "1" && -n "${MSS_LOGIN_DIR:-}" ]]; then
    printf '%s\n' "$MSS_LOGIN_DIR"
    return 0
  fi
  printf '%s\n' "MSS-Login"
}

mss_login_shadow_dest() {
  local nodes_root base
  nodes_root="${NODES_DIR:-/app/ComfyUI/custom_nodes}"
  base="$(mss_login_folder_name)"
  if [[ -z "$base" || "$base" == "." || "$base" == ".." || "$base" == *"/"* || "$base" == *$'\n'* ]]; then
    echo "[comfyui-deploy] MSS-Login folder name must be a single path segment." >&2
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

# Last mountinfo entry whose mount point is exactly $1.
# Field 4 is the mount root inside the filesystem. Field 5 is the mount point.
# The fstype is the token after " - ". A direct tmpfs has mount root "/".
# A bind of a subdirectory does not.
mount_info_at() {
  local want="$1" which="$2"
  local info line point fstype root last_fs="" last_root=""
  info="$(mss_mountinfo_file)"
  [[ -r "$info" ]] || return 1
  want="$(realpath -m "$want")"
  while IFS= read -r line; do
    [[ "$line" == *" - "* ]] || continue
    point="$(awk '{print $5}' <<<"$line")"
    point="$(unescape_mount_field "$point")"
    point="$(realpath -m "$point")"
    [[ "$point" == "$want" ]] || continue
    root="$(awk '{print $4}' <<<"$line")"
    root="$(unescape_mount_field "$root")"
    fstype="${line#* - }"
    fstype="${fstype%% *}"
    last_fs="$fstype"
    last_root="$root"
  done <"$info"
  [[ -n "$last_fs" ]] || return 1
  if [[ "$which" == "root" ]]; then
    printf '%s\n' "$last_root"
  else
    printf '%s\n' "$last_fs"
  fi
}

mount_fstype() {
  mount_info_at "$1" fstype
}

mount_root_field() {
  mount_info_at "$1" root
}

shadow_mount_is_direct_tmpfs() {
  local dest="$1" fstype root
  if ! fstype="$(mount_fstype "$dest")"; then
    echo "MSS-Login shadow at ${dest} is not mounted. Refusing to read or import the host directory."
    return 1
  fi
  root="$(mount_root_field "$dest")"
  if [[ "$fstype" != "tmpfs" || "$root" != "/" ]]; then
    echo "MSS-Login shadow at ${dest} is not tmpfs (fstype ${fstype:-missing}, mount root ${root:-missing}). Refusing to read or import the host directory."
    return 1
  fi
  return 0
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
  local rel parent
  [[ -f "${manifest}.dirs" && -f "${manifest}.entries" ]] || return 1
  while IFS= read -r rel || [[ -n "$rel" ]]; do
    [[ -z "$rel" || "$rel" == \#* ]] && continue
    manifest_path_ok "$rel" || return 1
    mkdir -p "${dest}/${rel}" || return 1
  done <"${manifest}.dirs"
  while IFS= read -r rel || [[ -n "$rel" ]]; do
    [[ -z "$rel" || "$rel" == \#* ]] && continue
    manifest_path_ok "$rel" || return 1
    parent="$(dirname "$rel")"
    mkdir -p "${dest}/${parent}" || return 1
    if [[ -L "${src}/${rel}" || -f "${src}/${rel}" ]]; then
      cp -P -- "${src}/${rel}" "${dest}/${rel}" || return 1
    elif [[ -p "${src}/${rel}" ]]; then
      mkfifo "${dest}/${rel}" || return 1
    else
      return 1
    fi
  done <"${manifest}.entries"
}

list_shadow_nondirs() {
  local dest="$1"
  (
    cd "$dest" || exit 1
    find . \
      \( -path './.git' -o -path '*/__pycache__' \) -prune -o \
      ! -type d ! -name '*.pyc' ! -name '*.pyo' -print \
      | sed 's|^\./||' \
      | sort
  )
}

list_shadow_dirs() {
  local dest="$1"
  (
    cd "$dest" || exit 1
    find . \
      \( -path './.git' -o -path '*/__pycache__' \) -prune -o \
      -type d -print \
      | sed 's|^\./||' \
      | sed '/^$/d' \
      | sort
  )
}

verify_manifest() {
  local dest="$1" manifest="$2"
  local list_got
  [[ -f "${manifest}.entries" && -f "${manifest}.dirs" ]] || return 1
  list_got="$(mktemp)"
  list_shadow_nondirs "$dest" >"$list_got"
  if ! diff -q "${manifest}.entries" "$list_got" >/dev/null 2>&1; then
    echo "[comfyui-deploy] Shadow non-directory list does not match the baked manifest." >&2
    diff -u "${manifest}.entries" "$list_got" >&2 || true
    rm -f "$list_got"
    return 1
  fi
  list_shadow_dirs "$dest" >"$list_got"
  if ! diff -q "${manifest}.dirs" "$list_got" >/dev/null 2>&1; then
    echo "[comfyui-deploy] Shadow directory list does not match the baked manifest." >&2
    diff -u "${manifest}.dirs" "$list_got" >&2 || true
    rm -f "$list_got"
    return 1
  fi
  rm -f "$list_got"
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
  invoke_setpriv --reuid="${COMFY_UID}" --regid="${COMFY_GID}" --init-groups --inh-caps=-all -- test -w "$dest"
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
  invoke_setpriv --reuid="${COMFY_UID}" --regid="${COMFY_GID}" --init-groups --inh-caps=-all -- test -w "$file"
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
  local dest reason
  dest="$(mss_login_shadow_dest)" || exit 1
  if ! reason="$(shadow_mount_is_direct_tmpfs "$dest")"; then
    refuse_mss_login "$reason"
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
    if [[ ! -d "$node" ]]; then
      echo "[comfyui-deploy] Skipping custom node ${name}: not a directory or broken symlink." >&2
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

# Carried over from development 9dc33b1 (user-scripts/01-download-models.sh).
# Runs the baked, root-owned /usr/local/bin/mss-download-models as uid 1000
# after the MSS-Login shadow and pin checks. The host user-scripts directory
# is read for the download list only; no host script is executed, and the
# downloader writes only under the models directory. Failures are logged and
# startup continues, as before. Set DOWNLOAD_MODELS=false to skip.
run_model_downloads() {
  local list="${MSS_MODELS_LIST:-/home/comfy/user-scripts/models-to-download.txt}"
  if ! is_truthy "${DOWNLOAD_MODELS:-true}"; then
    echo "[comfyui-deploy] DOWNLOAD_MODELS is off; skipping model downloads."
    return 0
  fi
  if [[ "$(id -u)" -ne "$COMFY_UID" ]]; then
    echo "[comfyui-deploy] Refusing model downloads as uid $(id -u); they run only as uid ${COMFY_UID}." >&2
    return 0
  fi
  if [[ -z "${MODELS_TO_DOWNLOAD:-}" && ! -f "$list" ]]; then
    echo "[comfyui-deploy] No model download list at ${list}; skipping model downloads."
    return 0
  fi
  MODELS_DIR="${MODELS_DIR:-/app/ComfyUI/models}" MSS_MODELS_LIST="$list" \
    /bin/bash /usr/local/bin/mss-download-models \
    || echo "[comfyui-deploy] Model downloads finished with exit code $? (continuing startup)." >&2
}

prepare_as_root() {
  local dest reason
  export HOME=/home/comfy
  export USER=comfy
  export LOGNAME=comfy

  reset_comfy_pycache

  # Confirm the shadow mount before chown -R. A missing tmpfs would otherwise
  # let chown walk the host MSS-Login checkout that the mount is supposed to hide.
  dest="$(mss_login_shadow_dest)" || exit 1
  if ! reason="$(shadow_mount_is_direct_tmpfs "$dest")"; then
    refuse_mss_login "$reason"
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

  # ensure_owned walks custom_nodes and chowns the still-empty tmpfs to uid
  # 1000. prepare_mss_login then copies the pin and locks that tree root:root
  # before setpriv. The mounted .bashrc is not sourced.
  prepare_mss_login
  reject_legacy_manager_nodes
  if comfyui_manager_enabled; then
    verify_comfyui_manager_tree
  fi
}

# MSS-Login 1d9acbc reads auto_update from DATA_DIR/config.json, not from an
# environment variable. enabled stays true and mode is notify, so a new
# release is still reported. mode auto is not used. There is no stack
# variable that changes this. python -S avoids a uid-1000 sitecustomize.
force_mss_login_auto_update_notify() {
  local data
  data="${MSS_LOGIN_DATA_DIR:-/data/mss-login}"
  comfy_python -S - "$data" <<'PY'
import json
import os
import sys

data = sys.argv[1]
path = os.path.join(data, "config.json")
os.makedirs(data, exist_ok=True)
cfg = {}
if os.path.isfile(path):
    try:
        with open(path, encoding="utf-8") as handle:
            loaded = json.load(handle)
        if isinstance(loaded, dict):
            cfg = loaded
        else:
            sys.stderr.write(f"[comfyui-deploy] {path} is not a JSON object; leaving it unchanged.\n")
            sys.exit(1)
    except json.JSONDecodeError:
        sys.stderr.write(f"[comfyui-deploy] {path} is not valid JSON; leaving it unchanged.\n")
        sys.exit(1)
auto_update = cfg.get("auto_update")
if not isinstance(auto_update, dict):
    auto_update = {}
auto_update["enabled"] = True
auto_update["mode"] = "notify"
cfg["auto_update"] = auto_update
cfg["auto_install_deps"] = False
experimental = cfg.get("experimental")
if not isinstance(experimental, dict):
    experimental = {}
experimental["install_other_nodes_deps"] = False
cfg["experimental"] = experimental
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(cfg, handle, indent=4)
    handle.write("\n")
os.replace(tmp, path)
PY
  echo "[comfyui-deploy] MSS-Login auto_update in ${data}/config.json is enabled=true, mode=notify. In-place update is refused by the image patch."
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

# Flags from ComfyUI comfy/cli_args.py at 0dbfd493b4cc604db743c699f0f7ce01348e54a4
# that change which nodes load or where custom_nodes, models, or user data live.
# Full names from comfy/cli_args.py at 0dbfd493b4cc604db743c699f0f7ce01348e54a4.
# argparse accepts an unambiguous prefix, so any --token that is a prefix of
# one of these (for example --base-dir or --disable-all) is refused too.
cli_denied_flag_names() {
  printf '%s\n' \
    --disable-all-custom-nodes \
    --whitelist-custom-nodes \
    --enable-manager \
    --enable-manager-legacy-ui \
    --disabled-nodes-config \
    --disable-partner-nodes \
    --disable-api-nodes \
    --offline \
    --base-directory \
    --extra-model-paths-config \
    --output-directory \
    --temp-directory \
    --input-directory \
    --previews-directory \
    --user-directory \
    --models-directory \
    --front-end-root \
    --comfy-api-base \
    --disable-manager-ui
}

cli_node_path_flag_denied() {
  local token="${1%%=*}" flag
  [[ "$token" == --* ]] || return 1
  while IFS= read -r flag; do
    [[ -n "$flag" ]] || continue
    if [[ "$flag" == "$token" || "$flag" == "$token"* ]]; then
      return 0
    fi
  done < <(cli_denied_flag_names)
  return 1
}

baked_frontend_flag_value() {
  local version="v1.55.11"
  if [[ "${MSS_LOGIN_TEST_MODE:-}" == "1" && -n "${MSS_FRONTEND_VERSION:-}" ]]; then
    version="$MSS_FRONTEND_VERSION"
  elif [[ -f /opt/comfy-frontend/VERSION ]]; then
    version="$(tr -d '[:space:]' < /opt/comfy-frontend/VERSION)"
  fi
  printf '%s\n' "Comfy-Org/ComfyUI_frontend@${version}"
}

# Drop a user --front-end-version when it matches the baked release, then keep
# exactly one canonical flag so ComfyUI uses web_custom_versions and does not
# download. Any other value refuses. Never fetches at runtime.
normalize_frontend_flag() {
  local baked token prev="" seen="" value=""
  local -a args=() kept=()
  baked="$(baked_frontend_flag_value)"
  set -f
  read -r -a args <<< "${CLI_ARGS:-}"
  set +f
  for token in "${args[@]}"; do
    if [[ -n "$prev" ]]; then
      value="$token"
      prev=""
      if [[ "$value" != "$baked" ]]; then
        refuse_mss_login "Refusing --front-end-version ${value}. The image only serves the baked frontend ${baked} and does not download another."
      fi
      seen=1
      echo "[comfyui-deploy] --front-end-version ${value} matches the baked frontend. No runtime download."
      continue
    fi
    if [[ "$token" == --front-end-version=* || ( "$token" == --*=* && "--front-end-version" == "${token%%=*}"* ) ]]; then
      value="${token#*=}"
      if [[ "$value" != "$baked" ]]; then
        refuse_mss_login "Refusing --front-end-version ${value}. The image only serves the baked frontend ${baked} and does not download another."
      fi
      seen=1
      echo "[comfyui-deploy] --front-end-version ${value} matches the baked frontend. No runtime download."
      continue
    fi
    if [[ "--front-end-version" == "$token" || "--front-end-version" == "$token"* ]]; then
      prev=1
      continue
    fi
    kept+=("$token")
  done
  if [[ -n "$prev" ]]; then
    refuse_mss_login "Refusing --front-end-version without a value."
  fi
  CLI_ARGS=""
  for token in "${kept[@]}"; do
    if [[ -z "$CLI_ARGS" ]]; then
      CLI_ARGS="$token"
    else
      CLI_ARGS="${CLI_ARGS} ${token}"
    fi
  done
  if [[ -n "$CLI_ARGS" ]]; then
    CLI_ARGS="${CLI_ARGS} --front-end-version ${baked}"
  else
    CLI_ARGS="--front-end-version ${baked}"
  fi
  if [[ -z "$seen" ]]; then
    echo "[comfyui-deploy] Using baked frontend ${baked}. No runtime download."
  fi
  export CLI_ARGS
}

collapse_ws() {
  local value="$1"
  local -a parts=()
  set -f
  # shellcheck disable=SC2086
  read -r -a parts <<< "$value"
  set +f
  local IFS=' '
  printf '%s' "${parts[*]}"
}

valid_tcp_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]{1,5}$ ]] || return 1
  (( 10#$value >= 1 && 10#$value <= 65535 )) || return 1
}

# A token counts when it is the flag or a prefix of it, including --flag=value.
# That matches the denied-flag check, so --po is seen as --port.
cli_has_flag() {
  local argline="$1" flag="$2" token bare
  local -a arr=()
  set -f
  read -r -a arr <<< "$argline"
  set +f
  for token in "${arr[@]}"; do
    bare="${token%%=*}"
    [[ "$bare" == --* ]] || continue
    if [[ "$flag" == "$bare" || "$flag" == "$bare"* ]]; then
      return 0
    fi
  done
  return 1
}

# Last --port wins, matching argparse. Image defaults are omitted when the
# user string already contains --listen or --port.
mss_listen_port() {
  local argline="${1:-${CLI_ARGS:-}}" token bare prev="" value=""
  local -a arr=()
  set -f
  read -r -a arr <<< "$argline"
  set +f
  for token in "${arr[@]}"; do
    if [[ -n "$prev" ]]; then
      value="$token"
      prev=""
      continue
    fi
    bare="${token%%=*}"
    if [[ "$bare" == --* && ( "--port" == "$bare" || "--port" == "$bare"* ) ]]; then
      if [[ "$token" == *=* ]]; then
        value="${token#*=}"
      else
        prev=1
      fi
    fi
  done
  if [[ -n "$prev" ]]; then
    refuse_mss_login "Refusing --port without a value."
  fi
  if [[ -z "$value" ]]; then
    value="${COMFYUI_PORT:-9008}"
  fi
  if ! valid_tcp_port "$value"; then
    refuse_mss_login "Refusing port '${value}'. A port must be an integer from 1 to 65535."
  fi
  printf '%s\n' "$value"
}

# CLI_ARGS (stack 250) and EXTRA_CLI_ARGS are the same extra argument string.
# If both are set they must match. Defaults are added only for flags the user
# did not already pass, so a user --listen/--port is the one that is launched.
build_cli_args() {
  local alias_args extra_args user_args listen port cors vram token
  if [[ -n "${STACK_CLI_ARGS+x}" ]]; then
    alias_args="${STACK_CLI_ARGS}"
  else
    alias_args="${CLI_ARGS-}"
  fi
  extra_args="${EXTRA_CLI_ARGS-}"
  alias_args="$(collapse_ws "$alias_args")"
  extra_args="$(collapse_ws "$extra_args")"
  if [[ -n "$alias_args" && -n "$extra_args" && "$alias_args" != "$extra_args" ]]; then
    refuse_mss_login "CLI_ARGS and EXTRA_CLI_ARGS are both set and differ. Set only one, or set them to the same text."
  fi
  if [[ -n "$alias_args" ]]; then
    user_args="$alias_args"
  else
    user_args="$extra_args"
  fi
  listen="${COMFYUI_HOST:-0.0.0.0}"
  port="${COMFYUI_PORT:-9008}"
  if ! valid_tcp_port "$port"; then
    refuse_mss_login "Refusing COMFYUI_PORT '${port}'. A port must be an integer from 1 to 65535."
  fi
  cors="${CORS:-*}"
  vram="${VRAM_RESERVE_GB:-1.5}"
  local -a defaults=()
  cli_has_flag "$user_args" --listen || defaults+=(--listen "$listen")
  cli_has_flag "$user_args" --port || defaults+=(--port "$port")
  cli_has_flag "$user_args" --enable-cors-header || defaults+=("--enable-cors-header=${cors}")
  cli_has_flag "$user_args" --use-pytorch-cross-attention || defaults+=(--use-pytorch-cross-attention)
  cli_has_flag "$user_args" --reserve-vram || defaults+=(--reserve-vram "$vram")
  cli_has_flag "$user_args" --disable-smart-memory || defaults+=(--disable-smart-memory)
  cli_has_flag "$user_args" --cache-lru || defaults+=(--cache-lru 1)
  CLI_ARGS=""
  for token in "${defaults[@]}"; do
    if [[ -z "$CLI_ARGS" ]]; then
      CLI_ARGS="$token"
    else
      CLI_ARGS="${CLI_ARGS} ${token}"
    fi
  done
  if [[ -n "$user_args" ]]; then
    if [[ -z "$CLI_ARGS" ]]; then
      CLI_ARGS="$user_args"
    else
      CLI_ARGS="${CLI_ARGS} ${user_args}"
    fi
  fi
  export CLI_ARGS
  normalize_frontend_flag
  mss_listen_port >/dev/null
}

refuse_cli_node_path_flags() {
  local arg
  local -a args=()
  set -f
  read -r -a args <<< "${CLI_ARGS:-} $*"
  set +f
  for arg in "${args[@]}"; do
    if cli_node_path_flag_denied "$arg"; then
      refuse_mss_login "Refusing CLI flag ${arg%%=*}. It changes custom-node loading or a base path. Refused flags: --disable-all-custom-nodes, --whitelist-custom-nodes, --enable-manager, --enable-manager-legacy-ui, --disabled-nodes-config, --disable-partner-nodes, --disable-api-nodes, --offline, --base-directory, --extra-model-paths-config, --output-directory, --temp-directory, --input-directory, --previews-directory, --user-directory, --models-directory, --front-end-root, --comfy-api-base, --disable-manager-ui. The image adds --enable-manager itself when COMFYUI_MANAGER_ENABLED is true."
    fi
  done
}

extra_model_paths_file() {
  if [[ "${MSS_LOGIN_TEST_MODE:-}" == "1" && -n "${MSS_EXTRA_MODEL_PATHS:-}" ]]; then
    printf '%s\n' "$MSS_EXTRA_MODEL_PATHS"
  else
    printf '%s\n' "/app/ComfyUI/extra_model_paths.yaml"
  fi
}

refuse_extra_model_paths_custom_nodes() {
  local path status
  path="$(extra_model_paths_file)"
  if [[ ! -e "$path" ]]; then
    return 0
  fi
  if [[ ! -f "$path" ]]; then
    refuse_mss_login "${path} is not a file. Refusing to start."
  fi
  set +e
  comfy_python - "$path" <<'PY'
import sys

path = sys.argv[1]
try:
    import yaml
except Exception:
    sys.stderr.write("PyYAML is not importable; refusing to guess extra_model_paths.yaml.\n")
    sys.exit(2)

def has_custom_nodes(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if str(key) == "custom_nodes" or has_custom_nodes(value):
                return True
        return False
    if isinstance(node, list):
        return any(has_custom_nodes(item) for item in node)
    return False

try:
    with open(path, encoding="utf-8") as handle:
        data = yaml.safe_load(handle)
except Exception as exc:
    sys.stderr.write(f"extra_model_paths.yaml could not be parsed: {exc}\n")
    sys.exit(3)
if has_custom_nodes(data):
    sys.exit(4)
sys.exit(0)
PY
  status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    refuse_mss_login "extra_model_paths.yaml at ${path} is unreadable, unparsable, or contains a custom_nodes key."
  fi
}

# ComfyUI-Manager is baked at /opt/comfyui-manager/site (root-owned, pinned,
# patched by comfyui-manager-mss-lockdown.patch). It is enabled by default and
# reachable only by the MSS-Login owner, read-only. The user may not pass
# --enable-manager, --enable-manager-legacy-ui or --disable-manager-ui; the
# entrypoint adds --enable-manager itself after the CLI checks.
comfyui_manager_enabled() {
  is_truthy "${COMFYUI_MANAGER_ENABLED:-true}"
}

comfyui_manager_root() {
  if [[ "${MSS_LOGIN_TEST_MODE:-}" == "1" && -n "${MSS_MANAGER_ROOT:-}" ]]; then
    printf '%s\n' "$MSS_MANAGER_ROOT"
  else
    printf '%s\n' "/opt/comfyui-manager"
  fi
}

comfyui_manager_user_dir() {
  if [[ "${MSS_LOGIN_TEST_MODE:-}" == "1" && -n "${MSS_MANAGER_USER_DIR:-}" ]]; then
    printf '%s\n' "$MSS_MANAGER_USER_DIR"
  else
    printf '%s\n' "/app/ComfyUI/user/__manager"
  fi
}

refuse_comfyui_manager() {
  echo "[comfyui-deploy] Refusing to start. $*" >&2
  echo "[comfyui-deploy] Set COMFYUI_MANAGER_ENABLED=false to start without ComfyUI-Manager." >&2
  exit 1
}

# Root-owned tree, lockdown patch recorded, manifest match, and (as root)
# uid 1000 cannot write it. Any failure refuses to start.
verify_comfyui_manager_tree() {
  local root site manifest stray
  root="$(comfyui_manager_root)"
  site="${root}/site"
  manifest="${root}/MANIFEST"
  if [[ ! -d "$site" || -L "$site" || -L "$root" ]]; then
    refuse_comfyui_manager "ComfyUI-Manager is enabled but ${site} is missing or a symlink."
  fi
  if [[ ! -f "$manifest" || ! -f "${manifest}.entries" || ! -f "${manifest}.dirs" ]]; then
    refuse_comfyui_manager "ComfyUI-Manager manifest is missing at ${manifest}."
  fi
  if [[ ! -f "${root}/PATCHES" ]] || ! grep -qx 'comfyui-manager-mss-lockdown.patch' "${root}/PATCHES"; then
    refuse_comfyui_manager "ComfyUI-Manager at ${root} does not record comfyui-manager-mss-lockdown.patch."
  fi
  if [[ ! -f "${site}/comfyui_manager/mss_lockdown.py" || -L "${site}/comfyui_manager/mss_lockdown.py" ]]; then
    refuse_comfyui_manager "ComfyUI-Manager at ${site} has no mss_lockdown.py."
  fi
  if ! verify_manifest "$site" "$manifest"; then
    refuse_comfyui_manager "ComfyUI-Manager at ${site} does not match ${manifest}."
  fi
  if [[ "${MSS_LOGIN_TEST_MODE:-}" != "1" ]]; then
    stray="$(find "$root" ! -uid 0 -print -quit 2>/dev/null || true)"
    if [[ -n "$stray" ]]; then
      refuse_comfyui_manager "ComfyUI-Manager path ${stray} is not owned by root."
    fi
    if [[ "$(/usr/bin/id -u)" -eq 0 ]]; then
      if ! assert_uid1000_cannot_write "$site"; then
        refuse_comfyui_manager "uid ${COMFY_UID} could modify ComfyUI-Manager at ${site}."
      fi
    else
      stray="$(find "$root" -writable -print -quit 2>/dev/null || true)"
      if [[ -n "$stray" ]]; then
        refuse_comfyui_manager "ComfyUI-Manager path ${stray} is writable by uid $(id -u)."
      fi
    fi
  fi
  echo "[comfyui-deploy] ComfyUI-Manager $(tr -d '[:space:]' < "${root}/VERSION" 2>/dev/null || echo unknown) at ${site} matches its manifest."
}

# A custom_nodes entry whose name contains comfyui-manager is the legacy
# custom-node Manager. ComfyUI's comfyui_manager.should_be_disabled skips it
# when --enable-manager is set. Without --enable-manager it would load with
# no owner gate, so startup refuses.
reject_legacy_manager_nodes() {
  local nodes_root path name
  nodes_root="${NODES_DIR:-/app/ComfyUI/custom_nodes}"
  [[ -d "$nodes_root" ]] || return 0
  shopt -s nullglob dotglob
  for path in "${nodes_root}"/*; do
    name="$(basename "$path")"
    [[ "${name,,}" == *comfyui-manager* ]] || continue
    loader_would_import "$path" || continue
    if comfyui_manager_enabled; then
      echo "[comfyui-deploy] ${path} is a legacy ComfyUI-Manager. ComfyUI skips it while the baked Manager is enabled." >&2
    else
      shopt -u nullglob dotglob
      refuse_comfyui_manager "${path} is a legacy ComfyUI-Manager and would load with no owner gate. Remove it, rename it to *.disabled, or enable the baked Manager."
    fi
  done
  shopt -u nullglob dotglob
}

# Written as uid 1000 at every start. The whole config.ini is replaced, so a
# value changed in the user volume does not survive a restart. The patched
# Manager also forces these keys in read_config(). install-scripts.txt and
# restore-snapshot.json are renamed *.refused-<epoch>; the patched Manager
# never reads them.
force_comfyui_manager_config() {
  local dir status
  dir="$(comfyui_manager_user_dir)"
  set +e
  comfy_python -S - "$dir" <<'PY'
import os
import sys
import time

d = sys.argv[1]
if os.path.islink(d):
    sys.stderr.write(f"[comfyui-deploy] {d} is a symlink.\n")
    sys.exit(2)
os.makedirs(d, exist_ok=True)
if not os.path.isdir(d) or os.path.islink(d):
    sys.stderr.write(f"[comfyui-deploy] {d} is not a directory.\n")
    sys.exit(2)
forced = [
    ("security_level", "strong"),
    ("network_mode", "offline"),
    ("db_mode", "local"),
    ("use_uv", "false"),
    ("use_unified_resolver", "false"),
    ("bypass_ssl", "false"),
    ("file_logging", "false"),
    ("http_channel_enabled", "false"),
    ("channel_url", "https://raw.githubusercontent.com/ltdrdata/ComfyUI-Manager/main"),
    ("default_cache_as_channel_url", "false"),
    ("allow_git_url_install", "false"),
    ("allow_pip_install", "false"),
    ("allow_flagged_nodepack_install", "false"),
    ("always_lazy_install", "false"),
    ("model_download_by_agent", "false"),
    ("update_policy", "stable-comfyui"),
    ("git_exe", ""),
    ("share_option", "none"),
    ("downgrade_blacklist", ""),
    ("windows_selector_event_loop_policy", "false"),
    ("verbose", "false"),
]
content = "# Written by the comfyui-mss-login entrypoint at every start. Edits are discarded.\n[default]\n"
content += "".join(f"{k} = {v}\n" for k, v in forced)
path = os.path.join(d, "config.ini")
old = None
if os.path.islink(path) or (os.path.lexists(path) and not os.path.isfile(path)):
    old = "<not a regular file>"
elif os.path.isfile(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        old = handle.read()
if old is not None and old != content:
    sys.stderr.write(f"[comfyui-deploy] WARNING: {path} differed from the forced ComfyUI-Manager config. It was replaced.\n")
if os.path.isdir(path) and not os.path.islink(path):
    sys.stderr.write(f"[comfyui-deploy] {path} is a directory.\n")
    sys.exit(2)
tmp = path + ".mss-tmp"
if os.path.lexists(tmp):
    os.unlink(tmp)
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o644)
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    handle.write(content)
os.replace(tmp, path)
stamp = int(time.time())
scripts = os.path.join(d, "startup-scripts")
if os.path.isdir(scripts) and not os.path.islink(scripts):
    for name in ("install-scripts.txt", "restore-snapshot.json"):
        target = os.path.join(scripts, name)
        if os.path.lexists(target):
            os.replace(target, f"{target}.refused-{stamp}")
            sys.stderr.write(f"[comfyui-deploy] WARNING: renamed pending Manager {name} to {name}.refused-{stamp}. It is never run.\n")
PY
  status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    refuse_comfyui_manager "Could not force the ComfyUI-Manager config in ${dir}."
  fi
  echo "[comfyui-deploy] ComfyUI-Manager config in ${dir}/config.ini is forced: security_level=strong, network_mode=offline, no pip, no git-url, no file logging."
}

# PYTHONPATH is the root-owned site directory only. The import must resolve
# there, not to a comfyui_manager planted in the uid 1000 venv.
prepare_comfyui_manager_import() {
  local site want got
  site="$(comfyui_manager_root)/site"
  export PYTHONPATH="$site"
  want="${site}/comfyui_manager/__init__.py"
  got="$(comfy_python -c 'import importlib.util; s = importlib.util.find_spec("comfyui_manager"); print(s.origin if s else "")' 2>/dev/null || true)"
  if [[ "$got" != "$want" ]]; then
    refuse_comfyui_manager "comfyui_manager resolves to '${got:-nothing}', expected ${want}."
  fi
}

# GET /login must be HTTP 200 and include the MSS-Login page marker.
# Redirects are not enough: another service could answer 302.
mss_login_login_body_ok() {
  local code="$1" body="$2"
  [[ "$code" == "200" ]] || return 1
  grep -q 'id="mss-login-auth-app"' "$body"
}

wait_for_mss_login_route() {
  local port code n=0 body
  port="${1:-9008}"
  body="$(mktemp)"
  while [[ "$n" -lt 120 ]]; do
    n=$((n + 1))
    code="$(curl -s -o "$body" -w '%{http_code}' --max-time 5 "http://127.0.0.1:${port}/login" || true)"
    if mss_login_login_body_ok "$code" "$body"; then
      echo "[comfyui-deploy] MSS-Login GET /login returned 200 with the login page."
      rm -f "$body"
      return 0
    fi
    sleep 5
  done
  echo "[comfyui-deploy] MSS-Login GET /login last status was ${code:-none}." >&2
  rm -f "$body"
  return 1
}

launch_comfyui() {
  local detect_line
  build_cli_args
  echo "[comfyui-deploy] Initializing ComfyUI (${OS} / ${ARCH}, DEVICE_TYPE=${DEVICE_TYPE}, USE_CPU=${USE_CPU})."

  require_writable "${MODELS_DIR:-/app/ComfyUI/models}"
  require_writable "${NODES_DIR:-/app/ComfyUI/custom_nodes}"
  require_writable "${MSS_LOGIN_DATA_DIR:-/data/mss-login}"
  require_writable /app/ComfyUI/output
  require_writable /app/ComfyUI/input
  require_writable /app/ComfyUI/user

  warn_if_insightface_models_missing
  force_mss_login_auto_update_notify
  prepare_mss_login
  reject_legacy_manager_nodes
  if comfyui_manager_enabled; then
    verify_comfyui_manager_tree
    force_comfyui_manager_config
  fi

  detect_line="$(
    comfy_python - <<'PY'
import importlib.util
import os
import sys

mss = os.environ.get("MSS_DIR", "")
script_path = os.path.join(mss, "utils", "install_deps.py")
if not os.path.isfile(script_path):
    print("cpu pypi requirements.txt")
    sys.exit(0)

spec = importlib.util.spec_from_file_location("mss_install_deps", script_path)
if not spec or not spec.loader:
    print("cpu pypi requirements.txt")
    sys.exit(0)

mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
plan = mod.detect_torch_install_plan() if hasattr(mod, "detect_torch_install_plan") else {}
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
    if comfy_python -c "import torch, torchvision, torchaudio" &>/dev/null; then
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
  run_model_downloads

  if [[ "$TARGET_BACKEND" == "cpu" && "$CLI_ARGS" != *"--cpu"* ]]; then
    CLI_ARGS="${CLI_ARGS} --cpu"
    echo "[comfyui-deploy] Running in CPU execution mode."
  fi

  prepend_cuda_library_path

  refuse_cli_node_path_flags "$@"
  refuse_extra_model_paths_custom_nodes

  cd /app/ComfyUI
  local -a comfy_argv=()
  set -f
  read -r -a comfy_argv <<< "$CLI_ARGS"
  set +f
  if comfyui_manager_enabled; then
    prepare_comfyui_manager_import
    comfy_argv+=(--enable-manager)
    echo "[comfyui-deploy] ComfyUI-Manager is enabled for the MSS-Login owner only (read-only)."
  fi
  echo "[comfyui-deploy] Launching ComfyUI with args: ${comfy_argv[*]} $*"
  comfy_python main.py "${comfy_argv[@]}" "$@" &
  local child=$!
  trap 'kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true' TERM INT
  if ! wait_for_mss_login_route "$(mss_listen_port)"; then
    echo "[comfyui-deploy] Stopping. MSS-Login GET /login did not return 200 with the login page within 600s." >&2
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    exit 1
  fi
  wait "$child"
}

main() {
  if [[ "$(id -u)" -eq 0 ]]; then
    prepare_as_root
    cd /app/ComfyUI
    exec /usr/bin/env \
      PATH="/app/ComfyUI/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      /usr/bin/setpriv \
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
