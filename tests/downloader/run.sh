#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Test harness for scripts/mss-download-models.sh
# Tests rejection cases, genuine happy-path, token auth,
# and regressions for Nits 1-8 using a local HTTPS test server
# and a throwaway self-signed CA certificate.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOWNLOADER="${REPO_ROOT}/scripts/mss-download-models.sh"

TEST_DIR="$(mktemp -d "/tmp/mss-dl-test.XXXXXX")"
CA_KEY="${TEST_DIR}/ca.key"
CA_CERT="${TEST_DIR}/ca.crt"
SRV_KEY="${TEST_DIR}/server.key"
SRV_CERT="${TEST_DIR}/server.crt"
SRV_CONF="${TEST_DIR}/server.cnf"

# shellcheck disable=SC2329
cleanup() {
    if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT INT TERM

echo "[Test Harness] Setting up throwaway CA and certificates in $TEST_DIR..."

# Generate CA
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$CA_KEY" -out "$CA_CERT" -days 1 -subj "/CN=MSS-Test-CA" 2>/dev/null

# Generate Server Key & Cert with SAN for 127.0.0.1
cat > "$SRV_CONF" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = 127.0.0.1
[v3_req]
subjectAltName = @alt_names
[alt_names]
IP.1 = 127.0.0.1
DNS.1 = localhost
EOF

openssl req -newkey rsa:2048 -nodes -keyout "$SRV_KEY" -out "${TEST_DIR}/server.csr" -config "$SRV_CONF" 2>/dev/null
openssl x509 -req -in "${TEST_DIR}/server.csr" -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial -out "$SRV_CERT" -days 1 -extfile "$SRV_CONF" -extensions v3_req 2>/dev/null

# Start Python HTTP + HTTPS mock server
PORT_FILE="${TEST_DIR}/ports.txt"

python3 - <<PY &
import http.server, ssl, socket, sys, time, threading

data_good = b"TEST-MODEL-DATA-VALID-CONTENT" * 64
data_pickle = b"TEST-PICKLE-DATA-UNSAFE" * 32
data_oversized = b"A" * (2 * 1024 * 1024) # 2 MB

CANARY_HF = "CANARY_HF_TOKEN_VAL_12345"
CANARY_CV = "CANARY_CV_TOKEN_VAL_67890"
CANARY_ENV = "CANARY_ENV_TOKEN_VAL_99999"

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass # suppress access log

    def do_HEAD(self):
        self.do_GET(head_only=True)

    def do_GET(self, head_only=False):
        path = self.path.split("?")[0]
        auth_hdr = self.headers.get("Authorization", "")
        range_hdr = self.headers.get("Range", "")
        try:
            if path in ["/good.safetensors", "/unicode_test.safetensors"]:
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(data_good)))
                self.end_headers()
                if not head_only:
                    self.wfile.write(data_good)

            elif path in ["/pickle.ckpt", "/pickle.pkl", "/pickle.pickle", "/pickle.joblib"]:
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(data_pickle)))
                self.end_headers()
                if not head_only:
                    self.wfile.write(data_pickle)

            elif path == "/hf_authed.safetensors":
                if auth_hdr in [f"Bearer {CANARY_HF}", f"Bearer {CANARY_ENV}"]:
                    self.send_response(200)
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Content-Length", str(len(data_good)))
                    self.end_headers()
                    if not head_only:
                        self.wfile.write(data_good)
                else:
                    self.send_response(401)
                    self.end_headers()

            elif path == "/cv_authed.safetensors":
                if auth_hdr == f"Bearer {CANARY_CV}":
                    self.send_response(200)
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Content-Length", str(len(data_good)))
                    self.end_headers()
                    if not head_only:
                        self.wfile.write(data_good)
                else:
                    self.send_response(401)
                    self.end_headers()

            elif path == "/range_test.safetensors":
                # Nit 7: if Range request received, return 416 to trigger curl exit 33
                if range_hdr:
                    self.send_response(416)
                    self.end_headers()
                else:
                    self.send_response(200)
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Content-Length", str(len(data_good)))
                    self.end_headers()
                    if not head_only:
                        self.wfile.write(data_good)

            elif path == "/oversized.safetensors":
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(data_oversized)))
                self.end_headers()
                if not head_only:
                    self.wfile.write(data_oversized)

            elif path == "/slow.safetensors":
                time.sleep(3)
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(data_good)))
                self.end_headers()
                if not head_only:
                    self.wfile.write(data_good)

            elif path == "/redirect_to_http":
                self.send_response(302)
                self.send_header("Location", f"http://127.0.0.1:{http_port}/good.safetensors")
                self.end_headers()

            elif path == "/api/v1/model-versions/99999":
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                if not head_only:
                    self.wfile.write(b'{"files": [{"name": "evil/slash.safetensors", "hashes": {"SHA256": "1111111111111111111111111111111111111111111111111111111111111111"}}]}')
            else:
                self.send_response(404)
                self.end_headers()
        except (BrokenPipeError, ConnectionResetError):
            pass

# Find 2 free ports
s1 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s1.bind(('127.0.0.1', 0))
https_port = s1.getsockname()[1]
s1.close()

s2 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s2.bind(('127.0.0.1', 0))
http_port = s2.getsockname()[1]
s2.close()

with open("${PORT_FILE}", "w") as pf:
    pf.write(f"{https_port} {http_port}\n")

# HTTP server thread
httpd = http.server.ThreadingHTTPServer(('127.0.0.1', http_port), Handler)
t = threading.Thread(target=httpd.serve_forever, daemon=True)
t.start()

# HTTPS server
httpsd = http.server.ThreadingHTTPServer(('127.0.0.1', https_port), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(certfile="${SRV_CERT}", keyfile="${SRV_KEY}")
httpsd.socket = ctx.wrap_socket(httpsd.socket, server_side=True)
httpsd.serve_forever()
PY
SERVER_PID=$!

# Wait for server ports
for _ in {1..50}; do
    if [ -f "$PORT_FILE" ]; then break; fi
    sleep 0.1
done

if [ ! -f "$PORT_FILE" ]; then
    echo "FAIL: Mock server failed to initialize ports" >&2
    exit 1
fi

read -r HTTPS_PORT HTTP_PORT < "$PORT_FILE"
echo "[Test Harness] Mock servers running (HTTPS: $HTTPS_PORT, HTTP: $HTTP_PORT)"

export CURL_CA_BUNDLE="$CA_CERT"

# Assert fixture/server readiness so unreachable servers cannot produce false passes
echo -n "[Test Harness] Probing mock server readiness ... "
if ! curl -sS -I "https://127.0.0.1:${HTTPS_PORT}/good.safetensors" | grep -q "200 OK"; then
    echo "FAIL (mock HTTPS server not responding with 200 OK)" >&2
    exit 1
fi
echo "READY"

# Compute actual sha256 of good and pickle test payloads
GOOD_SHA="$(python3 -c "import hashlib; print(hashlib.sha256(b'TEST-MODEL-DATA-VALID-CONTENT' * 64).hexdigest())")"
PICKLE_SHA="$(python3 -c "import hashlib; print(hashlib.sha256(b'TEST-PICKLE-DATA-UNSAFE' * 32).hexdigest())")"
OVERSIZED_SHA="$(python3 -c "import hashlib; print(hashlib.sha256(b'A' * (2 * 1024 * 1024)).hexdigest())")"

run_case() {
    local name="$1"
    local entry="$2"
    local extra_env="${3:-}"
    local case_dir="${TEST_DIR}/case_${name}"
    mkdir -p "${case_dir}/models"

    local log
    log="$(
        # shellcheck disable=SC2086
        eval $extra_env MODELS_DIR="${case_dir}/models" \
            MODELS_TO_DOWNLOAD="'$entry'" \
            /bin/bash "$DOWNLOADER" 2>&1
    )" || {
        echo "FAIL [$name]: downloader exited non-zero" >&2
        echo "$log" >&2
        return 1
    }
    printf '%s' "$log"
}

PASSED=0
FAILED=0

assert_rejection() {
    local test_name="$1"
    local entry="$2"
    local expected_pattern="$3"
    local extra_env="${4:-}"

    echo -n "Running test case: $test_name ... "
    local log
    log="$(run_case "$test_name" "$entry" "$extra_env")"

    if grep -qE "$expected_pattern" <<<"$log"; then
        echo "PASS"
        PASSED=$((PASSED + 1))
    else
        echo "FAIL"
        echo "  Expected pattern: $expected_pattern"
        echo "  Output:"
        printf '    %s\n' "$log"
        FAILED=$((FAILED + 1))
    fi
}

# 1. Plain HTTP URL
assert_rejection "01_http_url" \
    "checkpoint:http://127.0.0.1:${HTTP_PORT}/good.safetensors $GOOD_SHA" \
    "Refusing non-HTTPS URL"

# 2. HTTPS to HTTP redirect (Nit 8: specific protocol rejection, not generic 'Failed to download')
assert_rejection "02_https_to_http_redirect" \
    "checkpoint:https://127.0.0.1:${HTTPS_PORT}/redirect_to_http $GOOD_SHA" \
    "Protocol.*disabled in libcurl"

# 3. Unpinned entry
assert_rejection "03_unpinned_entry" \
    "checkpoint:https://127.0.0.1:${HTTPS_PORT}/good.safetensors" \
    "Refusing unpinned entry"

# 4. Pickle files from non-allowed host (Nit 5: .ckpt, .pkl, .pickle, .joblib)
assert_rejection "04a_pickle_disallowed_ckpt" \
    "checkpoint:https://127.0.0.1:${HTTPS_PORT}/pickle.ckpt $PICKLE_SHA" \
    "Refusing pickle file from disallowed.*host: 127.0.0.1"

assert_rejection "04b_pickle_disallowed_pkl" \
    "checkpoint:https://127.0.0.1:${HTTPS_PORT}/pickle.pkl $PICKLE_SHA" \
    "Refusing pickle file from disallowed.*host: 127.0.0.1"

assert_rejection "04c_pickle_disallowed_pickle" \
    "checkpoint:https://127.0.0.1:${HTTPS_PORT}/pickle.pickle $PICKLE_SHA" \
    "Refusing pickle file from disallowed.*host: 127.0.0.1"

assert_rejection "04d_pickle_disallowed_joblib" \
    "checkpoint:https://127.0.0.1:${HTTPS_PORT}/pickle.joblib $PICKLE_SHA" \
    "Refusing pickle file from disallowed.*host: 127.0.0.1"

# 5. Name or URL starting with '-'
assert_rejection "05a_url_starting_with_dash" \
    "-https://127.0.0.1:${HTTPS_PORT}/good.safetensors $GOOD_SHA" \
    "Refusing (entry|URL) starting with '-'"

assert_rejection "05b_name_starting_with_dash" \
    "checkpoint:https://127.0.0.1:${HTTPS_PORT}/-badname.safetensors $GOOD_SHA" \
    "Refusing unsafe file name: -badname.safetensors"

# 6. Control characters and Unicode Bidi override (Nit 6)
assert_rejection "06a_control_characters" \
    "checkpoint:https://127.0.0.1:${HTTPS_PORT}/bad"$'\x01'"name.safetensors $GOOD_SHA" \
    "Refusing unsafe file name"

# Nit 6: Reject U+202E (Right-to-Left Override)
assert_rejection "06b_unicode_bidi_override" \
    "checkpoint:https://127.0.0.1:${HTTPS_PORT}/bad"$'\xe2\x80\xae'"name.safetensors $GOOD_SHA" \
    "Refusing unsafe file name"

# Nit 6: Preserve legitimate ordinary Unicode names (must not be rejected by name filter)
echo -n "Running test case: 06c_unicode_legitimate_name ... "
case06c_dir="${TEST_DIR}/case_06c_unicode"
mkdir -p "${case06c_dir}/models"
log06c="$(MODELS_DIR="${case06c_dir}/models" MODELS_TO_DOWNLOAD="checkpoint:https://127.0.0.1:${HTTPS_PORT}/unicode_test.safetensors $GOOD_SHA" /bin/bash "$DOWNLOADER" 2>&1 || true)"
if ! grep -q "Refusing unsafe file name" <<<"$log06c" && grep -q "Saved unicode_test.safetensors" <<<"$log06c"; then
    echo "PASS"
    PASSED=$((PASSED + 1))
else
    echo "FAIL (ordinary valid name rejected or failed)"
    FAILED=$((FAILED + 1))
fi

# 7. Slashes '/' in filename
assert_rejection "07_slash_in_name" \
    "checkpoint:https://127.0.0.1:${HTTPS_PORT}/bad%2fslash.safetensors $GOOD_SHA" \
    "Refusing unsafe file name"

# 8. Backslash '\' in filename
assert_rejection "08_backslash_in_name" \
    'checkpoint:https://127.0.0.1:'"${HTTPS_PORT}"'/bad\name.safetensors '"$GOOD_SHA" \
    "Refusing unsafe file name"

# 9. '..' traversal in filename
assert_rejection "09_dot_dot_traversal" \
    "checkpoint:https://127.0.0.1:${HTTPS_PORT}/.. $GOOD_SHA" \
    "Refusing unsafe file name: \.\."

# 10. Collision handling
echo -n "Running test case: 10a_disk_collision ... "
case10_dir="${TEST_DIR}/case_10_disk"
mkdir -p "${case10_dir}/models/checkpoints"
printf "EXISTING-CORRUPT-CONTENT" > "${case10_dir}/models/checkpoints/good.safetensors"
log10a="$(MODELS_DIR="${case10_dir}/models" MODELS_TO_DOWNLOAD="checkpoint:https://127.0.0.1:${HTTPS_PORT}/good.safetensors $GOOD_SHA" /bin/bash "$DOWNLOADER" 2>&1 || true)"
if grep -q "Refusing name collision: good.safetensors already exists with a different hash" <<<"$log10a" && \
   grep -q "EXISTING-CORRUPT-CONTENT" "${case10_dir}/models/checkpoints/good.safetensors"; then
    echo "PASS"
    PASSED=$((PASSED + 1))
else
    echo "FAIL (disk collision not rejected or file overwritten)"
    FAILED=$((FAILED + 1))
fi

assert_rejection "10b_manifest_duplicate" \
    "checkpoint:https://127.0.0.1:${HTTPS_PORT}/good.safetensors $GOOD_SHA,checkpoint:https://127.0.0.1:${HTTPS_PORT}/good.safetensors 0000000000000000000000000000000000000000000000000000000000000000" \
    "Refusing (name collision in manifest|duplicate manifest entry)"

# 11. Hash mismatch and .part deletion
echo -n "Running test case: 11_part_hash_mismatch ... "
case11_dir="${TEST_DIR}/case_11_part"
mkdir -p "${case11_dir}/models/checkpoints"
log11="$(MODELS_DIR="${case11_dir}/models" MODELS_TO_DOWNLOAD="checkpoint:https://127.0.0.1:${HTTPS_PORT}/good.safetensors 0000000000000000000000000000000000000000000000000000000000000000" /bin/bash "$DOWNLOADER" 2>&1 || true)"
if grep -q "Checksum mismatch after download.*deleting partial file" <<<"$log11" && \
   [ ! -f "${case11_dir}/models/checkpoints/good.safetensors.part" ] && \
   [ ! -f "${case11_dir}/models/checkpoints/good.safetensors" ]; then
    echo "PASS"
    PASSED=$((PASSED + 1))
else
    echo "FAIL (.part not deleted or bad destination created)"
    FAILED=$((FAILED + 1))
fi

# 12. Oversized file limit (Nit 8: specific reason, not generic 'Failed to download')
assert_rejection "12_oversized_file" \
    "checkpoint:https://127.0.0.1:${HTTPS_PORT}/oversized.safetensors $OVERSIZED_SHA" \
    "Maximum file size exceeded" \
    "MODELS_MAX_FILESIZE=500K"

# 13. Low disk space
assert_rejection "13_low_disk_space" \
    "checkpoint:https://127.0.0.1:${HTTPS_PORT}/good.safetensors $GOOD_SHA" \
    "Insufficient disk space in" \
    "MODELS_DISK_HEADROOM_KB=9999999999"

# 14. Network timeout (Nit 8: specific timeout reason, not generic 'Failed to download')
assert_rejection "14_network_timeout" \
    "checkpoint:https://127.0.0.1:${HTTPS_PORT}/slow.safetensors $GOOD_SHA" \
    "(Operation timed out|timed out|Maximum time exceeded)" \
    "MODELS_CONNECT_TIMEOUT=1 MODELS_MAX_TIME=2"

# 15. Tokenized URL credential redaction in logs (Nit 3)
echo -n "Running test case: 15_token_redaction_in_logs ... "
case15_dir="${TEST_DIR}/case_15_logs"
mkdir -p "${case15_dir}/models/checkpoints"
log15="$(MODELS_DIR="${case15_dir}/models" MODELS_TO_DOWNLOAD="checkpoint:https://127.0.0.1:${HTTPS_PORT}/good.safetensors?token=SECRET_TOKEN_XYZ_12345&secret=PASS999 $GOOD_SHA" /bin/bash "$DOWNLOADER" 2>&1 || true)"

if ! grep -q "SECRET_TOKEN_XYZ_12345" <<<"$log15" && \
   ! grep -q "PASS999" <<<"$log15" && \
   ! grep -Fq "?token=" <<<"$log15"; then
    echo "PASS"
    PASSED=$((PASSED + 1))
else
    echo "FAIL (credentials or query parameters leaked into logs)"
    printf '    %s\n' "$log15"
    FAILED=$((FAILED + 1))
fi

# 16. Symlink destination rejected before realpath (Nit 4)
echo -n "Running test case: 16_symlink_destination_rejected ... "
case16_dir="${TEST_DIR}/case_16_symlink"
mkdir -p "${case16_dir}/models/checkpoints"
ln -s "/tmp/evil_symlink_target" "${case16_dir}/models/checkpoints/symlink.safetensors"
log16="$(MODELS_DIR="${case16_dir}/models" MODELS_TO_DOWNLOAD="checkpoint:https://127.0.0.1:${HTTPS_PORT}/symlink.safetensors $GOOD_SHA" /bin/bash "$DOWNLOADER" 2>&1 || true)"
if grep -q "Refusing symlink destination" <<<"$log16"; then
    echo "PASS"
    PASSED=$((PASSED + 1))
else
    echo "FAIL (symlink destination not refused before realpath)"
    FAILED=$((FAILED + 1))
fi

# 17. Invalid size and headroom inputs handled safely (Nit 1)
echo -n "Running test case: 17_invalid_size_headroom_inputs ... "
case17_dir="${TEST_DIR}/case_17_size_check"
mkdir -p "${case17_dir}/models"
log17="$(MODELS_DIR="${case17_dir}/models" MODELS_MAX_FILESIZE="50G;rm -rf /" MODELS_DISK_HEADROOM_KB="invalid_kb" MODELS_TO_DOWNLOAD="checkpoint:https://127.0.0.1:${HTTPS_PORT}/good.safetensors $GOOD_SHA" /bin/bash "$DOWNLOADER" 2>&1 || true)"
if grep -q "Invalid MODELS_MAX_FILESIZE" <<<"$log17" && grep -q "Invalid MODELS_DISK_HEADROOM_KB" <<<"$log17"; then
    echo "PASS"
    PASSED=$((PASSED + 1))
else
    echo "FAIL (invalid size/headroom inputs not safely caught without evaluation)"
    FAILED=$((FAILED + 1))
fi

# 18. Genuine happy-path download and atomic placement (Nit 8)
echo -n "Running test case: 18_happy_path_download ... "
case18_dir="${TEST_DIR}/case_18_happy"
mkdir -p "${case18_dir}/models/checkpoints"
log18="$(MODELS_DIR="${case18_dir}/models" MODELS_TO_DOWNLOAD="checkpoint:https://127.0.0.1:${HTTPS_PORT}/good.safetensors $GOOD_SHA" /bin/bash "$DOWNLOADER" 2>&1 || true)"
dest18="${case18_dir}/models/checkpoints/good.safetensors"
if [ -f "$dest18" ] && [ "$(sha256sum "$dest18" | awk '{print $1}')" = "$GOOD_SHA" ] && grep -q "Saved good.safetensors" <<<"$log18"; then
    echo "PASS"
    PASSED=$((PASSED + 1))
else
    echo "FAIL (happy path file not downloaded or hash mismatch)"
    FAILED=$((FAILED + 1))
fi

# 19. Authenticated HF download with canary token (F1, Nit 8)
echo -n "Running test case: 19_hf_token_authenticated ... "
case19_dir="${TEST_DIR}/case_19_hf_auth"
mkdir -p "${case19_dir}/models/checkpoints"
log19="$(HF_TOKEN="CANARY_HF_TOKEN_VAL_12345" MODELS_DIR="${case19_dir}/models" MODELS_TO_DOWNLOAD="checkpoint:https://127.0.0.1:${HTTPS_PORT}/hf_authed.safetensors $GOOD_SHA" /bin/bash "$DOWNLOADER" 2>&1 || true)"
dest19="${case19_dir}/models/checkpoints/hf_authed.safetensors"
if [ -f "$dest19" ] && [ "$(sha256sum "$dest19" | awk '{print $1}')" = "$GOOD_SHA" ] && \
   ! grep -q "exit 26" <<<"$log19" && \
   ! grep -q "CANARY_HF_TOKEN_VAL_12345" <<<"$log19"; then
    echo "PASS"
    PASSED=$((PASSED + 1))
else
    echo "FAIL (authenticated HF download failed, had exit 26, or leaked canary)"
    FAILED=$((FAILED + 1))
fi

# 20. Authenticated CivitAI download with canary token (F1, Nit 8)
echo -n "Running test case: 20_civitai_token_authenticated ... "
case20_dir="${TEST_DIR}/case_20_cv_auth"
mkdir -p "${case20_dir}/models/checkpoints"
log20="$(CIVITAI_TOKEN="CANARY_CV_TOKEN_VAL_67890" MODELS_DIR="${case20_dir}/models" MODELS_TO_DOWNLOAD="checkpoint:https://127.0.0.1:${HTTPS_PORT}/cv_authed.safetensors $GOOD_SHA" /bin/bash "$DOWNLOADER" 2>&1 || true)"
dest20="${case20_dir}/models/checkpoints/cv_authed.safetensors"
if [ -f "$dest20" ] && [ "$(sha256sum "$dest20" | awk '{print $1}')" = "$GOOD_SHA" ] && \
   ! grep -q "exit 26" <<<"$log20" && \
   ! grep -q "CANARY_CV_TOKEN_VAL_67890" <<<"$log20"; then
    echo "PASS"
    PASSED=$((PASSED + 1))
else
    echo "FAIL (authenticated CivitAI download failed, had exit 26, or leaked canary)"
    FAILED=$((FAILED + 1))
fi

# 21. Token fallback from .env file (F1, User Requirement)
echo -n "Running test case: 21_env_file_token_fallback ... "
case21_dir="${TEST_DIR}/case_21_env_fallback"
mkdir -p "${case21_dir}/models/checkpoints"
env21="${case21_dir}/test.env"
echo "HF_TOKEN=CANARY_ENV_TOKEN_VAL_99999" > "$env21"
log21="$(ENV_FILE="$env21" MODELS_DIR="${case21_dir}/models" MODELS_TO_DOWNLOAD="checkpoint:https://127.0.0.1:${HTTPS_PORT}/hf_authed.safetensors $GOOD_SHA" /bin/bash "$DOWNLOADER" 2>&1 || true)"
dest21="${case21_dir}/models/checkpoints/hf_authed.safetensors"
if [ -f "$dest21" ] && [ "$(sha256sum "$dest21" | awk '{print $1}')" = "$GOOD_SHA" ]; then
    echo "PASS"
    PASSED=$((PASSED + 1))
else
    echo "FAIL (.env token fallback not loaded)"
    FAILED=$((FAILED + 1))
fi

# 22. Clean recovery from curl exit 33 (Nit 7, Nit 8)
echo -n "Running test case: 22_exit_33_clean_recovery ... "
case22_dir="${TEST_DIR}/case_22_exit33"
mkdir -p "${case22_dir}/models/checkpoints"
# Create a junk .part file
printf "JUNK-CORRUPTED-PART-DATA" > "${case22_dir}/models/checkpoints/range_test.safetensors.part"
log22="$(MODELS_DIR="${case22_dir}/models" MODELS_TO_DOWNLOAD="checkpoint:https://127.0.0.1:${HTTPS_PORT}/range_test.safetensors $GOOD_SHA" /bin/bash "$DOWNLOADER" 2>&1 || true)"
dest22="${case22_dir}/models/checkpoints/range_test.safetensors"
if [ -f "$dest22" ] && [ "$(sha256sum "$dest22" | awk '{print $1}')" = "$GOOD_SHA" ] && \
   grep -q "curl exit 33" <<<"$log22" && grep -q "Saved range_test.safetensors" <<<"$log22"; then
    echo "PASS"
    PASSED=$((PASSED + 1))
else
    echo "FAIL (clean recovery from exit 33 failed or file not saved)"
    FAILED=$((FAILED + 1))
fi

echo "============================================================"
echo "Harness Results: $PASSED passed, $FAILED failed."
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
echo "All downloader test cases passed successfully!"
exit 0
