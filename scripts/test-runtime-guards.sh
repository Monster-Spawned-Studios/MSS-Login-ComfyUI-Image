#!/usr/bin/env bash
# Exercises MSS-Login detection, the pin check, requirement filtering, and the
# custom-node install cache. No network and no ComfyUI install.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/entrypoint.sh"

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
  grep -q 'ignoring requirement option: --extra-index-url' "$err" || fail "did not log extra-index-url"
  grep -q 'ignoring requirement option: -i ' "$err" || fail "did not log -i"
  grep -q 'ignoring requirement option: --trusted-host' "$err" || fail "did not log trusted-host"
  grep -q 'ignoring URL or git requirement: git+https://' "$err" || fail "did not log git+"
  filter_requirements_file "$src" "$dest" "MSS-Login" true 2>"$err"
  grep -qx 'git+https://github.com/example/pkg.git' "$dest" || fail "pinned MSS-Login should keep git+ lines"
  rm -f "$src" "$dest" "$err"
  echo "filter case passed"
}

cache_case() {
  local base nodes constraints bin log node
  base="$(new_case)"
  nodes="${base}/custom_nodes"
  constraints="${base}/torch.txt"
  bin="${base}/bin"
  log="${base}/uv.log"
  node="${nodes}/SomeNode"
  mkdir -p "$node" "$bin"
  printf 'numpy>=1.0\n' >"${node}/requirements.txt"
  printf 'torch==2.9.0\n' >"$constraints"
  cat >"${bin}/uv" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "${log}"
exit 0
EOF
  chmod +x "${bin}/uv"
  PATH="${bin}:${PATH}" \
    NODES_DIR="$nodes" \
    MSS_TORCH_CONSTRAINTS="$constraints" \
    MSS_LOGIN_RUNTIME_DIR="" \
    install_custom_node_deps
  assert_eq "$(wc -l <"$log" | tr -d ' ')" "1" "first install calls uv once"
  PATH="${bin}:${PATH}" \
    NODES_DIR="$nodes" \
    MSS_TORCH_CONSTRAINTS="$constraints" \
    MSS_LOGIN_RUNTIME_DIR="" \
    install_custom_node_deps
  assert_eq "$(wc -l <"$log" | tr -d ' ')" "1" "unchanged requirements skip uv"
  printf 'numpy>=2.0\n' >"${node}/requirements.txt"
  PATH="${bin}:${PATH}" \
    NODES_DIR="$nodes" \
    MSS_TORCH_CONSTRAINTS="$constraints" \
    MSS_LOGIN_RUNTIME_DIR="" \
    install_custom_node_deps
  assert_eq "$(wc -l <"$log" | tr -d ' ')" "2" "changed requirements install again"
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
  local base seed nodes rev sha decoy
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
  sha="$(git -C "$seed" rev-parse HEAD)"
  printf '%s\n' "$sha" >"$rev"
  MSS_LOGIN_SEED="$seed" \
    MSS_LOGIN_REVISION_FILE="$rev" \
    NODES_DIR="$nodes" \
    MSS_LOGIN_DIR="MSS-Login" \
    MSS_LOGIN_ALLOW_UNPINNED="false" \
    prepare_mss_login
  [[ -f "${nodes}/MSS-Login/mss_login.py" ]] || fail "remote-only directory suppressed seeding"
  [[ -f "${decoy}/README.md" ]] || fail "remote-only directory was overwritten"
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
echo "all runtime guard tests passed"
