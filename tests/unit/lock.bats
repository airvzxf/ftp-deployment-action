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

@test "_lock_parse_sentinel_listing: extracts every sentinel, one per line, sorted ascending by stamp" {
  # F2 audit (#173): the previous parser returned only the FIRST
  # sentinel via `head -1`, letting orphans accumulate when the
  # stale-recovery branch only DELEd one name. The fix returns
  # every parsed sentinel (sorted ascending by stamp so the
  # OLDEST is the first line) so the recovery branch can DELE
  # all of them in a single lftp invocation.
  listing="drwxr-xr-x  2 u g 4096 Jul 07 08:00 .lftp-deployment.lock
-rw-r--r--  1 u g   12 Jul 07 08:00 .lftp-deployment.lock.20260707T080000Z.1234.info
-rw-r--r--  1 u g  100 Jul 07 08:01 .lftp-deployment.lock.20260707T080100Z.5678.info"
  result=$(_lock_parse_sentinel_listing "${listing}")
  # Command substitution strips trailing newlines, so the captured
  # string ends in `.info` (no newline). `grep -c .` counts the
  # non-empty lines (matches) regardless of trailing newlines.
  [ "$(printf '%s\n' "${result}" | grep -c .)" -eq 2 ]
  printf '%s\n' "${result}" | grep -q "^.lftp-deployment.lock.20260707T080000Z.1234.info$"
  printf '%s\n' "${result}" | grep -q "^.lftp-deployment.lock.20260707T080100Z.5678.info$"
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
    "ftp://example.test" ".lftp-deployment.lock" "5" "1" "ftptest" || rc=$?
  [ "${rc:-0}" -eq 0 ]
  # The first lftp call must be the mkdir (v2.11.0: switched from
  # `quote MKD` — which silently swallowed 5xx replies in lftp
  # 4.9.x — to lftp's high-level mkdir command, which propagates
  # the 550 properly).
  grep -q "mkdir .lftp-deployment.lock" "${FAKE_LFTP_LOG}"
  # The second lftp call must be the PUT for the sentinel.
  grep -q "put " "${FAKE_LFTP_LOG}"
  grep -q ".lftp-deployment.lock.*.info" "${FAKE_LFTP_LOG}"
  # v2.11.x (#132): the URL passed to lftp MUST carry the embedded
  # user so lftp's .netrc lookup fires. If we regress to passing the
  # bare `ftp://example.test` URL, real FTP servers reject with 530.
  grep -q "ftp://ftptest@example.test" "${FAKE_LFTP_LOG}"
  if grep -q "ftp://example.test " "${FAKE_LFTP_LOG}"; then
    echo "acquire_lock_with_recovery passed the BARE URL to lftp; #132 regression"
    cat "${FAKE_LFTP_LOG}"
    false
  fi
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
    "ftp://example.test" ".lftp-deployment.lock" "5" "1" "ftptest" || rc=$?
  [ "${rc:-0}" -eq 0 ]
  # The fake received 5 calls: MKD (fail), LIST+DELE+RMD in a
  # SINGLE lftp invocation (F2 audit #173 + #176), MKD (success),
  # PUT sentinel. Pre-fix the LIST, DELE stale, and RMD were 3
  # separate lftp invocations (call_count == 6). The single
  # invocation makes the snapshot atomic against the FTP server's
  # view, closing the race window where a concurrent holder's
  # PUT-in-progress could be mis-classified.
  call_count=$(wc -l < "${FAKE_LFTP_LOG}")
  [ "${call_count}" -eq 5 ]
  # v2.11.0: switched MKD from `quote MKD` (which swallows 5xx in
  # lftp 4.9.x) to lftp's high-level `mkdir`. Stale-recovery LIST
  # also moved from raw `quote LIST` (rejected by vsftpd for lack
  # of PASV) to lftp's high-level `cls`.
  grep -q "mkdir .lftp-deployment.lock" "${FAKE_LFTP_LOG}"
  grep -q "cls -la ." "${FAKE_LFTP_LOG}"
  grep -q "quote DELE" "${FAKE_LFTP_LOG}"
  grep -q "quote RMD" "${FAKE_LFTP_LOG}"
  grep -q "put " "${FAKE_LFTP_LOG}"
  # v2.11.x (#132): every lftp call carries the embedded user.
  for _expected in \
      "ftp://ftptest@example.test.*mkdir .lftp-deployment.lock" \
      "ftp://ftptest@example.test.*cls -la" \
      "ftp://ftptest@example.test.*quote DELE" \
      "ftp://ftptest@example.test.*quote RMD" \
      "ftp://ftptest@example.test.*put "; do
    grep -q "${_expected}" "${FAKE_LFTP_LOG}" \
      || { echo "missing call: ${_expected}"; cat "${FAKE_LFTP_LOG}"; false; }
  done
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
    "ftp://example.test" ".lftp-deployment.lock" "1" "1" "ftptest" || rc=$?
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
    "ftp://example.test" ".lftp-deployment.lock" "0" "5" "ftptest" || rc=$?
  [ "${rc:-0}" -eq 1 ]
  # At least one MKD call (and no sentinel write).
  grep -q "mkdir .lftp-deployment.lock" "${FAKE_LFTP_LOG}"
  if grep -q "put " "${FAKE_LFTP_LOG}"; then
    echo "timeout=0 + MKD fail should not attempt sentinel write"
    cat "${FAKE_LFTP_LOG}"
    false
  fi
}

# F2 audit (#251): timeout=0 + MKD fail + RECENT sentinel present
# must NOT trigger DELE/RMD against the live holder's lock dir.
# The pre-fix code path: MKD fail → LIST → age check `-le 0` is
# false (real sentinels always have age >= 1s) → takeover branch
# fires → DELEs the live holder's sentinel + RMDs the lock dir.
# Post-fix: timeout=0 short-circuits BEFORE the LIST, returns 1
# without touching the FTP server again.
@test "acquire_lock_with_recovery: timeout=0 + MKD fail + recent sentinel does NOT DELE/RMD (issue #251)" {
  recent_stamp=$(date -u +%Y%m%dT%H%M%SZ)
  export FAKE_LFTP_SCRIPT="${BATS_TEST_TMPDIR}/fake-lftp-script.txt"
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
    exit\ *) rc=${line#exit }; printf '%s\n' "$*" >> "${FAKE_LFTP_LOG}"; exit "${rc}" ;;
    echo\ *) payload=${line#echo }; printf '%s\n' "$*" >> "${FAKE_LFTP_LOG}"; printf '%s\n' "${payload}"; exit 0 ;;
    *) printf '%s\n' "$*" >> "${FAKE_LFTP_LOG}"; exit 0 ;;
  esac
fi
printf '%s\n' "$*" >> "${FAKE_LFTP_LOG}"; exit 0
FAKE
  chmod +x "${BATS_TEST_TMPDIR}/bin/lftp"

  unset ACQUIRED_LOCK_SENTINEL
  acquire_lock_with_recovery \
    "ftp://example.test" ".lftp-deployment.lock" "0" "5" "ftptest" || rc=$?
  [ "${rc:-0}" -eq 1 ]
  # Only the initial MKD happened. timeout=0 means "fail
  # immediately when held" — there must be NO LIST, NO DELE, NO
  # RMD, NO PUT. A pre-fix regression test would see all four.
  grep -q "mkdir .lftp-deployment.lock" "${FAKE_LFTP_LOG}"
  if grep -q "cls -la" "${FAKE_LFTP_LOG}"; then
    echo "timeout=0 must not LIST (would leak holder sentinel info)"; cat "${FAKE_LFTP_LOG}"; false
  fi
  if grep -q "quote DELE" "${FAKE_LFTP_LOG}"; then
    echo "timeout=0 must not DELE — live holder sentinel would be vandalised (#251)"; cat "${FAKE_LFTP_LOG}"; false
  fi
  if grep -q "quote RMD" "${FAKE_LFTP_LOG}"; then
    echo "timeout=0 must not RMD — live holder lock dir would be vandalised (#251)"; cat "${FAKE_LFTP_LOG}"; false
  fi
  if grep -q "put " "${FAKE_LFTP_LOG}"; then
    echo "timeout=0 must not PUT — no lock was acquired"; cat "${FAKE_LFTP_LOG}"; false
  fi
  [ -z "${ACQUIRED_LOCK_SENTINEL:-}" ]
}

# F2 audit (#268): transient LIST failure (TCP reset, FTP 421,
# 10s timeout) must NOT trigger takeover against the held lock dir.
# Pre-fix: _alwr_listing_rc was discarded, an empty listing looked
# identical to "no sentinel", and `_alwr_took_over=1` (the default)
# fired DELE+RMD against a perfectly healthy holder. Post-fix:
# non-zero LIST exit code triggers sleep+continue (respect the lock,
# back off and retry) without any DELE/RMD.
@test "acquire_lock_with_recovery: LIST lftp failure does NOT trigger takeover (issue #268)" {
  # count=1 means a single iteration: MKD fail, LIST fail, then
  # sleep+continue → loop exits, return 1.
  export FAKE_LFTP_SCRIPT="${BATS_TEST_TMPDIR}/fake-lftp-script.txt"
  cat > "${FAKE_LFTP_SCRIPT}" <<'SCRIPT'
exit 1
exit 1
SCRIPT
  cat > "${BATS_TEST_TMPDIR}/bin/lftp" <<'FAKE'
#!/bin/sh
line=$(head -n 1 "${FAKE_LFTP_SCRIPT:-/dev/null}" 2>/dev/null) || true
if [ -n "${line:-}" ]; then
  sed -i '1d' "${FAKE_LFTP_SCRIPT}"
  case "${line}" in
    exit\ *) rc=${line#exit }; printf '%s\n' "$*" >> "${FAKE_LFTP_LOG}"; exit "${rc}" ;;
    echo\ *) payload=${line#echo }; printf '%s\n' "$*" >> "${FAKE_LFTP_LOG}"; printf '%s\n' "${payload}"; exit 0 ;;
    *) printf '%s\n' "$*" >> "${FAKE_LFTP_LOG}"; exit 0 ;;
  esac
fi
printf '%s\n' "$*" >> "${FAKE_LFTP_LOG}"; exit 0
FAKE
  chmod +x "${BATS_TEST_TMPDIR}/bin/lftp"

  unset ACQUIRED_LOCK_SENTINEL
  acquire_lock_with_recovery \
    "ftp://example.test" ".lftp-deployment.lock" "1" "1" "ftptest" || rc=$?
  [ "${rc:-0}" -eq 1 ]
  grep -q "mkdir .lftp-deployment.lock" "${FAKE_LFTP_LOG}"
  grep -q "cls -la" "${FAKE_LFTP_LOG}"
  if grep -q "quote DELE" "${FAKE_LFTP_LOG}"; then
    echo "transient LIST failure must NOT trigger DELE (would vandalise live holder)"; cat "${FAKE_LFTP_LOG}"; false
  fi
  if grep -q "quote RMD" "${FAKE_LFTP_LOG}"; then
    echo "transient LIST failure must NOT trigger RMD (would vandalise live holder)"; cat "${FAKE_LFTP_LOG}"; false
  fi
  if grep -q "put " "${FAKE_LFTP_LOG}"; then
    echo "transient LIST failure must NOT write a sentinel"; cat "${FAKE_LFTP_LOG}"; false
  fi
  [ -z "${ACQUIRED_LOCK_SENTINEL:-}" ]
}

# F2 audit (NEW): _lock_age_seconds must exit non-zero when
# mktime() returns -1 (parse failure). Pre-fix: the function
# would print `int(n - t)` with one or both -1 inputs, yielding a
# garbage age that could be negative or wildly positive; the
# caller's `[ age -le timeout ]` check would either (a) treat the
# sentinel as "infinitely old" and take over on stale data, or
# (b) treat it as "in the future" and respect the lock. Either
# way is data-dependent and brittle. Post-fix: invalid timestamps
# produce non-zero exit; the caller treats indeterminate ages as
# "lock held, back off".
#
# Note on input: mktime() returns -1 only on SYNTACTICALLY invalid
# input. A real lock-helper call could never produce this shape
# because the parser restricts the stamp to [0-9TZ]+, but a
# corrupted sentinel on the FTP server could escape that check.
# month=13 does NOT trigger -1 (mktime rolls over to month=1 of
# the following year); a non-numeric substring DOES. We use a
# non-numeric "now" stamp here to exercise the defensive branch.
@test "_lock_age_seconds: returns non-zero exit when mktime fails to parse" {
  # Non-numeric substring in 'now' forces mktime() to return -1
  # (verified empirically on both gawk and busybox awk).
  _lock_age_seconds "2026ab07T080000Z" "20260707T080000Z" >/dev/null 2>&1
  [ "$?" -ne 0 ]
}

# F2 audit (#268 + #173, paired): when LIST returns an EMPTY
# listing (no sentinels, no other files), the recovery branch
# must STILL RMD the lock dir and take over (the
# "previous-holder-died-between-MKD-and-PUT" race). This is the
# regression guard for the `|| _alwr_stale_files=""` fallback
# at lib.sh:1196: without it, grep's exit 1 (no match in an
# empty listing) propagates through `set -o pipefail` and `set
# -e` and aborts the function before recovery can run.
@test "acquire_lock_with_recovery: MKD 550 + empty listing -> RMDs lock dir (no sentinel to DELE), takes over" {
  # Scripted fake-lftp sequence:
  #   1) MKD  -> exit 1 (held)
  #   2) LIST -> echo '' (empty listing: the lock dir exists but
  #               the previous holder died between MKD and PUT)
  #   3) combined recovery -> exit 0 (cls+empty DELEs+RMD in one
  #               lftp invocation; #173 + #176 fix)
  #   4) MKD  -> exit 0 (retry succeeds)
  #   5) PUT  -> exit 0 (sentinel written)
  export FAKE_LFTP_SCRIPT="${BATS_TEST_TMPDIR}/fake-lftp-script.txt"
  cat > "${FAKE_LFTP_SCRIPT}" <<'SCRIPT'
exit 1
echo
exit 0
exit 0
exit 0
SCRIPT
  cat > "${BATS_TEST_TMPDIR}/bin/lftp" <<'FAKE'
#!/bin/sh
line=$(head -n 1 "${FAKE_LFTP_SCRIPT:-/dev/null}" 2>/dev/null) || true
if [ -n "${line:-}" ]; then
  sed -i '1d' "${FAKE_LFTP_SCRIPT}"
  case "${line}" in
    exit\ *) rc=${line#exit }; printf '%s\n' "$*" >> "${FAKE_LFTP_LOG}"; exit "${rc}" ;;
    echo\ *) payload=${line#echo }; printf '%s\n' "$*" >> "${FAKE_LFTP_LOG}"; printf '%s\n' "${payload}"; exit 0 ;;
    *) printf '%s\n' "$*" >> "${FAKE_LFTP_LOG}"; exit 0 ;;
  esac
fi
printf '%s\n' "$*" >> "${FAKE_LFTP_LOG}"; exit 0
FAKE
  chmod +x "${BATS_TEST_TMPDIR}/bin/lftp"

  unset ACQUIRED_LOCK_SENTINEL
  acquire_lock_with_recovery \
    "ftp://example.test" ".lftp-deployment.lock" "5" "1" "ftptest" || rc=$?
  [ "${rc:-0}" -eq 0 ]
  # call_count == 5: MKD fail + LIST + combined recovery +
  # MKD retry + PUT.
  call_count=$(wc -l < "${FAKE_LFTP_LOG}")
  [ "${call_count}" -eq 5 ]
  # No DELE in the combined recovery (no sentinel to DELE) but RMD
  # must still fire.
  if grep -q "quote DELE" "${FAKE_LFTP_LOG}"; then
    echo "empty listing must not emit any DELE"; cat "${FAKE_LFTP_LOG}"; false
  fi
  grep -q "quote RMD .lftp-deployment.lock" "${FAKE_LFTP_LOG}"
  [ -n "${ACQUIRED_LOCK_SENTINEL:-}" ]
}

# F2 audit v2.11.10 (#294): pre-fix the loop ran
# `ceil(timeout/poll)` iterations, so total wall-clock was
# `count * (poll + work)` — 1.4x to 2x the documented
# concurrency_lock_timeout. Post-fix we track wall-clock via
# `date +%s` and break when the deadline is reached, so the
# action returns within `timeout + one iteration of slack`
# regardless of how much per-iteration network work happens.
#
# The fake lftp here simulates 1s of network work per call
# (a `sleep 1` injected via FAKE_LFTP_WORK) so the pre-fix
# fixed-iteration loop blows past the documented timeout
# while the post-fix wall-clock loop honors it. Without the
# simulated work, both loops would complete in ~timeout
# seconds (sleep poll dominates) and the test could not
# distinguish them.
@test "acquire_lock_with_recovery: wall-clock timeout respects concurrency_lock_timeout (issue #294)" {
  # Stateful fake-lftp that always returns MKD-fail + recent
  # sentinel + exit 0, after sleeping 1s to simulate network
  # work. Pre-fill enough script lines for the worst case
  # (count = ceil(timeout/poll) iterations, two lftp calls
  # each: MKD + LIST).
  export FAKE_LFTP_SCRIPT="${BATS_TEST_TMPDIR}/fake-lftp-script.txt"
  export FAKE_LFTP_WORK="${FAKE_LFTP_WORK:-1}"
  recent_stamp=$(date -u +%Y%m%dT%H%M%SZ)
  : > "${FAKE_LFTP_SCRIPT}"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    printf 'exit 1\n' >> "${FAKE_LFTP_SCRIPT}"
    printf 'echo .lftp-deployment.lock.%s.1.info\n' "${recent_stamp}" >> "${FAKE_LFTP_SCRIPT}"
  done
  cat > "${BATS_TEST_TMPDIR}/bin/lftp" <<'FAKE'
#!/bin/sh
# Simulate network latency so the pre-fix fixed-iteration
# loop's per-iteration "work" is non-trivial. Without this,
# fake-lftp is sub-millisecond and the wall-clock blowup is
# invisible.
if [ -n "${FAKE_LFTP_WORK:-}" ]; then
  sleep "${FAKE_LFTP_WORK}"
fi
line=$(head -n 1 "${FAKE_LFTP_SCRIPT:-/dev/null}" 2>/dev/null) || true
if [ -n "${line:-}" ]; then
  sed -i '1d' "${FAKE_LFTP_SCRIPT}"
  case "${line}" in
    exit\ *) rc=${line#exit }; printf '%s\n' "$*" >> "${FAKE_LFTP_LOG}"; exit "${rc}" ;;
    echo\ *) payload=${line#echo }; printf '%s\n' "$*" >> "${FAKE_LFTP_LOG}"; printf '%s\n' "${payload}"; exit 0 ;;
    *) printf '%s\n' "$*" >> "${FAKE_LFTP_LOG}"; exit 0 ;;
  esac
fi
printf '%s\n' "$*" >> "${FAKE_LFTP_LOG}"; exit 0
FAKE
  chmod +x "${BATS_TEST_TMPDIR}/bin/lftp"

  unset ACQUIRED_LOCK_SENTINEL
  _start=$(date +%s)
  # timeout=3, poll=1: pre-fix count=3, each iter is
  # (1s MKD + 1s LIST + 1s sleep) = 3s, total ~9s.
  # Post-fix: bounded at 3s + one iter of slack = ~5s.
  # Allow 7s for CI clock granularity (sleep 1s is ±0.5s on
  # busy runners).
  acquire_lock_with_recovery \
    "ftp://example.test" ".lftp-deployment.lock" "3" "1" "ftptest" || rc=$?
  _end=$(date +%s)
  _elapsed=$((_end - _start))

  unset FAKE_LFTP_WORK

  [ "${rc:-0}" -eq 1 ]
  # Pre-fix: ceil(3/1)=3 iters * (1s work + 1s LIST + 1s
  # sleep) ~= 9s. Post-fix: bounded at timeout + one iter
  # ~= 5s. A regression to fixed-iteration counting blows
  # past 7s; wall-clock tracking stays under 7s.
  [ "${_elapsed}" -le 7 ]
}

# ----------------------------------------------------------------------------
# rewrite_lftp_url — pure helper extracted from run_lftp_once
# (closes #132). The URL rewrite is the v2.11.0 fix that makes lftp
# 4.9.3 consult ~/.netrc for a bare `ftp://host:port` URL.
# ----------------------------------------------------------------------------

@test "rewrite_lftp_url: bare ftp://host:21 + user -> ftp://user@host:21" {
  result=$(rewrite_lftp_url "ftp://host:21" "alice")
  [ "${result}" = "ftp://alice@host:21" ]
}

@test "rewrite_lftp_url: ftp://host:2121 (non-default port) + user -> ftp://user@host:2121" {
  result=$(rewrite_lftp_url "ftp://127.0.0.1:2121" "ftptest")
  [ "${result}" = "ftp://ftptest@127.0.0.1:2121" ]
}

@test "rewrite_lftp_url: ftp://user@host:21 + user -> unchanged (already has user)" {
  result=$(rewrite_lftp_url "ftp://alice@host:21" "bob")
  [ "${result}" = "ftp://alice@host:21" ]
}

@test "rewrite_lftp_url: ftp://user:pw@host:21 + user -> unchanged (B-03 preserved)" {
  result=$(rewrite_lftp_url "ftp://alice:hunter2@host:21" "bob")
  [ "${result}" = "ftp://alice:hunter2@host:21" ]
}

@test "rewrite_lftp_url: ftp://host:21 + empty user -> unchanged (no-op)" {
  result=$(rewrite_lftp_url "ftp://host:21" "")
  [ "${result}" = "ftp://host:21" ]
}

@test "rewrite_lftp_url: no-scheme host:21 + user -> unchanged (no scheme to rewrite)" {
  result=$(rewrite_lftp_url "host:21" "alice")
  [ "${result}" = "host:21" ]
}

@test "rewrite_lftp_url: ftps://host:990 + user -> ftps://user@host:990 (scheme preserved)" {
  result=$(rewrite_lftp_url "ftps://host:990" "alice")
  [ "${result}" = "ftps://alice@host:990" ]
}

@test "rewrite_lftp_url: ftp://host (no port) + user -> ftp://user@host" {
  result=$(rewrite_lftp_url "ftp://host" "alice")
  [ "${result}" = "ftp://alice@host" ]
}

@test "rewrite_lftp_url: ftp://[::1]:21 + user -> ftp://user@[::1]:21 (IPv6)" {
  result=$(rewrite_lftp_url "ftp://[::1]:21" "alice")
  [ "${result}" = "ftp://alice@[::1]:21" ]
}

# ----------------------------------------------------------------------------
# release_lock_safely — uses lftp, tested via fake
# ----------------------------------------------------------------------------

@test "release_lock_safely: DELEs sentinel and RMDs lock dir" {
  rm -f "${FAKE_LFTP_LOG}"
  run release_lock_safely \
    "ftp://example.test" ".lftp-deployment.lock" \
    ".lftp-deployment.lock.20260707T080000Z.1234.info" \
    "ftptest"
  [ "$status" -eq 0 ]
  grep -q "quote DELE .lftp-deployment.lock.20260707T080000Z.1234.info" "${FAKE_LFTP_LOG}"
  grep -q "quote RMD .lftp-deployment.lock" "${FAKE_LFTP_LOG}"
  # v2.11.x (#132): the EXIT-trap release URL must carry the
  # embedded user, same as acquire_lock_with_recovery.
  grep -q "ftp://ftptest@example.test" "${FAKE_LFTP_LOG}"
}

@test "release_lock_safely: no-op when no sentinel AND ACQUIRED_LOCK_SENTINEL empty (v2.11.3 #188)" {
  # The v2.11.3 fix: if neither the explicit arg nor the global
  # ACQUIRED_LOCK_SENTINEL is set, this process never acquired the
  # lock — issuing `quote RMD <lock_path>` would race a parallel
  # runner's live lock dir. The function must be a complete no-op.
  unset ACQUIRED_LOCK_SENTINEL
  rm -f "${FAKE_LFTP_LOG}"
  run release_lock_safely \
    "ftp://example.test" ".lftp-deployment.lock" "" "ftptest"
  [ "$status" -eq 0 ]
  if [ -s "${FAKE_LFTP_LOG}" ]; then
    echo "release_lock_safely must not invoke lftp when no sentinel is available (would race live holder); log was:"
    cat "${FAKE_LFTP_LOG}"
    false
  fi
}

@test "release_lock_safely: falls back to ACQUIRED_LOCK_SENTINEL global" {
  rm -f "${FAKE_LFTP_LOG}"
  ACQUIRED_LOCK_SENTINEL=".lftp-deployment.lock.20260707T080000Z.1234.info"
  run release_lock_safely \
    "ftp://example.test" ".lftp-deployment.lock" "" "ftptest"
  [ "$status" -eq 0 ]
  grep -q "quote DELE .lftp-deployment.lock.20260707T080000Z.1234.info" "${FAKE_LFTP_LOG}"
  grep -q "quote RMD .lftp-deployment.lock" "${FAKE_LFTP_LOG}"
}

@test "release_lock_safely: no-op when lock_path is empty" {
  rm -f "${FAKE_LFTP_LOG}"
  run release_lock_safely "ftp://example.test" "" "" "ftptest"
  [ "$status" -eq 0 ]
  [ ! -s "${FAKE_LFTP_LOG}" ]
}

# ----------------------------------------------------------------------------
# run_lftp_lock_release — backward-compat shim
# ----------------------------------------------------------------------------

@test "run_lftp_lock_release: no-op when lock path is empty" {
  run run_lftp_lock_release "ftp://nonexistent.invalid" \
                            "/tmp/does-not-exist-netrc" \
                            "" "" "ftptest"
  [ "$status" -eq 0 ]
  [ ! -s "${FAKE_LFTP_LOG}" ]
}

@test "run_lftp_lock_release: no-op when netrc file is missing" {
  rm -f "${FAKE_LFTP_LOG}"
  run run_lftp_lock_release "ftp://nonexistent.invalid" \
                            "/tmp/does-not-exist-netrc" \
                            ".lftp-deployment.lock" "" "ftptest"
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
                            ".lftp-deployment.lock.20260707T080000Z.1234.info" \
                            "ftptest"
  [ "$status" -eq 0 ]
  grep -q "quote RMD .lftp-deployment.lock" "${FAKE_LFTP_LOG}"
  grep -q "quote DELE .lftp-deployment.lock.20260707T080000Z.1234.info" "${FAKE_LFTP_LOG}"
  # v2.11.x (#132): URL must carry the embedded user.
  grep -q "ftp://ftptest@example.test" "${FAKE_LFTP_LOG}"
}