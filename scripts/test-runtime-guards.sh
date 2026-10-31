#!/usr/bin/env bash
# Exercises the MSS-Login tmpfs shadow, duplicate detection, requirement
# filtering, and the custom-node install cache. No network and no ComfyUI install.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/entrypoint.sh"
export MSS_LOGIN_TEST_MODE=1

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" != "$want" ]]; then
    fail "${label}: got [${got}] want [${want}]"
  fi
}

make_plugin() {
  local dir="$1"
  mkdir -p "${dir}/utils"
  printf 'name = "MSS-Login"\n' >"${dir}/pyproject.toml"
  printf 'def create_mss_login_middleware():\n    return "ok"\n' >"${dir}/mss_login.py"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name test
  git -C "$dir" add pyproject.toml mss_login.py
  git -C "$dir" commit -q -m init
}

arm_tmpfs() {
  local dest="$1" fstype="${2:-tmpfs}"
  mkdir -p "$dest"
  MSS_MOUNTINFO="$(mktemp)"
  export MSS_MOUNTINFO
  dest="$(realpath -m "$dest")"
  printf '36 35 0:46 / %s rw,nosuid,nodev,noexec - %s %s rw,uid=0,gid=0\n' "$dest" "$fstype" "$fstype" >"$MSS_MOUNTINFO"
}

new_case() {
  local base
  base="$(mktemp -d)"
  printf '%s\n' "$base"
}

filter_case() {
  local src dest err
  src="$(mktemp)"
  dest="$(mktemp)"
  err="$(mktemp)"
  cat >"$src" <<'EOF'
numpy>=1.26
--extra-index-url https://evil.example/simple
-i https://evil.example/simple
--index-url https://download.pytorch.org/whl/cu130
--trusted-host evil.example
-f /tmp/wheels
--find-links /tmp/more
git+https://github.com/example/pkg.git
https://example.com/foo.whl
requests @ https://example.com/requests.whl
torch>=2.1
# comment
EOF
  filter_requirements_file "$src" "$dest" "DemoNode" false 2>"$err"
  grep -qx 'numpy>=1.26' "$dest" || fail "kept numpy"
  grep -qx 'torch>=2.1' "$dest" || fail "kept torch"
  if grep -E -q 'extra-index-url|trusted-host|find-links|git\+|example.com' "$dest"; then
    fail "filtered file still has a supply-chain line: $(cat "$dest")"
  fi
  grep -q 'Skipping requirement for node DemoNode: --extra-index-url' "$err" || fail "did not log extra-index-url"
  grep -q 'Skipping requirement for node DemoNode: -i ' "$err" || fail "did not log -i"
  grep -q 'Skipping requirement for node DemoNode: --trusted-host' "$err" || fail "did not log trusted-host"
  grep -q 'Skipping requirement for node DemoNode: git+https://github.com/example/pkg.git' "$err" || fail "did not log the skipped VCS line"
  if grep -q 'git+' "$dest"; then
    fail "URL requirements must be dropped even for MSS-Login"
  fi
  {
    printf '%s\n' \
      '-ihttp://127.0.0.1:9/evil-i' \
      '-fhttp://127.0.0.1:9/evil-f' \
      '-r/tmp/evilr.txt' \
      '-c /tmp/evilc.txt' \
      '--constraint /tmp/evilc.txt' \
      '-c/tmp/evilc.txt' \
      '-e /tmp/localpkg' \
      '/tmp/localpkg' \
      'localpkg @ file:///tmp/localpkg' \
      'six @ http://127.0.0.1:9/six.whl' \
      '--INDEX-URL http://127.0.0.1:9/evil-upper' \
      '--index-url=http://127.0.0.1:9/evil-eq' \
      '--no-index'
    printf '%s\n' $'--extra-\\\nindex-url http://127.0.0.1:9/evil-cont'
    printf '%s\n' $'\t--extra-index-url\thttp://127.0.0.1:9/evil-tab'
    printf '%s\r\n' '--index-url http://127.0.0.1:9/evil-crlf'
    printf '%s\n' 'six'
  } >"$src"
  filter_requirements_file "$src" "$dest" "Demo" false 2>"$err"
  assert_eq "$(grep -vx six "$dest" || true)" "" "adversarial lines must not be kept"
  grep -qx six "$dest" || fail "six was dropped"
  printf '%s\n' 'evil-1.0-py3-none-any.whl' 'Pkg-1.0.TAR.GZ' 'foo/bar' 'six' >"$src"
  filter_requirements_file "$src" "$dest" "Demo" false 2>"$err"
  assert_eq "$(grep -vx six "$dest" || true)" "" "wheel, sdist, and path tokens must be dropped"
  grep -qx six "$dest" || fail "six was dropped with the wheel"
  rm -f "$src" "$dest" "$err"
  echo "filter case passed"
}

cache_case() {
  local base nodes constraints bin log node allow venv
  base="$(new_case)"
  nodes="${base}/custom_nodes"
  constraints="${base}/torch.txt"
  allow="${base}/allow.txt"
  venv="${base}/venv"
  bin="${base}/bin"
  log="${base}/uv.log"
  node="${nodes}/ComfyUI-GGUF"
  mkdir -p "$node" "${nodes}/NotListed" "$bin" "$venv"
  printf 'numpy>=1.0\n' >"${node}/requirements.txt"
  printf 'numpy>=1.0\n' >"${nodes}/NotListed/requirements.txt"
  printf 'torch==2.9.0\n' >"$constraints"
  printf 'ComfyUI-GGUF\n' >"$allow"
  printf 'build-1\n' >"${venv}/.mss-build-id"
  cat >"${bin}/uv" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "${log}"
exit 0
EOF
  chmod +x "${bin}/uv"
  PATH="${bin}:${PATH}" \
    NODES_DIR="$nodes" \
    MSS_TORCH_CONSTRAINTS="$constraints" \
    MSS_NODE_DEPS_ALLOWLIST="$allow" \
    MSS_TEST_VENV_DIR="$venv" \
    MSS_LOGIN_RUNTIME_DIR="" \
    install_custom_node_deps
  assert_eq "$(wc -l <"$log" | tr -d ' ')" "1" "first install calls uv once"
  [[ -f "${venv}/.mss-node-dep-stamps/ComfyUI-GGUF" ]] || fail "stamp was not stored in the venv"
  [[ ! -e "${node}/.mss-dep-stamp" ]] || fail "stamp leaked onto the custom node"
  PATH="${bin}:${PATH}" \
    NODES_DIR="$nodes" \
    MSS_TORCH_CONSTRAINTS="$constraints" \
    MSS_NODE_DEPS_ALLOWLIST="$allow" \
    MSS_TEST_VENV_DIR="$venv" \
    MSS_LOGIN_RUNTIME_DIR="" \
    install_custom_node_deps
  assert_eq "$(wc -l <"$log" | tr -d ' ')" "1" "unchanged requirements skip uv"
  printf 'build-2\n' >"${venv}/.mss-build-id"
  PATH="${bin}:${PATH}" \
    NODES_DIR="$nodes" \
    MSS_TORCH_CONSTRAINTS="$constraints" \
    MSS_NODE_DEPS_ALLOWLIST="$allow" \
    MSS_TEST_VENV_DIR="$venv" \
    MSS_LOGIN_RUNTIME_DIR="" \
    install_custom_node_deps
  assert_eq "$(wc -l <"$log" | tr -d ' ')" "2" "new image build id reinstalls"
  rm -rf "$base"
  echo "cache case passed"
}

run_prepare() {
  local log status arg key value
  log="$(mktemp)"
  set +e
  (
    for arg in "$@"; do
      key="${arg%%=*}"
      value="${arg#*=}"
      export "${key}=${value}"
    done
    prepare_mss_login
  ) >"$log" 2>&1
  status=$?
  set -e
  printf '%s\n' "$status"
  cat "$log"
  rm -f "$log"
}

expect_refuse() {
  local label="$1"
  shift
  local out status
  out="$(run_prepare "$@")"
  status="${out%%$'\n'*}"
  [[ "$status" -ne 0 ]] || fail "${label} should refuse: ${out}"
  grep -q 'Refusing to start' <<<"$out" || fail "${label} missing Refusing: ${out}"
  printf '%s\n' "$out"
}

shadow_case() {
  local base seed nodes rev dest snapshot log out
  base="$(new_case)"
  seed="${base}/seed"
  nodes="${base}/custom_nodes"
  rev="${base}/REVISION"
  snapshot="${base}/host-snapshot"
  dest="${nodes}/MSS-Login"
  make_plugin "$seed"
  mkdir -p "${seed}/__pycache__"
  printf 'print("from-seed-pyc")\n' >"${seed}/__pycache__/mss_login.cpython-313.pyc"
  mkdir -p "${snapshot}/.venv/lib" "${snapshot}/__pycache__"
  printf 'host-only\n' >"${snapshot}/HOST_ONLY.txt"
  printf 'host-venv\n' >"${snapshot}/.venv/lib/marker.txt"
  printf 'print("pwned")\n' >"${snapshot}/__pycache__/mss_login.cpython-313.pyc"
  printf '%s\n' "$(git -C "$seed" rev-parse HEAD)" >"$rev"
  arm_tmpfs "$dest"
  MSS_LOGIN_SEED="$seed" \
    MSS_LOGIN_REVISION_FILE="$rev" \
    NODES_DIR="$nodes" \
    MSS_LOGIN_DIR="MSS-Login" \
    MSS_LOGIN_ALLOW_UNPINNED="false" \
    prepare_mss_login
  [[ -f "${dest}/pyproject.toml" ]] || fail "shadow was not seeded"
  [[ -f "${dest}/mss_login.py" ]] || fail "shadow is missing mss_login.py"
  [[ ! -e "${dest}/.git" ]] || fail "shadow copied .git"
  [[ ! -e "${dest}/__pycache__" ]] || fail "shadow copied bytecode"
  [[ ! -e "${dest}/.venv" ]] || fail "shadow copied .venv"
  [[ ! -e "${dest}/HOST_ONLY.txt" ]] || fail "host snapshot leaked into the shadow"
  assert_eq "$(cat "${snapshot}/HOST_ONLY.txt")" "host-only" "host snapshot was modified"
  assert_eq "${MSS_DIR}" "${dest}" "runtime dir is the shadow"
  python3 - <<PY
import os, sys
sys.path.insert(0, "${dest}")
import mss_login
assert mss_login.create_mss_login_middleware() == "ok"
assert not os.path.isdir(os.path.join("${dest}", "__pycache__"))
prefix = os.environ["PYTHONPYCACHEPREFIX"]
assert prefix == "/tmp/comfy-pycache"
found = []
for root, dirs, files in os.walk(prefix):
    for name in files:
        if name.startswith("mss_login"):
            found.append(os.path.join(root, name))
assert found, "import did not write bytecode under PYTHONPYCACHEPREFIX"
for path in found:
    assert path.startswith(prefix + os.sep)
    assert "${snapshot}" not in path
PY
  rm -rf "$base"
  unset MSS_MOUNTINFO
  echo "shadow case passed"
}

missing_mount_case() {
  local base seed nodes dest before
  base="$(new_case)"
  seed="${base}/seed"
  nodes="${base}/custom_nodes"
  dest="${nodes}/MSS-Login"
  make_plugin "$seed"
  mkdir -p "${dest}/.venv" "${dest}/__pycache__"
  printf 'leave-me\n' >"${dest}/HOST_ONLY.txt"
  printf 'pyc\n' >"${dest}/__pycache__/mss_login.cpython-313.pyc"
  before="$(sha256sum "${dest}/HOST_ONLY.txt")"
  unset MSS_MOUNTINFO
  expect_refuse "missing shadow mount" \
    MSS_LOGIN_SEED="$seed" \
    MSS_LOGIN_REVISION_FILE="${base}/REVISION" \
    NODES_DIR="$nodes" \
    MSS_LOGIN_DIR="MSS-Login" \
    MSS_LOGIN_ALLOW_UNPINNED="true" >/dev/null
  assert_eq "$(sha256sum "${dest}/HOST_ONLY.txt")" "$before" "missing mount modified the host file"
  [[ -f "${dest}/__pycache__/mss_login.cpython-313.pyc" ]] || fail "missing mount removed the host pyc"
  arm_tmpfs "$dest" "ext4"
  expect_refuse "non-tmpfs mount" \
    MSS_LOGIN_SEED="$seed" \
    NODES_DIR="$nodes" \
    MSS_LOGIN_DIR="MSS-Login" >/dev/null
  assert_eq "$(cat "${dest}/HOST_ONLY.txt")" "leave-me" "ext4 mount modified the host file"
  rm -rf "$base"
  unset MSS_MOUNTINFO
  echo "missing mount case passed"
}

nonempty_tmpfs_case() {
  local base seed nodes dest
  base="$(new_case)"
  seed="${base}/seed"
  nodes="${base}/custom_nodes"
  dest="${nodes}/MSS-Login"
  make_plugin "$seed"
  arm_tmpfs "$dest"
  printf 'already\n' >"${dest}/preexisting.txt"
  expect_refuse "non-empty tmpfs" \
    MSS_LOGIN_SEED="$seed" \
    NODES_DIR="$nodes" \
    MSS_LOGIN_DIR="MSS-Login" >/dev/null
  assert_eq "$(cat "${dest}/preexisting.txt")" "already" "non-empty tmpfs was overwritten"
  [[ ! -f "${dest}/pyproject.toml" ]] || fail "non-empty tmpfs was seeded"
  rm -rf "$base"
  unset MSS_MOUNTINFO
  echo "non-empty tmpfs case passed"
}

duplicate_case() {
  local base seed nodes dest log
  base="$(new_case)"
  seed="${base}/seed"
  nodes="${base}/custom_nodes"
  dest="${nodes}/MSS-Login"
  make_plugin "$seed"
  make_plugin "${nodes}/ComfyUI-MSS-Login"
  printf 'def create_mss_login_middleware():\n    return "py"\n' >"${nodes}/also_login.py"
  mkdir -p "${nodes}/.hidden-node"
  cp "${seed}/pyproject.toml" "${nodes}/.hidden-node/pyproject.toml"
  cp "${seed}/mss_login.py" "${nodes}/.hidden-node/mss_login.py"
  mkdir -p "${nodes}/SkipMe.disabled" "${nodes}/__pycache__" "${nodes}/Other.venv"
  cp "${seed}/pyproject.toml" "${nodes}/SkipMe.disabled/pyproject.toml"
  cp "${seed}/mss_login.py" "${nodes}/__pycache__/mss_login.py"
  printf 'not a node\n' >"${nodes}/readme.txt"
  printf 'print("pyc")\n' >"${nodes}/evil.pyc"
  mkdir -p "${nodes}/Pack/MSS-Login"
  cp "${seed}/pyproject.toml" "${nodes}/Pack/MSS-Login/pyproject.toml"
  printf 'plain\n' >"${nodes}/Pack/readme.txt"
  arm_tmpfs "$dest"
  log="$(expect_refuse "duplicate folder, py file, and hidden dir" \
    MSS_LOGIN_SEED="$seed" \
    NODES_DIR="$nodes" \
    MSS_LOGIN_DIR="MSS-Login")"
  grep -q 'would load twice' <<<"$log" || fail "duplicate message missing: ${log}"
  grep -q 'ComfyUI-MSS-Login' <<<"$log" || fail "did not list the renamed folder"
  grep -q 'also_login.py' <<<"$log" || fail "did not list the .py file"
  grep -q '.hidden-node' <<<"$log" || fail "hidden directory was skipped"
  if grep -F -q 'SkipMe.disabled' <<<"$log"; then
    fail "loader-skipped .disabled was treated as a duplicate"
  fi
  if grep -F -q '__pycache__' <<<"$log"; then
    fail "loader-skipped __pycache__ was treated as a duplicate"
  fi
  if grep -F -q 'evil.pyc' <<<"$log"; then
    fail "non-.py file was treated as a duplicate"
  fi
  if grep -F -q 'Pack/MSS-Login' <<<"$log"; then
    fail "nested package was treated as a top-level import"
  fi
  [[ ! -f "${dest}/pyproject.toml" ]] || fail "duplicate still seeded the shadow"
  rm -rf "$base"
  unset MSS_MOUNTINFO
  echo "duplicate case passed"
}

remote_and_hash_case() {
  local base seed nodes dest decoy log
  base="$(new_case)"
  seed="${base}/seed"
  nodes="${base}/custom_nodes"
  dest="${nodes}/MSS-Login"
  decoy="${nodes}/NotThePlugin"
  make_plugin "$seed"
  mkdir -p "$decoy"
  git -C "$decoy" init -q -b main
  git -C "$decoy" config user.email test@example.com
  git -C "$decoy" config user.name test
  printf 'readme\n' >"${decoy}/README.md"
  git -C "$decoy" add README.md
  git -C "$decoy" commit -q -m decoy
  git -C "$decoy" remote add origin https://github.com/Monster-Spawned-Studios/ComfyUI-MSS-Login.git
  arm_tmpfs "$dest"
  log="$(expect_refuse "git remote at the entry root" \
    MSS_LOGIN_SEED="$seed" \
    NODES_DIR="$nodes" \
    MSS_LOGIN_DIR="MSS-Login")"
  grep -q 'NotThePlugin' <<<"$log" || fail "remote-only entry was not listed"
  rm -rf "$decoy"
  mkdir -p "${nodes}/Altered"
  cp "${seed}/mss_login.py" "${nodes}/Altered/core.py"
  printf 'name = "Not-It"\n' >"${nodes}/Altered/pyproject.toml"
  log="$(expect_refuse "root file hash" \
    MSS_LOGIN_SEED="$seed" \
    NODES_DIR="$nodes" \
    MSS_LOGIN_DIR="MSS-Login")"
  grep -q 'Altered' <<<"$log" || fail "hashed root file was not listed: ${log}"
  rm -rf "$base"
  unset MSS_MOUNTINFO
  echo "remote and hash case passed"
}

break_glass_case() {
  local base seed nodes dest data log
  base="$(new_case)"
  seed="${base}/seed"
  nodes="${base}/custom_nodes"
  dest="${nodes}/MSS-Login"
  data="${base}/data"
  make_plugin "$seed"
  mkdir -p "$data"
  touch "${data}/MSS_LOGIN_BREAK_GLASS"
  unset MSS_MOUNTINFO
  log="$(expect_refuse "break-glass file without a shadow" \
    MSS_LOGIN_SEED="$seed" \
    NODES_DIR="$nodes" \
    MSS_LOGIN_DIR="MSS-Login" \
    MSS_LOGIN_DATA_DIR="$data" \
    MSS_LOGIN_ALLOW_UNPINNED="false")"
  if grep -q 'WARNING: MSS_LOGIN_ALLOW_UNPINNED=true' <<<"$log"; then
    fail "break-glass file produced the env warning"
  fi
  arm_tmpfs "$dest"
  MSS_LOGIN_SEED="$seed" \
    NODES_DIR="$nodes" \
    MSS_LOGIN_DIR="MSS-Login" \
    MSS_LOGIN_DATA_DIR="$data" \
    MSS_LOGIN_ALLOW_UNPINNED="true" \
    prepare_mss_login >"${base}/ok.log" 2>&1
  grep -q 'WARNING: MSS_LOGIN_ALLOW_UNPINNED=true is set' "${base}/ok.log" || fail "opt-out was not a loud warning: $(cat "${base}/ok.log")"
  grep -q 'does not skip the tmpfs' "${base}/ok.log" || fail "warning did not say the shadow still applies"
  [[ -f "${dest}/mss_login.py" ]] || fail "pinned shadow was not seeded"
  if grep -q 'host MSS-Login tree is not loaded' "${base}/ok.log"; then
    :
  else
    fail "warning did not say the host tree is not loaded"
  fi
  rm -rf "$base"
  unset MSS_MOUNTINFO
  [[ "${PYTHONPYCACHEPREFIX:-}" == "/tmp/comfy-pycache" ]] || fail "PYTHONPYCACHEPREFIX was not set by the entrypoint"
  echo "break-glass case passed"
}

auto_update_off_case() {
  local base cfg
  base="$(new_case)"
  cfg="${base}/config.json"
  printf '%s\n' '{"secret_key_env":"SECRET_KEY","auto_update":{"enabled":false,"mode":"auto","check_url":"https://example.invalid"}}' >"$cfg"
  MSS_LOGIN_AUTO_UPDATE=off MSS_LOGIN_DATA_DIR="$base" force_mss_login_auto_update_notify >/dev/null
  python3 - "$cfg" <<'PY'
import json
import sys

cfg = json.load(open(sys.argv[1], encoding="utf-8"))
if cfg.get("secret_key_env") != "SECRET_KEY":
    raise SystemExit("unrelated config key was dropped")
auto = cfg.get("auto_update") or {}
if auto.get("enabled") is not True or auto.get("mode") != "notify":
    raise SystemExit(f"auto_update was not forced to notify: {auto}")
if auto.get("check_url") != "https://example.invalid":
    raise SystemExit("check_url was dropped")
PY
  rm -f "$cfg"
  MSS_LOGIN_DATA_DIR="$base" force_mss_login_auto_update_notify >/dev/null
  python3 - "$cfg" <<'PY'
import json
import sys

auto = json.load(open(sys.argv[1], encoding="utf-8")).get("auto_update") or {}
if auto.get("enabled") is not True or auto.get("mode") != "notify":
    raise SystemExit(f"missing config was not created notify: {auto}")
PY
  rm -rf "$base"
  echo "auto-update notify case passed"
}

# shellcheck disable=SC2030,SC2031
security_regressions() {
  local base seed nodes dest yaml log status
  if grep -n 'chmod 1777' "${root}/entrypoint.sh" >/dev/null; then
    fail "pycache must not be mode 1777"
  fi
  mss_login_route_ok 200 || fail "200 should pass the login route check"
  mss_login_route_ok 302 || fail "302 should pass the login route check"
  if mss_login_route_ok 500; then
    fail "500 must not pass the login route check"
  fi
  (
    export MSS_LOGIN_TEST_MODE=0
    export MSS_LOGIN_DIR=Other
    export NODES_DIR=/tmp/nodes-fixed
    got="$(mss_login_shadow_dest)"
    [[ "$got" == "/tmp/nodes-fixed/MSS-Login" ]] || exit 1
  ) || fail "MSS_LOGIN_DIR was honored outside test mode"
  log="$(mktemp)"
  set +e
  (
    export CLI_ARGS="--listen 0.0.0.0 --base-directory /tmp/evil"
    refuse_cli_node_path_flags
  ) >"$log" 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "base-directory was allowed"
  grep -q -- '--base-directory' "$log" || fail "refusal did not name the flag: $(cat "$log")"
  set +e
  (
    export CLI_ARGS="--listen 0.0.0.0 --whitelist-custom-nodes MSS-Login"
    refuse_cli_node_path_flags
  ) >"$log" 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "whitelist-custom-nodes was allowed"
  yaml="$(mktemp)"
  printf '%s\n' 'comfyui:' '  checkpoints: models/checkpoints' >"$yaml"
  MSS_EXTRA_MODEL_PATHS="$yaml" refuse_extra_model_paths_custom_nodes
  printf '%s\n' 'comfyui:' '  custom_nodes: /tmp/other-nodes' >>"$yaml"
  set +e
  (
    export MSS_EXTRA_MODEL_PATHS="$yaml"
    refuse_extra_model_paths_custom_nodes
  ) >"$log" 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "custom_nodes key was allowed"
  printf '%s\n' 'not: [valid: yaml' >"$yaml"
  set +e
  (
    export MSS_EXTRA_MODEL_PATHS="$yaml"
    refuse_extra_model_paths_custom_nodes
  ) >"$log" 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "unparseable extra_model_paths was allowed"
  base="$(new_case)"
  seed="${base}/seed"
  nodes="${base}/custom_nodes"
  dest="${nodes}/MSS-Login"
  make_plugin "$seed"
  mkdir -p "${seed}/utils"
  ln -s pyproject.toml "${seed}/utils/link.toml"
  mkfifo "${seed}/utils/pipe"
  arm_tmpfs "$dest"
  MSS_LOGIN_SEED="$seed" NODES_DIR="$nodes" MSS_LOGIN_DIR="MSS-Login" prepare_mss_login >/dev/null
  [[ -L "${dest}/utils/link.toml" ]] || fail "symlink was not copied onto the shadow"
  [[ -p "${dest}/utils/pipe" ]] || fail "fifo was not copied onto the shadow"
  mkfifo "${dest}/extra.pipe"
  set +e
  (
    export MSS_LOGIN_SEED="$seed"
    export NODES_DIR="$nodes"
    export MSS_LOGIN_DIR="MSS-Login"
    prepare_mss_login
  ) >"$log" 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "extra fifo was accepted: $(cat "$log")"
  grep -q 'non-directory list' "$log" || fail "extra fifo message missing: $(cat "$log")"
  d="$(mktemp -d)"
  (
    unset PYTHONPYCACHEPREFIX
    python3 - "$d" <<'PY'
import py_compile
import sys
from pathlib import Path
src = Path(sys.argv[1]) / "hashmod.py"
src.write_text("VALUE = 1\n", encoding="utf-8")
py_compile.compile(str(src), invalidation_mode=py_compile.PycInvalidationMode.UNCHECKED_HASH, doraise=True)
src.write_text("VALUE = 2\n", encoding="utf-8")
PY
    python3 -c "import sys; sys.path.insert(0, '${d}'); import hashmod; print(hashmod.VALUE)" >"$log"
    got="$(tr -d '[:space:]' <"$log")"
    [[ "$got" == "1" ]] || exit 2
    comfy_python -c "import sys; sys.path.insert(0, '${d}'); import hashmod; print(hashmod.VALUE)" >"$log"
    got="$(tr -d '[:space:]' <"$log")"
    [[ "$got" == "2" ]] || exit 3
  ) || fail "hash-based pyc check did not prefer the source (see ${log})"
  rm -rf "$base" "$d"
  rm -f "$log" "$yaml"
  unset MSS_MOUNTINFO MSS_EXTRA_MODEL_PATHS
  echo "security regressions passed"
}

filter_case
cache_case
shadow_case
missing_mount_case
nonempty_tmpfs_case
duplicate_case
remote_and_hash_case
break_glass_case
auto_update_off_case
security_regressions
echo "all runtime guard tests passed"
