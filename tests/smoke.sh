#!/bin/sh
# tests/smoke.sh — smoke tests for init.sh.
#
# These run init.sh inside an Alpine container with lftp installed
# against a fake server (TCP port 1, which refuses connection) and
# assert the expected behaviour.
#
# Requirements:
#   - docker or podman on PATH
#   - network access to pull alpine:3.23.3 (first run only)
#
# Skip (exit 0) if no container runtime is available.

set -u

# shellcheck disable=SC1007
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
INIT_REL=./init.sh

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf '  ok: %s\n' "$*"; }
skip() { printf '  skip: %s\n' "$*"; exit 0; }

if command -v docker >/dev/null 2>&1; then
  RUNTIME=docker
elif command -v podman >/dev/null 2>&1; then
  RUNTIME=podman
else
  skip "no docker/podman found"
fi

# Build the base env that all tests use. The dummy server refuses
# connections on port 1, so lftp fails immediately.
common_env() {
  printf '%s\n' \
    "INPUT_SERVER=ftp://127.0.0.1:1" \
    "INPUT_USER=u" \
    "INPUT_PASSWORD=p" \
    "INPUT_MAX_RETRIES=1" \
    "INPUT_MIRROR_VERBOSE=1" \
    "INPUT_FTP_NOP_INTERVAL=2" \
    "INPUT_NET_MAX_RETRIES=1" \
    "INPUT_NET_PERSIST_RETRIES=1" \
    "INPUT_DNS_MAX_RETRIES=1" \
    "INPUT_NET_TIMEOUT=1s" \
    "INPUT_DNS_FATAL_TIMEOUT=1s" \
    "INPUT_FTP_SSL_ALLOW=false"
}

# run_init ENV_VARS TIMEOUT_SECONDS
#   Runs init.sh in alpine, returns combined stdout+stderr.
run_init() {
  _env=$1
  _t=${2:-15}
  _env_file=$(mktemp) || return 1
  {
    common_env
    printf '%s\n' "${_env}"
  } > "${_env_file}"
  ${RUNTIME} run --rm \
    -v "${ROOT}:/app:ro" \
    -w /app \
    --env-file "${_env_file}" \
    alpine:3.23.3 \
    /bin/sh -c "apk add --no-cache lftp ca-certificates >/dev/null 2>&1 && timeout ${_t} sh ${INIT_REL} 2>&1; echo EXIT=\$?" \
    2>&1
  rm -f "${_env_file}"
}

# ----------------------------------------------------------------------------
# Test 1: max_retries=abc → exit 2 with clear error
# ----------------------------------------------------------------------------
out=$(run_init "INPUT_MAX_RETRIES=abc" 10)
echo "${out}" | grep -q "max_retries must be a non-negative integer" \
  || fail "max_retries=abc did not produce validation error; output was:\n${out}"
echo "${out}" | grep -q "^EXIT=2" \
  || fail "max_retries=abc did not exit 2; output was:\n${out}"
pass "max_retries=abc produces clear error and exits 2"

# ----------------------------------------------------------------------------
# Test 2: unreachable server → exit 1 after retries exhausted
# ----------------------------------------------------------------------------
out=$(run_init "" 30)
echo "${out}" | grep -q "lftp exited with code" \
  || fail "unreachable server did not produce lftp exit code message; output was:\n${out}"
echo "${out}" | grep -q "ERROR: UPLOAD FAILED" \
  || fail "unreachable server did not produce final ERROR banner; output was:\n${out}"
echo "${out}" | grep -q "^EXIT=1" \
  || fail "unreachable server did not exit 1; output was:\n${out}"
pass "unreachable server exits 1 with lftp error message"

# ----------------------------------------------------------------------------
# Test 3: debug=true echoes the password
# ----------------------------------------------------------------------------
out=$(run_init "INPUT_DEBUG=true" 30)
echo "${out}" | grep -q "password:[[:space:]]*p" \
  || fail "debug=true did not echo the password value; output was:\n${out}"
pass "debug=true echoes the password value"

# ----------------------------------------------------------------------------
# Test 4: default dump does NOT echo the password value
# ----------------------------------------------------------------------------
# Use a distinctive password so we can grep for it precisely.
out=$(run_init "INPUT_PASSWORD=SecretTokenDoNotLeakXYZ" 30)
echo "${out}" | grep -q "SecretTokenDoNotLeakXYZ" \
  && fail "default dump leaked the password value; output was:\n${out}"
pass "default dump does not echo the password value"

# ----------------------------------------------------------------------------
# Test 5: mirror_verbose is honoured (output mentions verbose=2)
# ----------------------------------------------------------------------------
out=$(run_init "INPUT_MIRROR_VERBOSE=2" 30)
echo "${out}" | grep -q "MIRROR_COMMAND.*--verbose=2" \
  || fail "mirror_verbose=2 was not reflected in MIRROR_COMMAND; output was:\n${out}"
pass "mirror_verbose is honoured by init.sh"

# ----------------------------------------------------------------------------
# Test 6: backoff between attempts is visible in the log
# ----------------------------------------------------------------------------
out=$(run_init "INPUT_MAX_RETRIES=2" 30)
echo "${out}" | grep -q "Backing off" \
  || fail "retry backoff not visible in the log; output was:\n${out}"
pass "retry backoff is visible in the log"

printf 'All smoke tests passed.\n'
exit 0
