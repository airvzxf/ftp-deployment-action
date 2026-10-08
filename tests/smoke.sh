#!/bin/sh
# tests/smoke.sh — smoke tests for entrypoint.sh.
#
# These run entrypoint.sh inside an Alpine container with lftp
# installed against a fake server (TCP port 1, which refuses
# connection) and assert the expected behaviour.
#
# Requirements:
#   - docker or podman on PATH
#   - network access to pull alpine:3.23.3 (first run only)
#
# Skip (exit 0) if no container runtime is available.

set -u

# shellcheck disable=SC1007
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
INIT_REL=./entrypoint.sh

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

# v2.11.3 (#137): smoke tests run inside a pre-baked image that
# already has lftp + ca-certificates installed (see
# tests/Dockerfile.smoke). The previous flow did `apk add --no-cache`
# inside every container, which (a) raced the apk index download
# against the wait_for_port deadline in CI and (b) silently masked
# apk failures behind the `>/dev/null 2>&1` so a network error
# looked like an entrypoint.sh error. The pre-baked image is built
# once via `make build-smoke-image` and is pinned to the same
# alpine digest + lftp version as the production image (see
# tests/Dockerfile.smoke for the rationale).
SMOKE_IMAGE="${SMOKE_IMAGE:-ftp-deployment-action-smoke:local}"
if ! ${RUNTIME} image inspect "${SMOKE_IMAGE}" >/dev/null 2>&1; then
  fail "smoke image ${SMOKE_IMAGE} not found; run: make build-smoke-image"
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

# run_init ENV_VAR_1 [ENV_VAR_2 ...] TIMEOUT_SECONDS
#   Runs entrypoint.sh in alpine, returns combined stdout+stderr.
#   Each ENV_VAR_N is a "KEY=value" string written as a separate
#   line in the env file. The last argument, if numeric, is the
#   outer timeout for the lftp call inside the container.
#   /app is a bind-mount of the repo root, so /app/VERSION is the
#   repo's VERSION file, as in the image.
run_init() {
  _t=15
  # Pop the trailing numeric argument as the timeout, if any.
  for _arg in "$@"; do
    case "${_arg}" in
      ''|*[!0-9]*) ;;
      *) _t=${_arg} ;;
    esac
  done
  _env_file=$(mktemp) || return 1
  {
    common_env
    for _arg in "$@"; do
      case "${_arg}" in
        ''|*[!0-9]*) printf '%s\n' "${_arg}" ;;
      esac
    done
  } > "${_env_file}"
  ${RUNTIME} run --rm \
    -v "${ROOT}:/app:ro" \
    -w /app \
    --env-file "${_env_file}" \
    "${SMOKE_IMAGE}" \
    /bin/sh -c "timeout ${_t} sh ${INIT_REL} 2>&1; echo EXIT=\$?" \
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
# PR-C, entrypoint.sh emits `::add-mask::<value>` for sensitive inputs as
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
# Test 4b (v2.11.8 #194): INPUT_DEBUG=false suppresses the
# Resolved configuration dump. The dump previously leaked
# INPUT_LOCAL_DIR, INPUT_REMOTE_DIR, FTP_SETTINGS, MIRROR_COMMAND,
# INPUT_MAX_RETRIES, and an `ls -lha` of the local directory on
# every run regardless of debug setting. Now gated on
# INPUT_DEBUG=true; a non-debug run must NOT emit the
# "Resolved configuration" group.
# ----------------------------------------------------------------------------
out=$(run_init "INPUT_PASSWORD=NoDebugLeakCheck" 30)
if echo "${out}" | grep -q 'Resolved configuration'; then
  fail "INPUT_DEBUG=false must NOT print Resolved configuration group; output was:\n${out}"
fi
pass "INPUT_DEBUG=false suppresses Resolved configuration dump (v2.11.8 #194)"

# ----------------------------------------------------------------------------
# Test 5: mirror_verbose is honoured (output mentions verbose=2)
# v2.11.8 (#194): print_resolved_config is gated on INPUT_DEBUG=true;
# the test opts in so the MIRROR_COMMAND line surfaces in the dump.
# ----------------------------------------------------------------------------
out=$(run_init "INPUT_MIRROR_VERBOSE=2" "INPUT_DEBUG=true" 30)
echo "${out}" | grep -q "MIRROR_COMMAND.*--verbose=2" \
  || fail "mirror_verbose=2 was not reflected in MIRROR_COMMAND; output was:\n${out}"
pass "mirror_verbose is honoured by entrypoint.sh"

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
#
# v2.11.3 (#159): the previous version passed a single quoted string
# `'INPUT_SERVER=ftp://[::1]:21 INPUT_PASSWORD=foo'`, which POSIX sh
# parses as ONE argument — the space inside the single-quoted block
# is not a word separator. run_init then wrote it verbatim as a
# single env-file line, so `INPUT_PASSWORD=foo` was silently
# conflated into `INPUT_SERVER` (the container saw
# `INPUT_SERVER=ftp://[::1]:21 INPUT_PASSWORD=foo` as one var and
# left `INPUT_PASSWORD` at its `common_env` value `p`). The test
# passed only because lftp then fails on the malformed URL. Fix:
# pass the two env values as two separately-quoted arguments so
# they land in the env file on separate lines.
out=$(run_init 'INPUT_SERVER=ftp://[::1]:21' 'INPUT_PASSWORD=foo' 30)
# If the script runs at all (vs. aborting with a parse error), the
# IPv6 host extraction is functional.
echo "${out}" | grep -qE "ERROR: (max_retries|local_dir|remote_dir|lftp_settings)" \
  && fail "IPv6 host triggered a validation error; output was:\n${out}"
echo "${out}" | grep -q "^EXIT=1" \
  || fail "IPv6 host test did not exit 1 (expected connection failure); output was:\n${out}"
# v2.11.3 (#159): also assert the password actually reached the
# container, so a future regression in run_init's arg parsing or in
# --env-file's line-splitting fails loud instead of silently keeping
# the common_env default.
echo "${out}" | grep -qF "::add-mask::foo" \
  || fail "INPUT_PASSWORD=foo did not reach the container; output was:\n${out}"
pass "bracketed IPv6 host does not break the script (and INPUT_PASSWORD=foo reaches the container)"

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
# (which is where lftp is actually invoked). The entrypoint.sh now writes the
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
# Test 15: the pinned ref does not change the output (#324): no
# ::warning:: / ::notice:: / ::error:: for @latest, @master or a v1 tag.
# ----------------------------------------------------------------------------
for _ref in latest master v1.3.3; do
  out=$(run_init "GITHUB_ACTION_REF=${_ref}" 10)
  if echo "${out}" | grep -qE "::(warning|notice|error) file=action.yml"; then
    fail "GITHUB_ACTION_REF=${_ref} produced a workflow annotation; output was:\n${out}"
  fi
done
pass "GITHUB_ACTION_REF=latest/master/v1.3.3 produce no annotation"

# ----------------------------------------------------------------------------
# Test 22: A6 — failure banner points to the lftp output above it.
# ----------------------------------------------------------------------------
# We use max_retries=1 to keep the test fast (a single lftp attempt
# + a quick classification pass). The log file inside the container
# is unreachable for the user, so the banner must point to the lftp
# output already printed in the step log instead.
out=$(run_init "INPUT_MAX_RETRIES=1" 30)
echo "${out}" | grep -q "The server's reply is in the lftp output above." \
  || fail "failure banner did not point to the lftp output; output was:\n${out}"
pass "failure banner points to the lftp output in the step log"

# ----------------------------------------------------------------------------
# Test 23: the failure banner appears for an unreachable server even
# when no error matches the A6 classifier (i.e. we did not regress by
# always aborting on the first failure).
# ----------------------------------------------------------------------------
out=$(run_init "INPUT_MAX_RETRIES=1" 30)
echo "${out}" | grep -q "ERROR: UPLOAD FAILED" \
  || fail "unreachable server with max_retries=1 did not produce ERROR banner; output was:\n${out}"
# A6 should NOT have matched "max-retries exceeded (Connection refused)".
echo "${out}" | grep -q "PERMANENT" \
  && fail "A6 classifier incorrectly flagged a transient connection error as permanent; output was:\n${out}"
pass "A6 classifier does not flag transient connection errors as permanent"

# ----------------------------------------------------------------------------
# Test 24: dry_run=true — the mirror command gets --dry-run behind a
# `quote NOOP` connection check, so a dry run against the unreachable
# smoke server fails instead of printing the DRY RUN banner (#341).
# The success banner is covered by integration scenario 22.
# INPUT_DEBUG=true makes print_resolved_config dump MIRROR_COMMAND.
# ----------------------------------------------------------------------------
out=$(run_init "INPUT_DRY_RUN=true" "INPUT_DEBUG=true" 30)
echo "${out}" | grep -q "MIRROR_COMMAND.*quote NOOP && mirror .*--dry-run" \
  || fail "INPUT_DRY_RUN=true was not reflected in MIRROR_COMMAND; output was:\n${out}"
echo "${out}" | grep -q "^EXIT=1" \
  || fail "dry run against an unreachable server did not exit 1; output was:\n${out}"
if echo "${out}" | grep -q "FTP DRY RUN COMPLETED"; then
  fail "dry run against an unreachable server printed the DRY RUN banner; output was:\n${out}"
fi
pass "dry_run=true checks the connection before mirror --dry-run"

# ----------------------------------------------------------------------------
# Test 25: INPUT_EXCLUDE=*.map — `mirror -X *.map` appears in the
# resolved MIRROR_COMMAND, and NO `mirror:exclude*` directive is
# in FTP_SETTINGS (the v2.11.2 fix moved the exclude onto the
# mirror command itself; the previous `set mirror:exclude <value>`
# was a silent no-op in lftp 4.9.3 because `mirror:exclude` is
# never queried by MirrorJob).
# Uses dry_run=true so the script completes without a real lftp
# connection attempt (we only care about the resolved MIRROR_COMMAND
# string, not the actual mirror). v2.11.8 (#194): INPUT_DEBUG=true
# to surface the resolved-command dump.
# ----------------------------------------------------------------------------
out=$(run_init "INPUT_DRY_RUN=true" "INPUT_DEBUG=true" "INPUT_EXCLUDE=*.map" 30)
echo "${out}" | grep -qE 'MIRROR_COMMAND.*-X [*].map' \
  || fail "INPUT_EXCLUDE=*.map was not injected into MIRROR_COMMAND as -X flag; output was:\n${out}"
# mirror:exclude* must NOT appear in FTP_SETTINGS (was a silent
# no-op; v2.11.2 fix removed it).
if echo "${out}" | grep -qE 'set mirror:exclude'; then
  fail "INPUT_EXCLUDE should not produce any set mirror:exclude* directive in FTP_SETTINGS (was a silent no-op in lftp 4.9.3); output was:\n${out}"
fi
pass 'INPUT_EXCLUDE=*.map injects "mirror -X *.map" into MIRROR_COMMAND'

out=$(run_init "INPUT_DRY_RUN=true" "INPUT_DEBUG=true" 30)
if echo "${out}" | grep -qE 'set mirror:exclude'; then
  fail "default FTP_SETTINGS unexpectedly contains mirror:exclude; output was:\n${out}"
fi
pass "default FTP_SETTINGS contains no mirror:exclude directive (backward compatible)"

# ----------------------------------------------------------------------------
# Test 28 (v2.11.3 #160): INPUT_EXCLUDE is now validated by
# validate_glob_pattern (not validate_lftp_settings). Backtick /
# dollar / `!` / semicolons are valid glob/regex metacharacters
# for lftp's PatternSet and must NOT be rejected at validation
# time. Control characters and leading dash are still rejected
# (would break lftp argv parsing or be misread as -x / -X).
# Validation must pass; the script will then fail at the lftp
# connection (unreachable server) and exit 1.
# ----------------------------------------------------------------------------
backtick_val=$(printf 'foo%sbar' '`')
out=$(run_init "INPUT_DRY_RUN=true" "INPUT_EXCLUDE=${backtick_val}" 30)
# Backtick must NOT trigger validation rejection anymore.
if echo "${out}" | grep -q "lftp_settings contains backtick"; then
  fail "INPUT_EXCLUDE with backtick was rejected by old validator (v2.11.3 #160 regression); output was:\n${out}"
fi
# Backtick in exclude must NOT abort with any validation error.
if echo "${out}" | grep -qE "ERROR:.*(control|metacharacter|dollar|lftp_settings)"; then
  fail "INPUT_EXCLUDE with backtick triggered a validation error; output was:\n${out}"
fi
pass "INPUT_EXCLUDE with backtick passes validation (v2.11.3 #160 — glob-pattern validator)"

# Test 28b (v2.11.3 #160): control characters in INPUT_EXCLUDE
# ARE still rejected (validate_glob_pattern keeps the control-char
# deny-list; only the lftp-`-e`-script-specific rejections were
# dropped). Build the tab via printf because the smoke test runs
# under /bin/sh (busybox ash in the alpine test container does
# not expand `$'..'`).
tab_env=$(printf 'INPUT_EXCLUDE=foo\tbar')
out=$(run_init "${tab_env}" 10)
echo "${out}" | grep -q "control characters" \
  || fail "INPUT_EXCLUDE with tab was not rejected; output was:\n${out}"
echo "${out}" | grep -q "^EXIT=2" \
  || fail "INPUT_EXCLUDE with tab did not exit 2; output was:\n${out}"
pass "INPUT_EXCLUDE with control character (tab) is still rejected (exit 2)"

# Test 28c (v2.11.3 #160): leading dash in INPUT_EXCLUDE is
# rejected (would be misread by lftp as a `mirror` option rather
# than as the value of -x).
out=$(run_init "INPUT_EXCLUDE=-rf" 10)
echo "${out}" | grep -q "starts with a dash" \
  || fail "INPUT_EXCLUDE=-rf was not rejected; output was:\n${out}"
echo "${out}" | grep -q "^EXIT=2" \
  || fail "INPUT_EXCLUDE=-rf did not exit 2; output was:\n${out}"
pass "INPUT_EXCLUDE=-rf is rejected (would be misread as mirror option)"

# Test 28d (v2.11.3 #160): the `!` (lftp shell escape) is now
# accepted in INPUT_EXCLUDE — the previous validation was over-
# rejecting this valid glob character.
out=$(run_init "INPUT_DRY_RUN=true" 'INPUT_EXCLUDE=!important\.txt' 30)
if echo "${out}" | grep -qE "ERROR:.*(lftp_settings|\"!\")"; then
  fail "INPUT_EXCLUDE with '!' was rejected by old validator (v2.11.3 #160 over-rejection); output was:\n${out}"
fi
pass "INPUT_EXCLUDE with '!' (lftp shell escape) passes validation (v2.11.3 #160)"

# Test 28d2 (v2.11.3.1 / post-release F2 audit): the v2.11.3 #160
# docstring claimed INPUT_EXCLUDE was "a single argv slot to
# mirror, never parsed by a shell" — FALSE. The value is
# concatenated unquoted into the `lftp -e` script body, and lftp
# 4.9.3's parser treats `;`, `&`, `|` as command separators
# even mid-token. Re-introduce the command-separator rejection.
# `!`, backtick, `$`, space remain allowed as legitimate
# PatternSet / regex metacharacters.
for sep_val in 'foo;echo INJECTED' 'foo&echo INJECTED' 'foo|echo INJECTED' 'foo"X'; do
  out=$(run_init "INPUT_DRY_RUN=true" "INPUT_EXCLUDE=${sep_val}" 10)
  echo "${out}" | grep -q "lftp command separator\|double-quote" \
    || fail "INPUT_EXCLUDE='${sep_val}' was not rejected (v2.11.3.1 F2 audit); output was:\n${out}"
  echo "${out}" | grep -q "^EXIT=2" \
    || fail "INPUT_EXCLUDE='${sep_val}' did not exit 2; output was:\n${out}"
done
pass "INPUT_EXCLUDE rejects ;, &, |, and \" (lftp -e parser injection, v2.11.3.1)"

# Test 28d3 (v2.11.3.1 / post-release F2 audit): the embedded-
# newline case CANNOT be tested via the smoke harness's env-file
# path — docker's --env-file reader treats LF as the line
# separator, so a value with a literal newline is split into
# two env vars (`INPUT_EXCLUDE=foo` and `bar`) before the
# validator ever sees it. The case is covered at the unit
# level in tests/unit/validate.bats (validate_glob_pattern
# rejects newline, validate_int rejects newline). Documenting
# here so a future maintainer doesn't add a smoke test that
# can never fire.
#
# Test 28d4 (v2.11.3.1): same applies for validate_int — see 28d3.

# ----------------------------------------------------------------------------
# Test 28e (v2.11.3 #171): boolean inputs that flow into the
# lftp `-e` script (via build_ftp_settings -> "set <key> <val>;")
# must be validated as booleans. A malicious payload such as
# "true; !cat /home/lftp/.netrc" must be rejected with exit 2
# BEFORE lftp is invoked, blocking the RCE that #171 documented.
# ----------------------------------------------------------------------------
out=$(run_init 'INPUT_FTP_SSL_ALLOW=true; !cat /home/lftp/.netrc' 10)
echo "${out}" | grep -q "ftp_ssl_allow must be a bool" \
  || fail "INPUT_FTP_SSL_ALLOW with RCE payload was not rejected; output was:\n${out}"
echo "${out}" | grep -q "^EXIT=2" \
  || fail "INPUT_FTP_SSL_ALLOW with RCE payload did not exit 2; output was:\n${out}"
pass "INPUT_FTP_SSL_ALLOW='true; !cat ...' is rejected (RCE payload, v2.11.3 #171)"

# Test 28f (v2.11.3 #171): same RCE check for the duration inputs.
out=$(run_init 'INPUT_NET_TIMEOUT=15s; !cat /home/lftp/.netrc' 10)
echo "${out}" | grep -q "net_timeout must be a duration" \
  || fail "INPUT_NET_TIMEOUT with RCE payload was not rejected; output was:\n${out}"
echo "${out}" | grep -q "^EXIT=2" \
  || fail "INPUT_NET_TIMEOUT with RCE payload did not exit 2; output was:\n${out}"
pass "INPUT_NET_TIMEOUT='15s; !cat ...' is rejected (RCE payload, v2.11.3 #171)"

# Test 28g (v2.11.3 #171): dns_fatal_timeout='never' must still be
# accepted (the documented disable sentinel — the v2.11.2 audit
# caught the regex of the proposed fix would break this).
out=$(run_init "INPUT_DRY_RUN=true" 'INPUT_DNS_FATAL_TIMEOUT=never' 30)
if echo "${out}" | grep -qE "ERROR: dns_fatal_timeout"; then
  fail "INPUT_DNS_FATAL_TIMEOUT='never' was unexpectedly rejected (would regress documented sentinel); output was:\n${out}"
fi
pass "INPUT_DNS_FATAL_TIMEOUT='never' is accepted (documented sentinel, v2.11.3 #171)"

# ----------------------------------------------------------------------------
# Test 28h (v2.11.3 #172): paths with '!' or double-quote are
# rejected by validate_path. Without this, INPUT_LOCAL_DIR like
# '!cat /home/lftp/.netrc' would flow into the lftp -e script
# and execute the shell-escape as the lftp user (RCE).
# ----------------------------------------------------------------------------
out=$(run_init 'INPUT_LOCAL_DIR=!cat /home/lftp/.netrc' 10)
echo "${out}" | grep -q '"!"' \
  || fail "INPUT_LOCAL_DIR with '!' was not rejected; output was:\n${out}"
echo "${out}" | grep -q "^EXIT=2" \
  || fail "INPUT_LOCAL_DIR with '!' did not exit 2; output was:\n${out}"
pass "INPUT_LOCAL_DIR='!cat ...' is rejected (lftp shell escape, v2.11.3 #172)"

out=$(run_init 'INPUT_REMOTE_DIR=foo"; cls; quit;' 10)
echo "${out}" | grep -q "double-quote" \
  || fail "INPUT_REMOTE_DIR with double-quote was not rejected; output was:\n${out}"
echo "${out}" | grep -q "^EXIT=2" \
  || fail "INPUT_REMOTE_DIR with double-quote did not exit 2; output was:\n${out}"
pass 'INPUT_REMOTE_DIR with double-quote is rejected (lftp command injection, v2.11.3 #172)'

# ----------------------------------------------------------------------------
# Test 31: INPUT_CONCURRENCY_LOCK=false (default) — the lftp -e
# script is bit-for-bit identical to v2.7.0: no `quote MKD` or
# `repeat --until-ok` substring appears. We assert by substring
# absence (a passing test means the lock fragments are empty).
# ----------------------------------------------------------------------------
out=$(run_init "INPUT_DRY_RUN=true" 30)
if echo "${out}" | grep -q "quote MKD"; then
  fail "concurrency_lock=false (default) should not emit any quote MKD; output was:\n${out}"
fi
if echo "${out}" | grep -q "repeat --until-ok"; then
  fail "concurrency_lock=false (default) should not emit a repeat loop; output was:\n${out}"
fi
pass "concurrency_lock=false produces no lock fragments in the lftp script"

# ----------------------------------------------------------------------------
# Test 32: INPUT_CONCURRENCY_LOCK=true with a ".." path → exit 2
# (validate_path rejects traversal before any network attempt).
# ----------------------------------------------------------------------------
out=$(run_init "INPUT_CONCURRENCY_LOCK=true" "INPUT_CONCURRENCY_LOCK_PATH=../escape" 10)
echo "${out}" | grep -q "concurrency_lock_path contains \"\\.\\.\"" \
  || fail "concurrency_lock_path with traversal was not rejected; output was:\n${out}"
echo "${out}" | grep -q "^EXIT=2" \
  || fail "concurrency_lock_path with traversal did not exit 2; output was:\n${out}"
pass "concurrency_lock_path with '..' is rejected with exit 2"

# ----------------------------------------------------------------------------
# Test 33: INPUT_CONCURRENCY_LOCK=true with poll_interval=0 → exit 2
# (we explicitly reject 0 because it would cause a division-by-zero
# in the iteration-count computation).
# ----------------------------------------------------------------------------
out=$(run_init "INPUT_CONCURRENCY_LOCK=true" "INPUT_CONCURRENCY_LOCK_POLL_INTERVAL=0" 10)
echo "${out}" | grep -q "concurrency_lock_poll_interval must be > 0" \
  || fail "concurrency_lock_poll_interval=0 was not rejected; output was:\n${out}"
echo "${out}" | grep -q "^EXIT=2" \
  || fail "concurrency_lock_poll_interval=0 did not exit 2; output was:\n${out}"
pass "concurrency_lock_poll_interval=0 is rejected with exit 2"

# ----------------------------------------------------------------------------
# Test 34 (v2.9.0): INPUT_CONCURRENCY_LOCK=true against an
# unreachable server with a short timeout — entrypoint.sh must
# print the "could not acquire concurrency lock" error and exit 1,
# WITHOUT attempting the mirror. Validates the integration of the
# new acquire_lock_with_recovery helper with the entrypoint flow
# (the lock failure must surface as a clear, top-level error, not
# as a generic mirror failure).
# ----------------------------------------------------------------------------
out=$(run_init "INPUT_CONCURRENCY_LOCK=true" "INPUT_CONCURRENCY_LOCK_TIMEOUT=1" "INPUT_CONCURRENCY_LOCK_POLL_INTERVAL=1" "INPUT_MAX_RETRIES=1" 30)
echo "${out}" | grep -q "could not acquire concurrency lock" \
  || fail "INPUT_CONCURRENCY_LOCK=true + unreachable server did not print lock-acquire error; output was:\n${out}"
echo "${out}" | grep -q "^EXIT=1" \
  || fail "INPUT_CONCURRENCY_LOCK=true + unreachable server did not exit 1; output was:\n${out}"
# The mirror itself must NOT have been attempted (lock acquire
# happens before the mirror; if it fails, we go straight to the
# error path, not through run_lftp_once).
if echo "${out}" | grep -q "FTP UPLOADED FINISHED"; then
  fail "lock acquire failure should not reach the mirror; output was:\n${out}"
fi
pass "INPUT_CONCURRENCY_LOCK=true + unreachable server fails fast with lock-acquire error"

# ----------------------------------------------------------------------------
# Test 35 (v2.9.0): INPUT_CONCURRENCY_LOCK=false (default) on an
# unreachable server must reach the mirror phase and exit with
# the regular "UPLOAD FAILED" banner. Regression: ensures the
# disabled-lock code path stays unchanged.
# ----------------------------------------------------------------------------
out=$(run_init "INPUT_CONCURRENCY_LOCK=false" "INPUT_MAX_RETRIES=1" 30)
echo "${out}" | grep -q "ERROR: UPLOAD FAILED" \
  || fail "INPUT_CONCURRENCY_LOCK=false + unreachable server did not show regular failure banner; output was:\n${out}"
echo "${out}" | grep -q "^EXIT=1" \
  || fail "INPUT_CONCURRENCY_LOCK=false + unreachable server did not exit 1; output was:\n${out}"
# The lock acquire group must NOT have been entered.
if echo "${out}" | grep -q "Concurrency lock acquire"; then
  fail "lock disabled should not enter the Concurrency lock acquire group; output was:\n${out}"
fi
pass "INPUT_CONCURRENCY_LOCK=false (disabled) reaches the mirror and exits 1"

printf 'All smoke tests passed.\n'
exit 0
