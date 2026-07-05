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
#   Reads /app/VERSION from the bind-mount of the repo root, which is
#   the 'dev' string committed in VERSION. release.yml passes the
#   resolved tag as --build-arg VERSION in production images.
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
# Use a distinctive password so we can grep for it precisely. Since
# PR-C, init.sh emits `::add-mask::<value>` for sensitive inputs as
# defence-in-depth; the literal password value appears once in the
# log in that mask line, but never inside the "Inputs received" dump.
# The masked occurrence is what the user wants: GitHub auto-redacts
# those values in the rendered log.
out=$(run_init "INPUT_PASSWORD=SecretTokenDoNotLeakXYZ" 30)
# 1. The password value MUST appear at least once, in the ::add-mask:: line.
n_mask=$(printf '%s\n' "${out}" | grep -cF '::add-mask::SecretTokenDoNotLeakXYZ')
if [ "${n_mask}" -ne 1 ]; then
  fail "expected exactly one ::add-mask:: line for the password, got ${n_mask}; output was:\n${out}"
fi
# 2. The password MUST NOT appear inside the Inputs received dump.
#    Extract the dump block (between the first "=== Inputs received ==="
#    and the next "::endgroup::") and grep that.
dump=$(printf '%s\n' "${out}" | awk '/=== Inputs received ===/{flag=1;next}/::endgroup::/{flag=0}flag')
if printf '%s' "${dump}" | grep -qF 'SecretTokenDoNotLeakXYZ'; then
  fail "password value leaked into the Inputs received dump; output was:\n${out}"
fi
pass "default dump does not echo the password value (masked once, dump clean)"

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

# ----------------------------------------------------------------------------
# Test 7: B-04 — local_dir with ".." path traversal is rejected
# ----------------------------------------------------------------------------
out=$(run_init 'INPUT_LOCAL_DIR=../../etc' 10)
echo "${out}" | grep -q 'local_dir contains ".." path traversal' \
  || fail "path traversal in local_dir was not rejected; output was:\n${out}"
echo "${out}" | grep -q "^EXIT=2" \
  || fail "path traversal did not exit 2; output was:\n${out}"
pass 'local_dir="../../etc" is rejected with exit 2'

# ----------------------------------------------------------------------------
# Test 8: B-04 — remote_dir with ".." is also rejected
# ----------------------------------------------------------------------------
out=$(run_init 'INPUT_REMOTE_DIR=../foo' 10)
echo "${out}" | grep -q 'remote_dir contains ".." path traversal' \
  || fail "path traversal in remote_dir was not rejected; output was:\n${out}"
echo "${out}" | grep -q "^EXIT=2" \
  || fail "remote_dir path traversal did not exit 2; output was:\n${out}"
pass 'remote_dir="../foo" is rejected with exit 2'

# ----------------------------------------------------------------------------
# Test 9: B-04 — local_dir starting with '-' is rejected
# ----------------------------------------------------------------------------
out=$(run_init 'INPUT_LOCAL_DIR=-rf' 10)
echo "${out}" | grep -q "starts with a dash" \
  || fail "local_dir starting with dash was not rejected; output was:\n${out}"
echo "${out}" | grep -q "^EXIT=2" \
  || fail "local_dir starting with dash did not exit 2; output was:\n${out}"
pass "local_dir starting with a dash is rejected (exit 2)"

# ----------------------------------------------------------------------------
# Test 10: B-16 — lftp_settings with a backtick is rejected
# ----------------------------------------------------------------------------
# Build the value with printf to keep shellcheck happy and avoid the
# backtick being interpreted by the test harness.
backtick_val=$(printf 'set foo:bar %cuname' '`')
out=$(run_init "INPUT_LFTP_SETTINGS=${backtick_val}" 10)
echo "${out}" | grep -q "lftp_settings contains backtick" \
  || fail "lftp_settings with backtick was not rejected; output was:\n${out}"
echo "${out}" | grep -q "^EXIT=2" \
  || fail "lftp_settings with backtick did not exit 2; output was:\n${out}"
pass "lftp_settings with backtick is rejected (exit 2)"

# ----------------------------------------------------------------------------
# Test 11: B-16 — lftp_settings with more than 3 ';' is rejected
# ----------------------------------------------------------------------------
out=$(run_init 'INPUT_LFTP_SETTINGS=set a:1;set b:2;set c:3;set d:4;' 10)
echo "${out}" | grep -q "lftp_settings has 4" \
  || fail "lftp_settings with 4 ';' was not rejected; output was:\n${out}"
echo "${out}" | grep -q "^EXIT=2" \
  || fail "lftp_settings with 4 ';' did not exit 2; output was:\n${out}"
pass "lftp_settings with 4 ';' is rejected (exit 2)"

# ----------------------------------------------------------------------------
# Test 11b: B-16 — lftp_settings with '!' (lftp shell escape) is rejected
# ----------------------------------------------------------------------------
out=$(run_init 'INPUT_LFTP_SETTINGS=set x:y; !uname; set a:b' 10)
echo "${out}" | grep -q 'lftp_settings contains "!"' \
  || fail "lftp_settings with '!' was not rejected; output was:\n${out}"
echo "${out}" | grep -q "^EXIT=2" \
  || fail "lftp_settings with '!' did not exit 2; output was:\n${out}"
pass 'lftp_settings with "!" (lftp shell escape) is rejected (exit 2)'

# ----------------------------------------------------------------------------
# Test 11c: B-03 — bracketed IPv6 server is parsed correctly
# ----------------------------------------------------------------------------
# We can't actually connect to [::1] in the test container, but the
# host extraction should at least not error out on the URL form.
out=$(run_init 'INPUT_SERVER=ftp://[::1]:21 INPUT_PASSWORD=foo' 30)
# If the script runs at all (vs. aborting with a parse error), the
# IPv6 host extraction is functional.
echo "${out}" | grep -qE "ERROR: (max_retries|local_dir|remote_dir|lftp_settings)" \
  && fail "IPv6 host triggered a validation error; output was:\n${out}"
echo "${out}" | grep -q "^EXIT=1" \
  || fail "IPv6 host test did not exit 1 (expected connection failure); output was:\n${out}"
pass "bracketed IPv6 host does not break the script"

# ----------------------------------------------------------------------------
# Test 12: B-16 — documented lftp_settings (3 ';' chained) is accepted
# ----------------------------------------------------------------------------
out=$(run_init 'INPUT_LFTP_SETTINGS=set cache:cache-empty-listings true; set cmd:status-interval 1s; set http:user-agent "firefox";' 30)
# If validation passed, there should be no "ERROR: lftp_settings ..."
# line. The lftp call itself will still fail (unreachable server) but
# the failure should be the standard "lftp exited with code" path.
echo "${out}" | grep -qE "ERROR: lftp_settings" \
  && fail "lftp_settings validation unexpectedly failed; output was:\n${out}"
pass "documented lftp_settings (3 ';' chained) passes validation"

# ----------------------------------------------------------------------------
# Test 13: B-03 — password is NOT visible on the lftp command line
# ----------------------------------------------------------------------------
# Run with debug=true so that resolved values are echoed. Then verify
# the secret password does not appear inside the ::group::Upload block
# (which is where lftp is actually invoked). The init.sh now writes the
# password to a .netrc and omits the `-u` arg, so even with debug=true
# the only places the password appears are:
#   1. the ::add-mask:: line (defence-in-depth),
#   2. the "password: <value>" line of the env dump (debug only).
# Both are fine. What we MUST NOT see is the password inside the
# Upload group, where the lftp process and its stderr are captured.
_env_str=$(printf 'INPUT_PASSWORD=SuperSecretDoNotLeakZZZ\nINPUT_DEBUG=true')
out=$(run_init "${_env_str}" 30)
upload_block=$(printf '%s\n' "${out}" | awk '/::group::Upload/{flag=1;next}/::endgroup::/{flag=0;exit}flag')
n=$(printf '%s\n' "${upload_block}" | grep -cF 'SuperSecretDoNotLeakZZZ')
if [ "${n}" -ne 0 ]; then
  fail "password leaked into the Upload group (${n} occurrences); output was:\n${out}"
fi
pass "password is not visible inside the Upload group (lftp command line)"

# ----------------------------------------------------------------------------
# Test 14: B-02 — max_retries=0 means "retry forever".
#
# We can't actually run forever, so we run with a 25s outer timeout and
# verify that the script performs MORE than one attempt before being
# killed. With max_retries=1 (the old default for this test scenario) the
# script would give up after the first failure and print the ERROR
# banner. With max_retries=0 it must keep retrying.
# ----------------------------------------------------------------------------
out=$(run_init 'INPUT_MAX_RETRIES=0' 25)
# Count "Try #N" lines: at least 2 attempts must have happened.
n=$(printf '%s\n' "${out}" | grep -cE '^Try #[0-9]+$')
if [ "${n}" -lt 2 ]; then
  fail "max_retries=0 did not retry (only ${n} attempts in 25s); output was:\n${out}"
fi
# And the script must NOT have given up with the "ERROR: UPLOAD FAILED"
# banner in that window — only the timeout can stop it.
if printf '%s' "${out}" | grep -q "ERROR: UPLOAD FAILED"; then
  fail "max_retries=0 gave up early with the ERROR banner; output was:\n${out}"
fi
pass "max_retries=0 retries past the first failure (saw ${n} attempts in 25s)"

# ----------------------------------------------------------------------------
# Test 15: deprecation warning fires for EOL ref (v1.3.3).
# ----------------------------------------------------------------------------
out=$(run_init 'GITHUB_ACTION_REF=v1.3.3' 10)
echo "${out}" | grep -q "::warning file=action.yml,title=End-of-life version::" \
  || fail "no ::warning:: emitted for EOL ref v1.3.3; output was:\n${out}"
echo "${out}" | grep -q "v1.3.3 is end-of-life" \
  || fail "warning text does not mention the EOL ref; output was:\n${out}"
pass "::warning:: emitted for EOL ref v1.3.3"

# ----------------------------------------------------------------------------
# Test 16: ::notice:: fires for older-but-supported v1.x refs.
# ----------------------------------------------------------------------------
out=$(run_init 'GITHUB_ACTION_REF=v1.5.0' 10)
echo "${out}" | grep -q "::notice file=action.yml,title=New major available::" \
  || fail "no ::notice:: emitted for v1.5.0; output was:\n${out}"
echo "${out}" | grep -q "v2 is available" \
  || fail "notice text does not mention v2; output was:\n${out}"
pass "::notice:: emitted for v1.5.0 ('v2 is available')"

# ----------------------------------------------------------------------------
# Test 17: current line (v2.0.1) is silent.
# ----------------------------------------------------------------------------
out=$(run_init 'GITHUB_ACTION_REF=v2.0.1' 10)
if echo "${out}" | grep -qE "::warning|::notice|::error file=action.yml,title="; then
  fail "unexpected deprecation notice for current ref v2.0.1; output was:\n${out}"
fi
pass "no deprecation notice for current ref v2.0.1"

# ----------------------------------------------------------------------------
# Test 18: @latest emits a ::warning::.
# ----------------------------------------------------------------------------
out=$(run_init 'GITHUB_ACTION_REF=latest' 10)
echo "${out}" | grep -q "::warning file=action.yml,title=Deprecated usage::" \
  || fail "no ::warning:: emitted for @latest; output was:\n${out}"
echo "${out}" | grep -q "moving target" \
  || fail "@latest warning does not mention 'moving target'; output was:\n${out}"
pass "::warning:: emitted for @latest"

# ----------------------------------------------------------------------------
# Test 19: @master emits a ::warning::.
# ----------------------------------------------------------------------------
out=$(run_init 'GITHUB_ACTION_REF=master' 10)
echo "${out}" | grep -q "::warning file=action.yml,title=Branch usage::" \
  || fail "no ::warning:: emitted for @master; output was:\n${out}"
pass "::warning:: emitted for @master"

# ----------------------------------------------------------------------------
# Test 20: fail_on_deprecated=true + EOL ref -> ::error:: and exit 1.
# ----------------------------------------------------------------------------
out=$(run_init 'GITHUB_ACTION_REF=v1.3.3
INPUT_FAIL_ON_DEPRECATED=true' 10)
echo "${out}" | grep -q "::error file=action.yml::" \
  || fail "no ::error:: emitted with fail_on_deprecated=true; output was:\n${out}"
echo "${out}" | grep -q "^EXIT=1" \
  || fail "fail_on_deprecated=true on EOL ref did not exit 1; output was:\n${out}"
pass "fail_on_deprecated=true on EOL ref exits 1 with ::error::"

# ----------------------------------------------------------------------------
# Test 21: fail_on_deprecated=true + current ref -> no ::error::, action runs.
# ----------------------------------------------------------------------------
out=$(run_init 'GITHUB_ACTION_REF=v2.0.1
INPUT_FAIL_ON_DEPRECATED=true' 25)
if echo "${out}" | grep -q "::error file=action.yml::"; then
  fail "fail_on_deprecated=true on current ref unexpectedly fired; output was:\n${out}"
fi
echo "${out}" | grep -q "^EXIT=1" \
  || fail "current ref with fail_on_deprecated should still reach the lftp step; output was:\n${out}"
pass "fail_on_deprecated=true on current ref does not error out"

printf 'All smoke tests passed.\n'
exit 0
