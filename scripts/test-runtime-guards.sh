#!/usr/bin/env bash
# Exercises MSS-Login detection, the pin check, requirement filtering, and the
# custom-node install cache. No network and no ComfyUI install.
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
  printf 'app.middlewares.append(access_control.create_mss_login_middleware())\n' >"${dir}/mss_login.py"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name test
  git -C "$dir" add pyproject.toml mss_login.py
  git -C "$dir" commit -q -m init
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
  grep -q 'ignoring requirement line: --extra-index-url' "$err" || fail "did not log extra-index-url"
  grep -q 'ignoring requirement line: -i ' "$err" || fail "did not log -i"
  grep -q 'ignoring requirement line: --trusted-host' "$err" || fail "did not log trusted-host"
  grep -q 'ignoring requirement line: git+https://' "$err" || fail "did not log git+"
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

seed_case() {
  local base seed nodes rev sha
  base="$(new_case)"
  seed="${base}/seed"
  nodes="${base}/custom_nodes"
  rev="${base}/REVISION"
  mkdir -p "$nodes"
  make_plugin "$seed"
  sha="$(git -C "$seed" rev-parse HEAD)"
  printf '%s\n' "$sha" >"$rev"
  MSS_LOGIN_SEED="$seed" \
    MSS_LOGIN_REVISION_FILE="$rev" \
    NODES_DIR="$nodes" \
    MSS_LOGIN_DIR="MSS-Login" \
    MSS_LOGIN_ALLOW_UNPINNED="false" \
    prepare_mss_login
  [[ -f "${nodes}/MSS-Login/pyproject.toml" ]] || fail "seed did not create MSS-Login"
  [[ -d "${nodes}/MSS-Login/.git" ]] || fail "seed did not copy the git checkout"
  assert_eq "${MSS_DIR}" "${nodes}/MSS-Login" "seeded runtime dir"
  rm -rf "$base"
  echo "seed case passed"
}

different_folder_case() {
  local base seed nodes rev sha
  base="$(new_case)"
  seed="${base}/seed"
  nodes="${base}/custom_nodes"
  rev="${base}/REVISION"
  mkdir -p "$nodes"
  make_plugin "$seed"
  make_plugin "${nodes}/LegacyFolder"
  sha="$(git -C "${nodes}/LegacyFolder" rev-parse HEAD)"
  printf '%s\n' "$sha" >"$rev"
  local log
  log="$(mktemp)"
  MSS_LOGIN_SEED="$seed" \
    MSS_LOGIN_REVISION_FILE="$rev" \
    NODES_DIR="$nodes" \
    MSS_LOGIN_DIR="MSS-Login" \
    MSS_LOGIN_ALLOW_UNPINNED="false" \
    prepare_mss_login >"$log"
  [[ ! -e "${nodes}/MSS-Login" ]] || fail "seeded a second copy beside LegacyFolder"
  assert_eq "${MSS_DIR}" "${nodes}/LegacyFolder" "runtime dir follows the existing package"
  grep -q 'LegacyFolder' "$log" || fail "did not log the folder that is used"
  rm -f "$log"
  rm -rf "$base"
  echo "different folder case passed"
}

remote_only_case() {
  local base seed nodes rev decoy status log
  base="$(new_case)"
  seed="${base}/seed"
  nodes="${base}/custom_nodes"
  rev="${base}/REVISION"
  decoy="${nodes}/NotThePlugin"
  mkdir -p "$nodes" "$decoy"
  git -C "$decoy" init -q -b main
  git -C "$decoy" config user.email test@example.com
  git -C "$decoy" config user.name test
  printf 'readme\n' >"${decoy}/README.md"
  git -C "$decoy" add README.md
  git -C "$decoy" commit -q -m decoy
  git -C "$decoy" remote add origin https://github.com/Monster-Spawned-Studios/ComfyUI-MSS-Login.git
  make_plugin "$seed"
  printf '%s\n' "$(git -C "$seed" rev-parse HEAD)" >"$rev"
  log="$(mktemp)"
  set +e
  (
    MSS_LOGIN_SEED="$seed" \
      MSS_LOGIN_REVISION_FILE="$rev" \
      NODES_DIR="$nodes" \
      MSS_LOGIN_DIR="MSS-Login" \
      prepare_mss_login
  ) >"$log" 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "git remote alone was allowed to sit beside a seeded copy"
  [[ ! -e "${nodes}/MSS-Login" ]] || fail "seeded a second copy beside a remote match"
  grep -q 'Refusing' "$log" || fail "remote-only refusal missing"
  rm -f "$log"
  rm -rf "$base"
  echo "remote-only case passed"
}

two_copies_case() {
  local base nodes status log
  base="$(new_case)"
  nodes="${base}/custom_nodes"
  mkdir -p "$nodes"
  make_plugin "${nodes}/MSS-Login"
  make_plugin "${nodes}/ComfyUI-MSS-Login"
  log="$(mktemp)"
  set +e
  (
    NODES_DIR="$nodes" MSS_LOGIN_DIR="MSS-Login" prepare_mss_login
  ) >"$log" 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "two copies were allowed to start"
  grep -q 'would load twice' "$log" || fail "two-copy message missing: $(cat "$log")"
  grep -q 'MSS-Login' "$log" || fail "did not list MSS-Login"
  grep -q 'ComfyUI-MSS-Login' "$log" || fail "did not list ComfyUI-MSS-Login"
  rm -f "$log"
  rm -rf "$base"
  echo "two copies case passed"
}

attack_cases() {
  local base seed nodes rev sha status log
  base="$(new_case)"
  seed="${base}/seed"
  nodes="${base}/custom_nodes"
  rev="${base}/REVISION"
  mkdir -p "$nodes"
  make_plugin "$seed"
  sha="$(git -C "$seed" rev-parse HEAD)"
  printf '%s\n' "$sha" >"$rev"

  run_prepare() {
    local label="$1"
    shift
    log="$(mktemp)"
    set +e
    (
      MSS_LOGIN_SEED="$seed" MSS_LOGIN_REVISION_FILE="$rev" NODES_DIR="$nodes" MSS_LOGIN_DIR="MSS-Login" prepare_mss_login
    ) >"$log" 2>&1
    status=$?
    set -e
    if [[ "$1" == "ok" ]]; then
      [[ "$status" -eq 0 ]] || fail "${label} should start: $(cat "$log")"
    else
      [[ "$status" -ne 0 ]] || fail "${label} should refuse: $(cat "$log")"
      grep -q 'Refusing' "$log" || fail "${label} missing Refusing: $(cat "$log")"
    fi
    rm -f "$log"
  }

  rm -rf "$nodes"
  mkdir -p "$nodes"
  cp -a "$seed" "${nodes}/MSS-Login"
  run_prepare "clean copy" ok

  echo 'print("backdoor")' >>"${nodes}/MSS-Login/mss_login.py"
  run_prepare "dirty file" bad
  git -C "${nodes}/MSS-Login" checkout -q -- mss_login.py

  echo 'x=1' >"${nodes}/MSS-Login/extra_evil.py"
  run_prepare "untracked file" bad
  rm -f "${nodes}/MSS-Login/extra_evil.py"

  rm -rf "${nodes}/MSS-Login/.git"
  git -C "${nodes}/MSS-Login" init -q
  printf '%s\n' "$sha" >"${nodes}/MSS-Login/.git/HEAD"
  run_prepare "forged HEAD" bad

  rm -rf "$nodes"
  mkdir -p "$nodes"
  cp -a "$seed" "${nodes}/Altered"
  sed -i 's/^name = "MSS-Login"/name = "Not-It"/' "${nodes}/Altered/pyproject.toml"
  mv "${nodes}/Altered/mss_login.py" "${nodes}/Altered/core.py"
  run_prepare "renamed entry module" bad
  [[ ! -e "${nodes}/MSS-Login" ]] || fail "altered copy caused a second seed"

  rm -rf "$base"
  echo "attack cases passed"
}

mismatch_case() {
  local base nodes rev status log sha
  base="$(new_case)"
  nodes="${base}/custom_nodes"
  rev="${base}/REVISION"
  mkdir -p "$nodes"
  make_plugin "${nodes}/MSS-Login"
  sha="$(git -C "${nodes}/MSS-Login" rev-parse HEAD)"
  printf '%s\n' "0123456789abcdef0123456789abcdef01234567" >"$rev"
  log="$(mktemp)"
  set +e
  (
    MSS_LOGIN_REVISION_FILE="$rev" \
      NODES_DIR="$nodes" \
      MSS_LOGIN_DIR="MSS-Login" \
      MSS_LOGIN_ALLOW_UNPINNED="false" \
      prepare_mss_login
  ) >"$log" 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "mismatched HEAD was allowed"
  grep -q '0123456789abcdef0123456789abcdef01234567' "$log" || fail "did not log image revision"
  grep -q "$sha" "$log" || fail "did not log checkout HEAD"
  grep -q 'was not modified' "$log" || fail "did not say the checkout was left alone"
  rm -f "$log"
  echo "mismatch case passed"

  log="$(mktemp)"
  set +e
  (
    MSS_LOGIN_REVISION_FILE="$rev" \
      NODES_DIR="$nodes" \
      MSS_LOGIN_DIR="MSS-Login" \
      MSS_LOGIN_ALLOW_UNPINNED="true" \
      prepare_mss_login
  ) >"$log" 2>&1
  status=$?
  set -e
  [[ "$status" -eq 0 ]] || fail "ALLOW_UNPINNED should continue (status ${status}): $(cat "$log")"
  grep -q 'WARNING: MSS_LOGIN_ALLOW_UNPINNED' "$log" || fail "opt-out was not a loud warning"
  rm -f "$log"
  rm -rf "$base"
  echo "unpinned opt-out case passed"
}

filter_case
cache_case
seed_case
different_folder_case
remote_only_case
two_copies_case
mismatch_case
attack_cases
echo "all runtime guard tests passed"
