#!/usr/bin/env bash
# Entrypoint guards for the baked ComfyUI-Manager: CLI flags, the root-owned
# tree and its manifest, the forced config.ini, the import path, and legacy
# Manager folders in custom_nodes. No network and no ComfyUI install.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/entrypoint.sh"
export MSS_LOGIN_TEST_MODE=1

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_refused() {
  local label="$1"
  shift
  local log status
  log="$(mktemp)"
  set +e
  ("$@") >"$log" 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "${label} was not refused: $(cat "$log")"
  rm -f "$log"
}

expect_ok() {
  local label="$1"
  shift
  local log status
  log="$(mktemp)"
  set +e
  ("$@") >"$log" 2>&1
  status=$?
  set -e
  [[ "$status" -eq 0 ]] || fail "${label} failed: $(cat "$log")"
  rm -f "$log"
}

cli_refuses() {
  CLI_ARGS="$1" refuse_cli_node_path_flags
}

cli_case() {
  local flag
  for flag in --enable-manager --enable-manager-legacy-ui --disable-manager-ui \
    --enable-m --enable-manager-l --disable-manager --disable-man "--enable-manager=1" "--disable-manager-ui=true"; do
    expect_refused "CLI ${flag}" cli_refuses "--listen 0.0.0.0 ${flag}"
  done
  expect_ok "CLI stack 250 args" cli_refuses "--listen --port 9008 --enable-cors-header=* --use-pytorch-cross-attention --reserve-vram 1.5 --disable-smart-memory --cache-lru 1"
  echo "manager cli case passed"
}

make_manager_root() {
  local mroot="$1"
  mkdir -p "${mroot}/site/comfyui_manager/glob" "${mroot}/site/comfyui_manager-4.3.dist-info"
  printf 'print("init")\n' >"${mroot}/site/comfyui_manager/__init__.py"
  printf 'OWNER_FLAG = "mss_login_manager_owner"\n' >"${mroot}/site/comfyui_manager/mss_lockdown.py"
  printf 'x = 1\n' >"${mroot}/site/comfyui_manager/glob/manager_server.py"
  printf 'Name: comfyui-manager\nVersion: 4.3\n' >"${mroot}/site/comfyui_manager-4.3.dist-info/METADATA"
  printf '4.3\n' >"${mroot}/VERSION"
  printf 'comfyui-manager-mss-lockdown.patch\n' >"${mroot}/PATCHES"
  bash "${root}/scripts/write-mss-login-manifest.sh" "${mroot}/site" "${mroot}/MANIFEST"
}

verify_tree_at() {
  MSS_MANAGER_ROOT="$1" verify_comfyui_manager_tree
}

tree_case() {
  local base m
  base="$(mktemp -d)"
  m="${base}/good"
  make_manager_root "$m"
  expect_ok "baked tree" verify_tree_at "$m"

  m="${base}/edited"
  make_manager_root "$m"
  printf 'import os; os.system("pip install evil")\n' >>"${m}/site/comfyui_manager/glob/manager_server.py"
  expect_refused "edited Manager file" verify_tree_at "$m"

  m="${base}/extra"
  make_manager_root "$m"
  printf 'evil = 1\n' >"${m}/site/comfyui_manager/evil.py"
  expect_refused "extra Manager file" verify_tree_at "$m"

  m="${base}/extradir"
  make_manager_root "$m"
  mkdir -p "${m}/site/comfyui_manager/plugins"
  expect_refused "extra Manager directory" verify_tree_at "$m"

  m="${base}/pth"
  make_manager_root "$m"
  printf 'import os\n' >"${m}/site/evil.pth"
  expect_refused "planted .pth in site" verify_tree_at "$m"

  m="${base}/nopatch"
  make_manager_root "$m"
  : >"${m}/PATCHES"
  expect_refused "PATCHES without lockdown patch" verify_tree_at "$m"

  m="${base}/nolock"
  make_manager_root "$m"
  rm -f "${m}/site/comfyui_manager/mss_lockdown.py"
  bash "${root}/scripts/write-mss-login-manifest.sh" "${m}/site" "${m}/MANIFEST"
  expect_refused "missing mss_lockdown.py (manifest regenerated)" verify_tree_at "$m"

  m="${base}/nomanifest"
  make_manager_root "$m"
  rm -f "${m}/MANIFEST.dirs"
  expect_refused "missing MANIFEST.dirs" verify_tree_at "$m"

  m="${base}/symsite"
  make_manager_root "${base}/real"
  mkdir -p "$m"
  cp "${base}/real/MANIFEST"* "${base}/real/PATCHES" "${base}/real/VERSION" "$m/"
  ln -s "${base}/real/site" "${m}/site"
  expect_refused "site is a symlink" verify_tree_at "$m"

  m="${base}/symfile"
  make_manager_root "$m"
  rm -f "${m}/site/comfyui_manager/mss_lockdown.py"
  ln -s /etc/hostname "${m}/site/comfyui_manager/mss_lockdown.py"
  expect_refused "mss_lockdown.py is a symlink" verify_tree_at "$m"

  m="${base}/missing"
  expect_refused "missing Manager root" verify_tree_at "$m"
  rm -rf "$base"
  echo "manager tree case passed"
}

force_config_at() {
  MSS_MANAGER_USER_DIR="$1" force_comfyui_manager_config
}

config_value() {
  python3 - "$1" "$2" <<'PY'
import configparser
import sys

c = configparser.ConfigParser(strict=False)
c.read(sys.argv[1])
print(c["default"].get(sys.argv[2], "<missing>"))
PY
}

config_case() {
  local base d log
  base="$(mktemp -d)"
  d="${base}/__manager"
  mkdir -p "${d}/startup-scripts"
  cat >"${d}/config.ini" <<'EOF'
[default]
security_level = weak
network_mode = public
allow_pip_install = True
allow_git_url_install = True
use_uv = True
bypass_ssl = True
file_logging = True
channel_url = http://evil.example
always_lazy_install = True
[extra]
x = 1
EOF
  printf "['/app/ComfyUI/custom_nodes', '#LAZY-INSTALL-SCRIPT', 'python', '-m', 'pip', 'install', 'evil']\n" >"${d}/startup-scripts/install-scripts.txt"
  printf '{}\n' >"${d}/startup-scripts/restore-snapshot.json"
  log="$(mktemp)"
  force_config_at "$d" >"$log" 2>&1 || fail "force config: $(cat "$log")"
  grep -q 'differed from the forced ComfyUI-Manager config' "$log" || fail "tampered config was not reported"
  [[ "$(config_value "${d}/config.ini" security_level)" == "strong" ]] || fail "security_level not forced"
  [[ "$(config_value "${d}/config.ini" network_mode)" == "offline" ]] || fail "network_mode not forced"
  [[ "$(config_value "${d}/config.ini" allow_pip_install)" == "false" ]] || fail "allow_pip_install not forced"
  [[ "$(config_value "${d}/config.ini" allow_git_url_install)" == "false" ]] || fail "allow_git_url_install not forced"
  [[ "$(config_value "${d}/config.ini" use_uv)" == "false" ]] || fail "use_uv not forced"
  [[ "$(config_value "${d}/config.ini" file_logging)" == "false" ]] || fail "file_logging not forced"
  [[ "$(config_value "${d}/config.ini" channel_url)" == "https://raw.githubusercontent.com/ltdrdata/ComfyUI-Manager/main" ]] || fail "channel_url not forced"
  if grep -q '^\[extra\]' "${d}/config.ini"; then
    fail "extra config section survived"
  fi
  [[ ! -e "${d}/startup-scripts/install-scripts.txt" ]] || fail "install-scripts.txt not quarantined"
  [[ ! -e "${d}/startup-scripts/restore-snapshot.json" ]] || fail "restore-snapshot.json not quarantined"
  compgen -G "${d}/startup-scripts/install-scripts.txt.refused-*" >/dev/null || fail "install-scripts.txt rename missing"
  : >"$log"
  force_config_at "$d" >"$log" 2>&1 || fail "second force config"
  if grep -q 'differed' "$log"; then
    fail "unchanged config reported as tampered"
  fi

  printf 'keep\n' >"${base}/target.ini"
  rm -f "${d}/config.ini"
  ln -s "${base}/target.ini" "${d}/config.ini"
  force_config_at "$d" >"$log" 2>&1 || fail "force config over symlink"
  [[ ! -L "${d}/config.ini" && -f "${d}/config.ini" ]] || fail "config.ini symlink not replaced"
  [[ "$(cat "${base}/target.ini")" == "keep" ]] || fail "symlink target was written"

  mkdir -p "${base}/elsewhere"
  ln -s "${base}/elsewhere" "${base}/linked"
  expect_refused "symlinked Manager user dir" force_config_at "${base}/linked"
  rm -rf "$base" "$log"
  echo "manager config case passed"
}

import_at() {
  local site_root="$1" cwd="$2"
  (cd "$cwd" && MSS_MANAGER_ROOT="$site_root" prepare_comfyui_manager_import)
}

import_case() {
  local base
  base="$(mktemp -d)"
  make_manager_root "${base}/m"
  mkdir -p "${base}/clean" "${base}/planted/comfyui_manager"
  printf 'print("planted")\n' >"${base}/planted/comfyui_manager/__init__.py"
  expect_ok "import resolves to baked site" import_at "${base}/m" "${base}/clean"
  expect_refused "planted comfyui_manager earlier on sys.path" import_at "${base}/m" "${base}/planted"
  expect_refused "missing site" import_at "${base}/none" "${base}/clean"
  rm -rf "$base"
  echo "manager import case passed"
}

legacy_case() {
  local base
  base="$(mktemp -d)"
  mkdir -p "${base}/nodes/ComfyUI-Manager"
  expect_ok "legacy Manager folder with baked Manager on" env NODES_DIR="${base}/nodes" COMFYUI_MANAGER_ENABLED=true bash -c "source '${root}/entrypoint.sh'; reject_legacy_manager_nodes"
  expect_refused "legacy Manager folder with baked Manager off" env NODES_DIR="${base}/nodes" COMFYUI_MANAGER_ENABLED=false bash -c "source '${root}/entrypoint.sh'; reject_legacy_manager_nodes"
  rm -rf "${base}/nodes/ComfyUI-Manager"
  mkdir -p "${base}/nodes/comfyui-manager-main"
  expect_refused "renamed legacy folder (substring) with Manager off" env NODES_DIR="${base}/nodes" COMFYUI_MANAGER_ENABLED=false bash -c "source '${root}/entrypoint.sh'; reject_legacy_manager_nodes"
  rm -rf "${base}/nodes/comfyui-manager-main"
  mkdir -p "${base}/nodes/ComfyUI-Manager.disabled"
  printf 'x\n' >"${base}/nodes/comfyui-manager-notes.txt"
  expect_ok "disabled folder and non-.py file" env NODES_DIR="${base}/nodes" COMFYUI_MANAGER_ENABLED=false bash -c "source '${root}/entrypoint.sh'; reject_legacy_manager_nodes"
  rm -rf "$base"
  echo "legacy manager case passed"
}

lock_parity_case() {
  grep -qx 'comfyui-manager-mss-lockdown.patch' <(sed -n 's/.*printf .%s\\n. "\(comfyui-manager-mss-lockdown.patch\)".*/\1/p' "${root}/Dockerfile") \
    || fail "Dockerfile does not record comfyui-manager-mss-lockdown.patch in PATCHES"
  grep -q 'mss-login-manager-owner-gate.patch" > /opt/mss-login/PATCHES' "${root}/Dockerfile" \
    || fail "Dockerfile does not record the MSS-Login owner gate patch"
  local spec name lock_file lock_text
  lock_file="${root}/config/comfyui-manager-requirements.lock"
  lock_text="$(cat "$lock_file")"
  while IFS= read -r spec; do
    [[ -z "$spec" || "$spec" == \#* || "$spec" == " "* ]] && continue
    spec="${spec%% \\}"
    requirement_line_is_safe_spec "$spec" || fail "lock line is not a plain spec: ${spec}"
    [[ "$spec" == *==* ]] || fail "lock line is not pinned: ${spec}"
    name="${spec%%==*}"
    awk -v n="$name" 'BEGIN{f=0} $1==n"=="substr($1,length(n)+3){f=1} f&&/--hash=sha256:[0-9a-f]{64}/{print; exit}' \
      <<<"$lock_text" | grep -q . || fail "lock entry ${name} has no sha256 hash"
  done <<<"$lock_text"
  echo "manager lock parity case passed"
}

cli_case
tree_case
config_case
import_case
legacy_case
lock_parity_case
echo "all ComfyUI-Manager guard tests passed"
