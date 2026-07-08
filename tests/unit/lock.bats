#!/usr/bin/env bats
# tests/unit/lock.bats — unit tests for the concurrency-lock
# functions in lib.sh.
#
# The v2.8.0 inline-lftp-script approach (build_lock_acquire_script
# and build_lock_release_script emitting the `repeat --until-ok
# quote MKD ...` fragment) was replaced in v2.9.0 with shell-driven
# helpers (acquire_lock_with_recovery, release_lock_safely) so the
# stale-lock auto-recovery can do its LIST/parse/DELE/RMD sequence
# without fighting lftp's flow-control primitives. The
# build_lock_acquire_script and build_lock_release_script functions
# remain as no-op shims for source-level backward compat.
#
# Coverage matrix:
#   * build_lock_acquire_script — always empty (v2.9.0 deprecation).
#   * build_lock_release_script — always empty (v2.9.0 deprecation).
#   * _lock_sentinel_name — pure: TIMESTAMP + PID -> filename.
#   * _lock_age_seconds — pure: STAMP_NOW - STAMP_THEN in seconds.
#   * _lock_parse_sentinel_listing — pure: extract first sentinel
#     filename from an FTP LIST output.
#   * acquire_lock_with_recovery — uses lftp; tested via fake lftp.
#   * release_lock_safely — uses lftp; tested via fake lftp.
#   * run_lftp_lock_release — backward-compat shim, delegates to
#     release_lock_safely.

setup() {
  set +u
  set +e
  LIB="${BATS_TEST_DIRNAME}/../../lib.sh"
  # shellcheck disable=SC1090
  . "${LIB}"

  # Reset the lock-related INPUT_* to their action.yml defaults
  # before every test, so a previous test that set them does not
  # leak into the next one.
  unset INPUT_CONCURRENCY_LOCK \
        INPUT_CONCURRENCY_LOCK_PATH \
        INPUT_CONCURRENCY_LOCK_TIMEOUT \
        INPUT_CONCURRENCY_LOCK_POLL_INTERVAL

  # Build a fake `lftp` that captures the call arguments and
  # returns scripted results. Tests can override the script body
  # by writing to $BATS_TEST_TMPDIR/lftp.sh and pointing FAKE_LFTP
  # at it. By default, the fake exits 0 and emits nothing.
  export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-/tmp}"
  export FAKE_LFTP_LOG="${BATS_TEST_TMPDIR}/fake-lftp.log"
  export FAKE_LFTP_RC="${BATS_TEST_TMPDIR}/fake-lftp.rc"
  rm -f "${FAKE_LFTP_LOG}" "${FAKE_LFTP_RC}"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cat > "${BATS_TEST_TMPDIR}/bin/lftp" <<'FAKE'
#!/bin/sh
# Fake lftp for testing. Logs every call, then exits with the
# contents of $FAKE_LFTP_RC (default 0) and writes $FAKE_LFTP_STDOUT
# to stdout.
printf '%s\n' "$*" >> "${FAKE_LFTP_LOG:-/tmp/fake-lftp.log}"
if [ -n "${FAKE_LFTP_STDOUT:-}" ]; then
  printf '%s' "${FAKE_LFTP_STDOUT}"
fi
exit "${FAKE_LFTP_RC:-0}"
FAKE
  chmod +x "${BATS_TEST_TMPDIR}/bin/lftp"
}

teardown() {
  unset FAKE_LFTP_STDOUT
}

# ----------------------------------------------------------------------------
# build_lock_acquire_script — deprecated no-op (v2.9.0)
# ----------------------------------------------------------------------------

@test "build_lock_acquire_script: always empty (v2.9.0 deprecation)" {
  INPUT_CONCURRENCY_LOCK="true"
  INPUT_CONCURRENCY_LOCK_PATH=".lftp-deployment.lock"
  INPUT_CONCURRENCY_LOCK_TIMEOUT="300"
  INPUT_CONCURRENCY_LOCK_POLL_INTERVAL="5"
  run build_lock_acquire_script
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "build_lock_acquire_script: empty when INPUT_CONCURRENCY_LOCK is unset" {
  unset INPUT_CONCURRENCY_LOCK
  run build_lock_acquire_script
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "build_lock_acquire_script: empty when INPUT_CONCURRENCY_LOCK is false" {
  INPUT_CONCURRENCY_LOCK="false"
  run build_lock_acquire_script
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ----------------------------------------------------------------------------
# build_lock_release_script — deprecated no-op (v2.9.0)
# ----------------------------------------------------------------------------

@test "build_lock_release_script: always empty (v2.9.0 deprecation)" {
  INPUT_CONCURRENCY_LOCK="true"
  INPUT_CONCURRENCY_LOCK_PATH=".lftp-deployment.lock"
  run build_lock_release_script
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ----------------------------------------------------------------------------
# _lock_sentinel_name — pure
# ----------------------------------------------------------------------------

@test "_lock_sentinel_name: produces the documented format" {
  result=$(_lock_sentinel_name "20260707T080000Z" "1234")
  [ "$result" = ".lftp-deployment.lock.20260707T080000Z.1234.info" ]
}

@test "_lock_sentinel_name: handles large PIDs" {
  result=$(_lock_sentinel_name "20260101T000000Z" "999999")
  [ "$result" = ".lftp-deployment.lock.20260101T000000Z.999999.info" ]
}

@test "_lock_sentinel_name: round-trips through _lock_parse_sentinel_listing" {
  name=$(_lock_sentinel_name "20260707T080000Z" "1234")
  # Build a fake listing line.
  listing="drwxr-xr-x   2 user group         4096 Jul 07 08:00 ${name}"
  found=$(_lock_parse_sentinel_listing "${listing}")
  [ "$found" = "${name}" ]
}

# ----------------------------------------------------------------------------
# _lock_age_seconds — pure
# ----------------------------------------------------------------------------

@test "_lock_age_seconds: zero when now == then" {
  result=$(_lock_age_seconds "20260707T080000Z" "20260707T080000Z")
  [ "$result" = "0" ]
}

@test "_lock_age_seconds: positive when now > then" {
  result=$(_lock_age_seconds "20260707T080500Z" "20260707T080000Z")
  [ "$result" = "300" ]
}

@test "_lock_age_seconds: handles minute and hour boundaries" {
  result=$(_lock_age_seconds "20260707T090000Z" "20260707T080000Z")
  [ "$result" = "3600" ]
}

@test "_lock_age_seconds: handles day boundary" {
  result=$(_lock_age_seconds "20260708T000000Z" "20260707T235959Z")
  [ "$result" = "1" ]
}

@test "_lock_age_seconds: negative when then > now (clock skew)" {
  result=$(_lock_age_seconds "20260707T080000Z" "20260707T080500Z")
  [ "$result" = "-300" ]
}

# ----------------------------------------------------------------------------
# _lock_parse_sentinel_listing — pure
# ----------------------------------------------------------------------------

@test "_lock_parse_sentinel_listing: returns empty on empty input" {
  result=$(_lock_parse_sentinel_listing "")
  [ -z "$result" ]
}

@test "_lock_parse_sentinel_listing: returns empty on no match" {
  result=$(_lock_parse_sentinel_listing "drwxr-xr-x  2 u g 4096 Jul 07 08:00 some-file.txt")
  [ -z "$result" ]
}

@test "_lock_parse_sentinel_listing: extracts the first sentinel from a listing" {
  listing="drwxr-xr-x  2 u g 4096 Jul 07 08:00 .lftp-deployment.lock
-rw-r--r--  1 u g   12 Jul 07 08:00 .lftp-deployment.lock.20260707T080000Z.1234.info
-rw-r--r--  1 u g  100 Jul 07 08:01 .lftp-deployment.lock.20260707T080100Z.5678.info"
  result=$(_lock_parse_sentinel_listing "${listing}")
  [ "$result" = ".lftp-deployment.lock.20260707T080000Z.1234.info" ]
}

@test "_lock_parse_sentinel_listing: ignores the lock dir itself" {
  listing="drwxr-xr-x  2 u g 4096 Jul 07 08:00 .lftp-deployment.lock"
  result=$(_lock_parse_sentinel_listing "${listing}")
  [ -z "$result" ]
}

# ----------------------------------------------------------------------------
# acquire_lock_with_recovery — uses lftp, tested via fake
#
# Note: ACQUIRED_LOCK_SENTINEL is set as a global side-effect of
# a successful acquire, and `bats run` runs the command in a
# subshell which discards that assignment. We therefore call the
# function WITHOUT `run` and inspect both the captured return
# code and the global afterwards.
#
# bats runs every test body with `set -e` inherited, and the
# function under test legitimately returns 1 on the timeout
# path, so we wrap each call in `|| rc=$?`. The setup() above
# does `set +e` so `set -e` inside the function (set before its
# own internal lftp calls) does not cascade back and abort the
# test body.
# ----------------------------------------------------------------------------

@test "acquire_lock_with_recovery: MKD success writes sentinel and returns 0" {
  export FAKE_LFTP_RC="0"
  unset INPUT_SERVER INPUT_CONCURRENCY_LOCK_PATH INPUT_CONCURRENCY_LOCK_TIMEOUT INPUT_CONCURRENCY_LOCK_POLL_INTERVAL
  INPUT_SERVER="ftp://example.test"
  INPUT_CONCURRENCY_LOCK_PATH=".lftp-deployment.lock"
  INPUT_CONCURRENCY_LOCK_TIMEOUT="5"
  INPUT_CONCURRENCY_LOCK_POLL_INTERVAL="1"
  unset ACQUIRED_LOCK_SENTINEL
  acquire_lock_with_recovery \
    "ftp://example.test" ".lftp-deployment.lock" "5" "1" || rc=$?
  [ "${rc:-0}" -eq 0 ]
  # The first lftp call must be the MKD.
  grep -q "quote MKD .lftp-deployment.lock" "${FAKE_LFTP_LOG}"
  # The second lftp call must be the PUT for the sentinel.
  grep -q "put " "${FAKE_LFTP_LOG}"
  grep -q ".lftp-deployment.lock.*.info" "${FAKE_LFTP_LOG}"
  # ACQUIRED_LOCK_SENTINEL must be set.
  [ -n "${ACQUIRED_LOCK_SENTINEL:-}" ]
  case "${ACQUIRED_LOCK_SENTINEL}" in
    .lftp-deployment.lock.[0-9]*) ;;
    *) echo "ACQUIRED_LOCK_SENTINEL='${ACQUIRED_LOCK_SENTINEL}' does not match pattern"; false ;;
  esac
}

@test "acquire_lock_with_recovery: MKD 550 then stale listing -> takes over, returns 0" {
  # Scripted fake-lftp response sequence:
  #   1) MKD      -> exit 1 (held)
  #   2) LIST     -> echo stale sentinel listing
  #   3) DELE     -> exit 0 (stale cleanup)
  #   4) RMD      -> exit 0 (lock dir removed)
  #   5) MKD      -> exit 0 (retry succeeds)
  #   6) PUT      -> exit 0 (sentinel written)
  export FAKE_LFTP_SCRIPT="${BATS_TEST_TMPDIR}/fake-lftp-script.txt"
  cat > "${FAKE_LFTP_SCRIPT}" <<'SCRIPT'
exit 1
echo .lftp-deployment.lock.20200101T000000Z.1.info
exit 0
exit 0
exit 0
exit 0
SCRIPT
  cat > "${BATS_TEST_TMPDIR}/bin/lftp" <<'FAKE'
#!/bin/sh
# Stateful fake lftp. Each invocation reads one line of
# $FAKE_LFTP_SCRIPT and follows it. A line starting with "exit "
# sets the exit code. A line starting with "echo " is printed to
# stdout. Anything else is ignored.
line=$(head -n 1 "${FAKE_LFTP_SCRIPT:-/dev/null}" 2>/dev/null) || true
if [ -n "${line:-}" ]; then
  sed -i '1d' "${FAKE_LFTP_SCRIPT}"
  case "${line}" in
    exit\ *)
      rc=${line#exit }
      printf '%s\n' "$*" >> "${FAKE_LFTP_LOG:-/tmp/fake-lftp.log}"
      exit "${rc}"
      ;;
    echo\ *)
      payload=${line#echo }
      printf '%s\n' "$*" >> "${FAKE_LFTP_LOG:-/tmp/fake-lftp.log}"
      printf '%s\n' "${payload}"
      exit 0
      ;;
    *)
      printf '%s\n' "$*" >> "${FAKE_LFTP_LOG:-/tmp/fake-lftp.log}"
      exit 0
      ;;
  esac
fi
printf '%s\n' "$*" >> "${FAKE_LFTP_LOG:-/tmp/fake-lftp.log}"
exit 0
FAKE
  chmod +x "${BATS_TEST_TMPDIR}/bin/lftp"

  unset ACQUIRED_LOCK_SENTINEL
  acquire_lock_with_recovery \
    "ftp://example.test" ".lftp-deployment.lock" "5" "1" || rc=$?
  [ "${rc:-0}" -eq 0 ]
  # The fake received 6 calls: MKD (fail), LIST, DELE stale,
  # RMD lock dir, MKD (success), PUT sentinel.
  call_count=$(wc -l < "${FAKE_LFTP_LOG}")
  [ "${call_count}" -eq 6 ]
  grep -q "quote MKD .lftp-deployment.lock" "${FAKE_LFTP_LOG}"
  grep -q "quote LIST" "${FAKE_LFTP_LOG}"
  grep -q "quote DELE" "${FAKE_LFTP_LOG}"
  grep -q "quote RMD" "${FAKE_LFTP_LOG}"
  grep -q "put " "${FAKE_LFTP_LOG}"
  [ -n "${ACQUIRED_LOCK_SENTINEL:-}" ]
}

@test "acquire_lock_with_recovery: MKD 550 then recent listing -> sleeps, returns 1 on timeout" {
  # Scripted fake-lftp response sequence (count=1: one attempt):
  #   1) MKD      -> exit 1 (held)
  #   2) LIST     -> echo RECENT sentinel listing (current second)
  # Function should NOT take over, return 1 (timeout=1, poll=1).
  export FAKE_LFTP_SCRIPT="${BATS_TEST_TMPDIR}/fake-lftp-script.txt"
  recent_stamp=$(date -u +%Y%m%dT%H%M%SZ)
  cat > "${FAKE_LFTP_SCRIPT}" <<SCRIPT
exit 1
echo .lftp-deployment.lock.${recent_stamp}.1.info
SCRIPT
  cat > "${BATS_TEST_TMPDIR}/bin/lftp" <<'FAKE'
#!/bin/sh
line=$(head -n 1 "${FAKE_LFTP_SCRIPT:-/dev/null}" 2>/dev/null) || true
if [ -n "${line:-}" ]; then
  sed -i '1d' "${FAKE_LFTP_SCRIPT}"
  case "${line}" in
    exit\ *)
      rc=${line#exit }
      printf '%s\n' "$*" >> "${FAKE_LFTP_LOG:-/tmp/fake-lftp.log}"
      exit "${rc}"
      ;;
    echo\ *)
      payload=${line#echo }
      printf '%s\n' "$*" >> "${FAKE_LFTP_LOG:-/tmp/fake-lftp.log}"
      printf '%s\n' "${payload}"
      exit 0
      ;;
    *)
      printf '%s\n' "$*" >> "${FAKE_LFTP_LOG:-/tmp/fake-lftp.log}"
      exit 0
      ;;
  esac
fi
printf '%s\n' "$*" >> "${FAKE_LFTP_LOG:-/tmp/fake-lftp.log}"
exit 0
FAKE
  chmod +x "${BATS_TEST_TMPDIR}/bin/lftp"

  unset ACQUIRED_LOCK_SENTINEL
  acquire_lock_with_recovery \
    "ftp://example.test" ".lftp-deployment.lock" "1" "1" || rc=$?
  [ "${rc:-0}" -eq 1 ]
  # Recent sentinel -> NO DELE / RMD cleanup, no sentinel write.
  if grep -q "quote DELE" "${FAKE_LFTP_LOG}"; then
    echo "recent sentinel should not trigger DELE"
    cat "${FAKE_LFTP_LOG}"
    false
  fi
  if grep -q "quote RMD" "${FAKE_LFTP_LOG}"; then
    echo "recent sentinel should not trigger RMD"
    cat "${FAKE_LFTP_LOG}"
    false
  fi
  if grep -q "put " "${FAKE_LFTP_LOG}"; then
    echo "recent sentinel should not trigger sentinel PUT"
    cat "${FAKE_LFTP_LOG}"
    false
  fi
}

@test "acquire_lock_with_recovery: timeout=0 means single attempt, fail if held" {
  export FAKE_LFTP_RC="1"
  unset ACQUIRED_LOCK_SENTINEL
  acquire_lock_with_recovery \
    "ftp://example.test" ".lftp-deployment.lock" "0" "5" || rc=$?
  [ "${rc:-0}" -eq 1 ]
  # At least one MKD call (and no sentinel write).
  grep -q "quote MKD" "${FAKE_LFTP_LOG}"
  if grep -q "put " "${FAKE_LFTP_LOG}"; then
    echo "timeout=0 + MKD fail should not attempt sentinel write"
    cat "${FAKE_LFTP_LOG}"
    false
  fi
}

# ----------------------------------------------------------------------------
# release_lock_safely — uses lftp, tested via fake
# ----------------------------------------------------------------------------

@test "release_lock_safely: DELEs sentinel and RMDs lock dir" {
  rm -f "${FAKE_LFTP_LOG}"
  run release_lock_safely \
    "ftp://example.test" ".lftp-deployment.lock" \
    ".lftp-deployment.lock.20260707T080000Z.1234.info"
  [ "$status" -eq 0 ]
  grep -q "quote DELE .lftp-deployment.lock.20260707T080000Z.1234.info" "${FAKE_LFTP_LOG}"
  grep -q "quote RMD .lftp-deployment.lock" "${FAKE_LFTP_LOG}"
}

@test "release_lock_safely: only RMDs lock dir when no sentinel provided" {
  unset ACQUIRED_LOCK_SENTINEL
  rm -f "${FAKE_LFTP_LOG}"
  run release_lock_safely \
    "ftp://example.test" ".lftp-deployment.lock"
  [ "$status" -eq 0 ]
  grep -q "quote RMD .lftp-deployment.lock" "${FAKE_LFTP_LOG}"
  if grep -q "quote DELE" "${FAKE_LFTP_LOG}"; then
    echo "release_lock_safely should not DELE anything without a sentinel"
    cat "${FAKE_LFTP_LOG}"
    false
  fi
}

@test "release_lock_safely: falls back to ACQUIRED_LOCK_SENTINEL global" {
  rm -f "${FAKE_LFTP_LOG}"
  ACQUIRED_LOCK_SENTINEL=".lftp-deployment.lock.20260707T080000Z.1234.info"
  run release_lock_safely \
    "ftp://example.test" ".lftp-deployment.lock"
  [ "$status" -eq 0 ]
  grep -q "quote DELE .lftp-deployment.lock.20260707T080000Z.1234.info" "${FAKE_LFTP_LOG}"
}

@test "release_lock_safely: no-op when lock_path is empty" {
  rm -f "${FAKE_LFTP_LOG}"
  run release_lock_safely "ftp://example.test" ""
  [ "$status" -eq 0 ]
  [ ! -s "${FAKE_LFTP_LOG}" ]
}

# ----------------------------------------------------------------------------
# run_lftp_lock_release — backward-compat shim
# ----------------------------------------------------------------------------

@test "run_lftp_lock_release: no-op when lock path is empty" {
  run run_lftp_lock_release "ftp://nonexistent.invalid" \
                            "/tmp/does-not-exist-netrc" \
                            ""
  [ "$status" -eq 0 ]
  [ ! -s "${FAKE_LFTP_LOG}" ]
}

@test "run_lftp_lock_release: no-op when netrc file is missing" {
  rm -f "${FAKE_LFTP_LOG}"
  run run_lftp_lock_release "ftp://nonexistent.invalid" \
                            "/tmp/does-not-exist-netrc" \
                            ".lftp-deployment.lock"
  [ "$status" -eq 0 ]
  [ ! -s "${FAKE_LFTP_LOG}" ]
}

@test "run_lftp_lock_release: delegates to release_lock_safely when netrc exists" {
  rm -f "${FAKE_LFTP_LOG}"
  # Create a fake netrc so the netrc-exists check passes.
  fake_netrc="${BATS_TEST_TMPDIR}/fake-netrc"
  touch "${fake_netrc}"
  run run_lftp_lock_release "ftp://example.test" \
                            "${fake_netrc}" \
                            ".lftp-deployment.lock" \
                            ".lftp-deployment.lock.20260707T080000Z.1234.info"
  [ "$status" -eq 0 ]
  grep -q "quote RMD .lftp-deployment.lock" "${FAKE_LFTP_LOG}"
  grep -q "quote DELE .lftp-deployment.lock.20260707T080000Z.1234.info" "${FAKE_LFTP_LOG}"
}