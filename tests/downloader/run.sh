#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Test harness for scripts/mss-download-models.sh
# Tests 15 rejection cases using a local HTTPS test server
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

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass # suppress access log

    def do_HEAD(self):
        self.do_GET(head_only=True)

    def do_GET(self, head_only=False):
        path = self.path.split("?")[0]
        try:
            if path == "/good.safetensors":
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(data_good)))
                self.end_headers()
                if not head_only:
                    self.wfile.write(data_good)
            elif path == "/pickle.ckpt":
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(data_pickle)))
                self.end_headers()
                if not head_only:
                    self.wfile.write(data_pickle)
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

# Compute actual sha256 of good and pickle test payloads
GOOD_SHA="$(python3 -c "import hashlib; print(hashlib.sha256(b'TEST-MODEL-DATA-VALID-CONTENT' * 64).hexdigest())")"
PICKLE_SHA="$(python3 -c "import hashlib; print(hashlib.sha256(b'TEST-PICKLE-DATA-UNSAFE' * 32).hexdigest())")"
OVERSIZED_SHA="$(python3 -c "import hashlib; print(hashlib.sha256(b'A' * (2 * 1024 * 1024)).hexdigest())")"

export CURL_CA_BUNDLE="$CA_CERT"

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

# 2. HTTPS to HTTP redirect
assert_rejection "02_https_to_http_redirect" \
    "checkpoint:https://127.0.0.1:${HTTPS_PORT}/redirect_to_http $GOOD_SHA" \
    "(Protocol.*disabled in libcurl|Failed to download)"

# 3. Unpinned entry
assert_rejection "03_unpinned_entry" \
    "checkpoint:https://127.0.0.1:${HTTPS_PORT}/good.safetensors" \
    "Refusing unpinned entry"

# 4. Pickle file from non-allowed host (127.0.0.1 instead of huggingface.co/civitai.com)
assert_rejection "04_pickle_disallowed_host" \
    "checkpoint:https://127.0.0.1:${HTTPS_PORT}/pickle.ckpt $PICKLE_SHA" \
    "Refusing pickle file from disallowed host: 127.0.0.1"

# 5. Name or URL starting with '-'
assert_rejection "05a_url_starting_with_dash" \
    "-https://127.0.0.1:${HTTPS_PORT}/good.safetensors $GOOD_SHA" \
    "Refusing (entry|URL) starting with '-'"

assert_rejection "05b_name_starting_with_dash" \
    "checkpoint:https://127.0.0.1:${HTTPS_PORT}/-badname.safetensors $GOOD_SHA" \
    "Refusing unsafe file name: -badname.safetensors"

# 6. Control characters in filename
assert_rejection "06_control_characters" \
    "checkpoint:https://127.0.0.1:${HTTPS_PORT}/bad"$'\x01'"name.safetensors $GOOD_SHA" \
    "Refusing unsafe file name"

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
    "Refusing name collision in manifest"

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

# 12. Oversized file limit
assert_rejection "12_oversized_file" \
    "checkpoint:https://127.0.0.1:${HTTPS_PORT}/oversized.safetensors $OVERSIZED_SHA" \
    "(Failed to download|Maximum file size exceeded)" \
    "MODELS_MAX_FILESIZE=500K"

# 13. Low disk space
assert_rejection "13_low_disk_space" \
    "checkpoint:https://127.0.0.1:${HTTPS_PORT}/good.safetensors $GOOD_SHA" \
    "Insufficient disk space in" \
    "MODELS_DISK_HEADROOM_KB=9999999999"

# 14. Network timeout
assert_rejection "14_network_timeout" \
    "checkpoint:https://127.0.0.1:${HTTPS_PORT}/slow.safetensors $GOOD_SHA" \
    "Failed to download" \
    "MODELS_CONNECT_TIMEOUT=1 MODELS_MAX_TIME=2"

# 15. Tokenized URL credential redaction in logs
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

echo "============================================================"
echo "Harness Results: $PASSED passed, $FAILED failed."
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
echo "All downloader rejection test cases passed successfully!"
exit 0
