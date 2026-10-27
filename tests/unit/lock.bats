#!/usr/bin/env bats
# tests/unit/lock.bats — unit tests for the concurrency-lock
# functions in lib.sh.
#
# The lock is driven by shell helpers (acquire_lock_with_recovery,
# release_lock_safely) so the stale-lock auto-recovery can do its
# LIST/parse/DELE/RMD sequence without fighting lftp's flow-control
# primitives.
#
# Coverage matrix:
#   * _lock_sentinel_name — pure: TIMESTAMP + PID -> filename.
#   * _lock_age_seconds — pure: STAMP_NOW - STAMP_THEN in seconds.
#   * _lock_parse_sentinel_listing — pure: extract first sentinel
#     filename from an FTP LIST output.
#   * acquire_lock_with_recovery — uses lftp; tested via fake lftp.
#   * release_lock_safely — uses lftp; tested via fake lftp.

setup() {
  # No `set +e` here (FND-0080): bats runs the body under `set -eET`,
  # and that errexit is what fails a test on ANY failing command, not
  # only the last one. A call that is expected to fail is wrapped in
  # `run` or `|| rc=$?`. bats does not enable nounset, so no `set +u`.
  # LIB_SRC overrides the lib.sh under test (used to prove the FND-0003
  # tests fail on the pre-fix lib.sh).
  LIB="${LIB_SRC:-${BATS_TEST_DIRNAME}/../../lib.sh}"
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
# bats runs every test body with `set -e`, and the function under
# test legitimately returns 1 on the timeout path, so we wrap each
# call in `|| rc=$?`. Inside that `||` list bash ignores errexit,
# including the `set -e` the function runs itself; the function
# always leaves `set -e` on when it returns, so every assertion
# after the call gates the test.
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
  grep -q "put .* -o .lftp-deployment.lock/.lftp-deployment.lock.*.info" "${FAKE_LFTP_LOG}"
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

# #250: a sentinel is only stale once it is older than 6 h. Since the
# FND-0003 heartbeat the holder renames its sentinel to a fresh stamp
# before every mirror attempt, so "stale" means no attempt has started
# for 6 h. An older-than-timeout but younger-than-6-h sentinel belongs
# to a live run (a long mirror) and must be kept.
_install_scripted_lftp() {
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
}

_stamp_seconds_ago() {
  date -u -d "@$(( $(date +%s) - $1 ))" +%Y%m%dT%H%M%SZ
}

@test "acquire_lock_with_recovery: sentinel older than timeout but younger than 6 h is a live holder (issue #250)" {
  export FAKE_LFTP_SCRIPT="${BATS_TEST_TMPDIR}/fake-lftp-script.txt"
  live_stamp=$(_stamp_seconds_ago 600)
  printf 'exit 1\necho .lftp-deployment.lock.%s.7.info\n' "${live_stamp}" > "${FAKE_LFTP_SCRIPT}"
  _install_scripted_lftp

  unset ACQUIRED_LOCK_SENTINEL
  acquire_lock_with_recovery \
    "ftp://example.test" ".lftp-deployment.lock" "1" "1" "ftptest" \
    2> "${BATS_TEST_TMPDIR}/stderr" || rc=$?
  [ "${rc:-0}" -eq 1 ]
  if grep -qE "quote (DELE|RMD)|put " "${FAKE_LFTP_LOG}"; then
    echo "a 600 s old sentinel belongs to a live run; it must not be taken over"; cat "${FAKE_LFTP_LOG}"; false
  fi
  # The sentinel is a dot-file; vsftpd only lists it for `LIST -a`.
  # FND-0004: the waiter lists the lock dir itself, where the sentinel lives.
  grep -q "set ftp:list-options -a; cls -la .lftp-deployment.lock;" "${FAKE_LFTP_LOG}"
  [ -z "${ACQUIRED_LOCK_SENTINEL:-}" ]
}

@test "acquire_lock_with_recovery: sentinel older than 6 h is stale and taken over (issue #250)" {
  export FAKE_LFTP_SCRIPT="${BATS_TEST_TMPDIR}/fake-lftp-script.txt"
  stale_stamp=$(_stamp_seconds_ago 21660)
  printf 'exit 1\necho .lftp-deployment.lock.%s.7.info\nexit 0\nexit 0\nexit 0\n' "${stale_stamp}" > "${FAKE_LFTP_SCRIPT}"
  _install_scripted_lftp

  unset ACQUIRED_LOCK_SENTINEL
  acquire_lock_with_recovery \
    "ftp://example.test" ".lftp-deployment.lock" "5" "1" "ftptest" || rc=$?
  [ "${rc:-0}" -eq 0 ]
  grep -q "quote DELE .lftp-deployment.lock/.lftp-deployment.lock.${stale_stamp}.7.info" "${FAKE_LFTP_LOG}"
  grep -q "quote RMD .lftp-deployment.lock" "${FAKE_LFTP_LOG}"
  [ -n "${ACQUIRED_LOCK_SENTINEL:-}" ]
}

@test "acquire_lock_with_recovery: on timeout, names the holder's sentinel and how to clear it (issue #250)" {
  export FAKE_LFTP_SCRIPT="${BATS_TEST_TMPDIR}/fake-lftp-script.txt"
  live_stamp=$(_stamp_seconds_ago 600)
  printf 'exit 1\necho .lftp-deployment.lock.%s.7.info\n' "${live_stamp}" > "${FAKE_LFTP_SCRIPT}"
  _install_scripted_lftp

  unset ACQUIRED_LOCK_SENTINEL
  acquire_lock_with_recovery \
    "ftp://example.test" ".lftp-deployment.lock" "1" "1" "ftptest" \
    2> "${BATS_TEST_TMPDIR}/stderr" || rc=$?
  [ "${rc:-0}" -eq 1 ]
  grep -qE "^ERROR: lock \.lftp-deployment\.lock is held by \.lftp-deployment\.lock\.${live_stamp}\.7\.info \(age 6[0-9]{2} s\); if that run is gone, delete \.lftp-deployment\.lock/\.lftp-deployment\.lock\.${live_stamp}\.7\.info and then \.lftp-deployment\.lock on the server\$" "${BATS_TEST_TMPDIR}/stderr" \
    || { echo "stderr:"; cat "${BATS_TEST_TMPDIR}/stderr"; false; }
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
  rc=0
  _lock_age_seconds "2026ab07T080000Z" "20260707T080000Z" >/dev/null 2>&1 || rc=$?
  [ "${rc}" -ne 0 ]
}

# F2 audit (#268 + #173, paired): when LIST returns an EMPTY
# listing (no sentinels, no other files) and the lock dir has been
# sentinel-less for LOCK_EMPTY_GRACE seconds (FND-0042; forced to 0
# here), the recovery branch must STILL RMD the lock dir and take
# over (the "previous-holder-died-between-MKD-and-PUT" race). This
# is the regression guard for the `|| _alwr_stale_files=""` fallback:
# without it, grep's exit 1 (no match in an
# empty listing) propagates through `set -o pipefail` and `set
# -e` and aborts the function before recovery can run.
@test "acquire_lock_with_recovery: MKD 550 + empty listing past LOCK_EMPTY_GRACE -> RMDs lock dir (no sentinel to DELE), takes over" {
  LOCK_EMPTY_GRACE=0
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

# ----------------------------------------------------------------------------
# FND-0042 / FND-0004 helpers: a virtual clock and a path-aware fake lftp.
#
# The lock loop reads time through `date +%s` and waits through `sleep`.
# _install_lock_fakes replaces both with stubs driven by one counter file
# (FAKE_CLOCK), so the grace period can be exercised in milliseconds and
# deterministically: `sleep N` advances the clock by N, and every lftp call
# advances it by FAKE_LFTP_STEP (default 1) so a loop that never sleeps
# still terminates. Other `date` invocations (the sentinel stamp) go to the
# real date.
#
# The fake lftp logs every call, then:
#   * `mkdir`: exit 0 once a RMD has been seen (or FAKE_MKD_OK=1), else 1;
#   * `quote RMD` (any script containing it): records the RMD, exit 0;
#   * `cls -la <target>;` (the waiter's LIST, never a recovery script):
#     numbers the call ($n, 1-based, counted in FAKE_LIST_N) and sources
#     $FAKE_LIST_SH, which prints the listing for $t (target) / $n;
#   * anything else (the sentinel PUT): exit 0.
# The tests that use it end their assertions in `|| exit 1`. They were
# written while setup() still ran `set +e` (FND-0080); errexit now gates
# every command, so the `|| exit 1` is redundant but harmless.
# ----------------------------------------------------------------------------

_install_lock_fakes() {
  export FAKE_CLOCK="${BATS_TEST_TMPDIR}/clock"
  export FAKE_LIST_N="${BATS_TEST_TMPDIR}/list-n"
  export FAKE_LIST_SH="${BATS_TEST_TMPDIR}/list.sh"
  export FAKE_RMD_DONE="${BATS_TEST_TMPDIR}/rmd-done"
  export FAKE_REAL_DATE
  FAKE_REAL_DATE=$(command -v date)
  rm -f "${FAKE_RMD_DONE}" "${FAKE_LIST_N}"
  echo 1000000 > "${FAKE_CLOCK}"
  : > "${FAKE_LIST_SH}"
  cat > "${BATS_TEST_TMPDIR}/bin/date" <<'FAKE'
#!/bin/sh
if [ "$*" = "+%s" ]; then cat "${FAKE_CLOCK}"; exit 0; fi
exec "${FAKE_REAL_DATE}" "$@"
FAKE
  cat > "${BATS_TEST_TMPDIR}/bin/sleep" <<'FAKE'
#!/bin/sh
echo $(( $(cat "${FAKE_CLOCK}") + $1 )) > "${FAKE_CLOCK}"
FAKE
  cat > "${BATS_TEST_TMPDIR}/bin/lftp" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >> "${FAKE_LFTP_LOG}"
echo $(( $(cat "${FAKE_CLOCK}") + ${FAKE_LFTP_STEP:-1} )) > "${FAKE_CLOCK}"
case "$*" in
  *"quote RMD"*) : > "${FAKE_RMD_DONE}"; exit 0 ;;
  *"mkdir "*)
    if [ -e "${FAKE_RMD_DONE}" ] || [ "${FAKE_MKD_OK:-0}" = 1 ]; then exit 0; fi
    exit 1 ;;
  *"cls -la "*)
    n=$(( $(cat "${FAKE_LIST_N}" 2>/dev/null || echo 0) + 1 ))
    echo "${n}" > "${FAKE_LIST_N}"
    t=$(printf '%s' "$*" | sed -n 's/.*cls -la \([^;]*\);.*/\1/p')
    . "${FAKE_LIST_SH}"
    exit 0 ;;
esac
exit 0
FAKE
  chmod +x "${BATS_TEST_TMPDIR}/bin/date" "${BATS_TEST_TMPDIR}/bin/sleep" "${BATS_TEST_TMPDIR}/bin/lftp"
}

# FND-0042: a lock dir with no sentinel may belong to a live holder that is
# between its MKD and its sentinel PUT. With the default LOCK_EMPTY_GRACE a
# waiter must keep waiting (and lose at its own timeout) instead of RMDing it.
@test "acquire_lock_with_recovery: FND-0042: empty listing within the default LOCK_EMPTY_GRACE is never RMDd" {
  _install_lock_fakes
  # Every LIST is empty: the dir is permanently sentinel-less.
  : > "${FAKE_LIST_SH}"
  [ "${LOCK_EMPTY_GRACE}" -ge 60 ] || exit 1
  unset ACQUIRED_LOCK_SENTINEL
  rc=0
  # 30 s timeout, 5 s poll: well inside the 120 s default grace.
  acquire_lock_with_recovery \
    "ftp://example.test" ".lftp-deployment.lock" "30" "5" "ftptest" || rc=$?
  [ "${rc}" -eq 1 ] || exit 1
  # The waiter really polled (otherwise the assertions below are vacuous).
  [ "$(cat "${FAKE_LIST_N}")" -ge 3 ] || exit 1
  if grep -q "quote RMD" "${FAKE_LFTP_LOG}"; then
    echo "RMD issued within the grace period"; cat "${FAKE_LFTP_LOG}"; exit 1
  fi
  if grep -q "quote DELE" "${FAKE_LFTP_LOG}"; then
    echo "DELE issued within the grace period"; cat "${FAKE_LFTP_LOG}"; exit 1
  fi
  if grep -q "put " "${FAKE_LFTP_LOG}"; then
    echo "lock must not be acquired within the grace period"; cat "${FAKE_LFTP_LOG}"; exit 1
  fi
  [ -z "${ACQUIRED_LOCK_SENTINEL:-}" ] || exit 1
}

# FND-0042: the grace clock restarts whenever a sentinel is seen. Timeline
# (virtual seconds; per iteration: mkdir +1, cls +1, sleep +5 = 7 s) with
# LOCK_EMPTY_GRACE=20: LIST 1-3 empty, LIST 4 shows a fresh sentinel, LIST
# 5-8 empty. If the clock were NOT reset by LIST 4, the dir would count as
# sentinel-less since LIST 1 and be taken over at LIST 5 (28 s >= 20 s).
# With the reset, the empty period restarts at LIST 5 and ends at LIST 8
# (21 s >= 20 s): the first RMD must come after exactly 8 waiter LISTs.
@test "acquire_lock_with_recovery: FND-0042: grace clock resets when a sentinel is seen between empty polls" {
  _install_lock_fakes
  LOCK_EMPTY_GRACE=20
  fresh_stamp=$(date -u +%Y%m%dT%H%M%SZ)
  cat > "${FAKE_LIST_SH}" <<LIST
if [ "\${n}" -eq 4 ]; then echo ".lftp-deployment.lock.${fresh_stamp}.1.info"; fi
LIST
  unset ACQUIRED_LOCK_SENTINEL
  rc=0
  acquire_lock_with_recovery \
    "ftp://example.test" ".lftp-deployment.lock" "200" "5" "ftptest" || rc=$?
  [ "${rc}" -eq 0 ] || exit 1
  # The fresh sentinel is a live holder: it is never DELEd.
  if grep -q "quote DELE" "${FAKE_LFTP_LOG}"; then
    echo "a fresh sentinel must not be DELEd"; cat "${FAKE_LFTP_LOG}"; exit 1
  fi
  grep -q "quote RMD .lftp-deployment.lock" "${FAKE_LFTP_LOG}" || exit 1
  # Waiter LISTs (the "cls -la <dir>;" lines) logged before the first RMD.
  lists_before_rmd=$(sed '/quote RMD/q' "${FAKE_LFTP_LOG}" | grep -c "set ftp:list-options -a; cls -la [^;]*; quit;") || true
  if [ "${lists_before_rmd}" -ne 8 ]; then
    echo "expected RMD after exactly 8 waiter LISTs, got ${lists_before_rmd}"; cat "${FAKE_LFTP_LOG}"; exit 1
  fi
  [ -n "${ACQUIRED_LOCK_SENTINEL:-}" ] || exit 1
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

# FND-0004: the sentinel is written INSIDE the lock dir, so that its
# lifetime is tied to concurrency_lock_path.
@test "acquire_lock_with_recovery: FND-0004: sentinel PUT targets <lock_path>/<sentinel>, not the login dir" {
  _install_lock_fakes
  export FAKE_MKD_OK=1
  unset ACQUIRED_LOCK_SENTINEL
  rc=0
  acquire_lock_with_recovery \
    "ftp://example.test" "deploy/lock" "5" "1" "ftptest" || rc=$?
  unset FAKE_MKD_OK
  [ "${rc}" -eq 0 ] || exit 1
  [ -n "${ACQUIRED_LOCK_SENTINEL:-}" ] || exit 1
  grep -qF -- "-o deploy/lock/${ACQUIRED_LOCK_SENTINEL}; quit;" "${FAKE_LFTP_LOG}" || {
    echo "sentinel PUT does not target deploy/lock/"; cat "${FAKE_LFTP_LOG}"; exit 1
  }
  # No PUT to the login dir (the old location).
  if grep -qF -- "-o ${ACQUIRED_LOCK_SENTINEL};" "${FAKE_LFTP_LOG}"; then
    echo "sentinel PUT still targets the login dir"; cat "${FAKE_LFTP_LOG}"; exit 1
  fi
}

# FND-0004: the waiter lists the lock dir and only judges sentinels found
# there. A stale sentinel in the login dir (old root-level location) or in
# another lock dir must not make it take over a live lock. The fake serves a
# 7-day-old sentinel for `.` and for `other/lock`, and a fresh one (a live
# holder) only for `deploy/lock`.
@test "acquire_lock_with_recovery: FND-0004: waiter lists <lock_path> only; stale sentinels elsewhere never trigger takeover" {
  # Stamps first: _stamp_seconds_ago reads `date +%s`, which the fakes stub.
  fresh_stamp=$(date -u +%Y%m%dT%H%M%SZ)
  old_stamp=$(_stamp_seconds_ago 604800)
  _install_lock_fakes
  cat > "${FAKE_LIST_SH}" <<LIST
case "\${t}" in
  deploy/lock) echo ".lftp-deployment.lock.${fresh_stamp}.5.info" ;;
  *) echo ".lftp-deployment.lock.${old_stamp}.9.info" ;;
esac
LIST
  unset ACQUIRED_LOCK_SENTINEL
  rc=0
  acquire_lock_with_recovery \
    "ftp://example.test" "deploy/lock" "5" "1" "ftptest" \
    2> "${BATS_TEST_TMPDIR}/stderr" || rc=$?
  [ "${rc}" -eq 1 ] || { cat "${FAKE_LFTP_LOG}"; exit 1; }
  # It listed the lock dir at least once ...
  grep -qF "set ftp:list-options -a; cls -la deploy/lock; quit;" "${FAKE_LFTP_LOG}" || exit 1
  # ... and never listed anything else (`.` or another lock path).
  other=$(grep -F "cls -la" "${FAKE_LFTP_LOG}" | grep -vF "cls -la deploy/lock;" || true)
  if [ -n "${other}" ]; then
    echo "waiter listed something other than the lock dir:"; echo "${other}"; exit 1
  fi
  # The live holder in deploy/lock was respected: no DELE, no RMD, no PUT.
  if grep -qE "quote (DELE|RMD)|put " "${FAKE_LFTP_LOG}"; then
    echo "stale sentinel elsewhere triggered a takeover"; cat "${FAKE_LFTP_LOG}"; exit 1
  fi
  # The reported holder is the one inside the lock dir.
  grep -qF "is held by .lftp-deployment.lock.${fresh_stamp}.5.info" "${BATS_TEST_TMPDIR}/stderr" || exit 1
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

# FND-0014: the user is percent-encoded in the userinfo. The `|| exit 1`
# dates from when setup() ran `set +e` (FND-0080); errexit now gates
# every command, so it is redundant but harmless.
@test "rewrite_lftp_url: cPanel user name@domain -> %40 (one userinfo token)" {
  result=$(rewrite_lftp_url "ftp://host:21" "deploy@example.com")
  [ "${result}" = "ftp://deploy%40example.com@host:21" ] || exit 1
}

@test "rewrite_lftp_url: ':' in user -> %3A (no embedded-password URL, #195)" {
  result=$(rewrite_lftp_url "ftps://host:990" "a:b")
  [ "${result}" = "ftps://a%3Ab@host:990" ] || exit 1
}

@test "rewrite_lftp_url: '/' in user -> %2F" {
  result=$(rewrite_lftp_url "ftp://host" "a/b")
  [ "${result}" = "ftp://a%2Fb@host" ] || exit 1
}

@test "rewrite_lftp_url: '%' in user is encoded first (no double encoding)" {
  result=$(rewrite_lftp_url "ftp://[::1]:21" "a%40b@c:d/e")
  [ "${result}" = "ftp://a%2540b%40c%3Ad%2Fe@[::1]:21" ] || exit 1
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
  grep -q "quote DELE .lftp-deployment.lock/.lftp-deployment.lock.20260707T080000Z.1234.info" "${FAKE_LFTP_LOG}"
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
  grep -q "quote DELE .lftp-deployment.lock/.lftp-deployment.lock.20260707T080000Z.1234.info" "${FAKE_LFTP_LOG}"
  grep -q "quote RMD .lftp-deployment.lock" "${FAKE_LFTP_LOG}"
}

# FND-0004: the sentinel lives inside the lock dir, so release must DELE it
# there BEFORE the RMD (an RMD of a non-empty dir fails). One lftp script,
# DELE first, both with the lock path.
@test "release_lock_safely: FND-0004: DELEs <lock_path>/<sentinel> before RMD" {
  rm -f "${FAKE_LFTP_LOG}"
  s=".lftp-deployment.lock.20260707T080000Z.1234.info"
  run release_lock_safely "ftp://example.test" "deploy/lock" "${s}" "ftptest"
  [ "$status" -eq 0 ] || exit 1
  [ "$(wc -l < "${FAKE_LFTP_LOG}")" -eq 1 ] || exit 1
  grep -qF "quote DELE deploy/lock/${s}; quote RMD deploy/lock; quit;" "${FAKE_LFTP_LOG}" || {
    echo "release script wrong:"; cat "${FAKE_LFTP_LOG}"; exit 1
  }
  # No login-dir DELE of the bare sentinel name.
  if grep -qF "quote DELE ${s}" "${FAKE_LFTP_LOG}"; then
    echo "bare (login dir) DELE present"; cat "${FAKE_LFTP_LOG}"; exit 1
  fi
}

# ----------------------------------------------------------------------------
# FND-0003: lock heartbeat. refresh_lock_sentinel renames the holder's
# sentinel (lftp `mv` = RNFR/RNTO) to a fresh stamp before every mirror
# attempt. A fake `date` (stamp read from FAKE_DATE_FILE) makes the new
# names deterministic and independent of second boundaries.
# ----------------------------------------------------------------------------

_install_fake_date() {
  export FAKE_DATE_FILE="${BATS_TEST_TMPDIR}/fake-date.stamp"
  printf '%s\n' "$1" > "${FAKE_DATE_FILE}"
  cat > "${BATS_TEST_TMPDIR}/bin/date" <<'FAKE'
#!/bin/sh
cat "${FAKE_DATE_FILE}"
FAKE
  chmod +x "${BATS_TEST_TMPDIR}/bin/date"
}

FND3_LOCK=".lftp-deployment.lock"
FND3_OLD=".lftp-deployment.lock.20260101T000000Z.1234.info"

@test "refresh_lock_sentinel: FND-0003: success renames old -> new (same PID scheme, fresh stamp), switches the name, clears TRIED" {
  _install_fake_date "20260601T120000Z"
  export FAKE_LFTP_RC=0
  ACQUIRED_LOCK_SENTINEL="${FND3_OLD}"
  ACQUIRED_LOCK_SENTINEL_TRIED="stale-name-from-earlier"
  refresh_lock_sentinel "ftp://example.test" "${FND3_LOCK}" "ftptest" > "${BATS_TEST_TMPDIR}/out" || exit 1
  new=$(_lock_sentinel_name "20260601T120000Z" "$$")
  [ "$(wc -l < "${FAKE_LFTP_LOG}")" -eq 1 ] || { cat "${FAKE_LFTP_LOG}"; exit 1; }
  grep -qF "mv ${FND3_LOCK}/${FND3_OLD} ${FND3_LOCK}/${new}; quit;" "${FAKE_LFTP_LOG}" || { cat "${FAKE_LFTP_LOG}"; exit 1; }
  grep -qF "ftp://ftptest@example.test" "${FAKE_LFTP_LOG}" || exit 1
  printf '%s\n' "${new}" | grep -Eq '^\.lftp-deployment\.lock\.[0-9]{8}T[0-9]{6}Z\.[0-9]+\.info$' || exit 1
  [ "${ACQUIRED_LOCK_SENTINEL}" = "${new}" ] || exit 1
  [ -z "${ACQUIRED_LOCK_SENTINEL_TRIED}" ] || exit 1
  [ ! -s "${BATS_TEST_TMPDIR}/out" ] || { cat "${BATS_TEST_TMPDIR}/out"; exit 1; }
}

@test "refresh_lock_sentinel: FND-0003: lftp failure returns 0, warns, keeps the old name, records the attempted name in TRIED" {
  _install_fake_date "20260601T120000Z"
  export FAKE_LFTP_RC=5
  ACQUIRED_LOCK_SENTINEL="${FND3_OLD}"
  ACQUIRED_LOCK_SENTINEL_TRIED=""
  rc=0
  refresh_lock_sentinel "ftp://example.test" "${FND3_LOCK}" "ftptest" > "${BATS_TEST_TMPDIR}/out" || rc=$?
  new=$(_lock_sentinel_name "20260601T120000Z" "$$")
  [ "${rc}" -eq 0 ] || exit 1
  grep -qF "::warning::concurrency lock: could not refresh the sentinel ${FND3_LOCK}/${FND3_OLD} (lftp exit 5)" "${BATS_TEST_TMPDIR}/out" || { cat "${BATS_TEST_TMPDIR}/out"; exit 1; }
  [ "${ACQUIRED_LOCK_SENTINEL}" = "${FND3_OLD}" ] || exit 1
  [ "${ACQUIRED_LOCK_SENTINEL_TRIED}" = "${new}" ] || { echo "TRIED=${ACQUIRED_LOCK_SENTINEL_TRIED}"; exit 1; }
}

@test "refresh_lock_sentinel: FND-0003: a new name equal to the current one (same second) makes no lftp call" {
  _install_fake_date "20260601T120000Z"
  ACQUIRED_LOCK_SENTINEL=$(_lock_sentinel_name "20260601T120000Z" "$$")
  ACQUIRED_LOCK_SENTINEL_TRIED=""
  before="${ACQUIRED_LOCK_SENTINEL}"
  refresh_lock_sentinel "ftp://example.test" "${FND3_LOCK}" "ftptest" > "${BATS_TEST_TMPDIR}/out" || exit 1
  [ ! -e "${FAKE_LFTP_LOG}" ] || { cat "${FAKE_LFTP_LOG}"; exit 1; }
  [ "${ACQUIRED_LOCK_SENTINEL}" = "${before}" ] || exit 1
  [ -z "${ACQUIRED_LOCK_SENTINEL_TRIED}" ] || exit 1
}

@test "refresh_lock_sentinel: FND-0003: no sentinel held (or empty lock path) makes no lftp call" {
  _install_fake_date "20260601T120000Z"
  ACQUIRED_LOCK_SENTINEL=""
  ACQUIRED_LOCK_SENTINEL_TRIED=""
  refresh_lock_sentinel "ftp://example.test" "${FND3_LOCK}" "ftptest" > "${BATS_TEST_TMPDIR}/out" || exit 1
  unset ACQUIRED_LOCK_SENTINEL
  refresh_lock_sentinel "ftp://example.test" "${FND3_LOCK}" "ftptest" > "${BATS_TEST_TMPDIR}/out" || exit 1
  ACQUIRED_LOCK_SENTINEL="${FND3_OLD}"
  refresh_lock_sentinel "ftp://example.test" "" "ftptest" > "${BATS_TEST_TMPDIR}/out" || exit 1
  [ ! -e "${FAKE_LFTP_LOG}" ] || { cat "${FAKE_LFTP_LOG}"; exit 1; }
  [ -z "${ACQUIRED_LOCK_SENTINEL_TRIED}" ] || exit 1
}

@test "release_lock_safely: FND-0003: after failed refreshes DELEs the current sentinel AND every TRIED name, then RMDs" {
  export FAKE_LFTP_RC=5
  ACQUIRED_LOCK_SENTINEL="${FND3_OLD}"
  ACQUIRED_LOCK_SENTINEL_TRIED=""
  _install_fake_date "20260601T120000Z"
  refresh_lock_sentinel "ftp://example.test" "${FND3_LOCK}" "ftptest" > "${BATS_TEST_TMPDIR}/out" || exit 1
  printf '%s\n' "20260601T130000Z" > "${FAKE_DATE_FILE}"
  refresh_lock_sentinel "ftp://example.test" "${FND3_LOCK}" "ftptest" > "${BATS_TEST_TMPDIR}/out" || exit 1
  t1=$(_lock_sentinel_name "20260601T120000Z" "$$")
  t2=$(_lock_sentinel_name "20260601T130000Z" "$$")
  [ "${ACQUIRED_LOCK_SENTINEL_TRIED}" = "${t1} ${t2}" ] || { echo "TRIED=${ACQUIRED_LOCK_SENTINEL_TRIED}"; exit 1; }
  rm -f "${FAKE_LFTP_LOG}"
  export FAKE_LFTP_RC=0
  release_lock_safely "ftp://example.test" "${FND3_LOCK}" "${ACQUIRED_LOCK_SENTINEL}" "ftptest" || exit 1
  [ "$(wc -l < "${FAKE_LFTP_LOG}")" -eq 1 ] || { cat "${FAKE_LFTP_LOG}"; exit 1; }
  grep -qF "quote DELE ${FND3_LOCK}/${FND3_OLD}; quote DELE ${FND3_LOCK}/${t1}; quote DELE ${FND3_LOCK}/${t2}; quote RMD ${FND3_LOCK}; quit;" "${FAKE_LFTP_LOG}" || {
    echo "release script wrong:"; cat "${FAKE_LFTP_LOG}"; exit 1
  }
}

@test "release_lock_safely: FND-0003: after a failed and then a successful refresh the TRIED list is empty and release is the plain DELE + RMD" {
  ACQUIRED_LOCK_SENTINEL="${FND3_OLD}"
  ACQUIRED_LOCK_SENTINEL_TRIED=""
  _install_fake_date "20260601T120000Z"
  export FAKE_LFTP_RC=5
  refresh_lock_sentinel "ftp://example.test" "${FND3_LOCK}" "ftptest" > "${BATS_TEST_TMPDIR}/out" || exit 1
  printf '%s\n' "20260601T130000Z" > "${FAKE_DATE_FILE}"
  export FAKE_LFTP_RC=0
  refresh_lock_sentinel "ftp://example.test" "${FND3_LOCK}" "ftptest" > "${BATS_TEST_TMPDIR}/out" || exit 1
  new=$(_lock_sentinel_name "20260601T130000Z" "$$")
  [ "${ACQUIRED_LOCK_SENTINEL}" = "${new}" ] || exit 1
  [ -z "${ACQUIRED_LOCK_SENTINEL_TRIED}" ] || exit 1
  rm -f "${FAKE_LFTP_LOG}"
  release_lock_safely "ftp://example.test" "${FND3_LOCK}" "${ACQUIRED_LOCK_SENTINEL}" "ftptest" || exit 1
  grep -qF " quote DELE ${FND3_LOCK}/${new}; quote RMD ${FND3_LOCK}; quit;" "${FAKE_LFTP_LOG}" || {
    echo "release script wrong:"; cat "${FAKE_LFTP_LOG}"; exit 1
  }
}

@test "release_lock_safely: no-op when lock_path is empty" {
  rm -f "${FAKE_LFTP_LOG}"
  run release_lock_safely "ftp://example.test" "" "" "ftptest"
  [ "$status" -eq 0 ]
  [ ! -s "${FAKE_LFTP_LOG}" ]
}

# F2 audit (#312): the mktemp fallback branch in
# acquire_lock_with_recovery used to chmod the body file BEFORE
# the redirect that creates it; the chmod was a no-op on the
# fallback path (the static filename does not exist yet) and
# the file ended up at 0644 — leaking pid / started_at / host
# metadata to the runner's other processes. Post-fix the chmod
# runs AFTER the redirect, so the fallback branch ends at 0600
# regardless of the process umask.
#
# Force the fallback by overriding mktemp to fail; intercept rm
# to capture the body file path so we can stat() its mode after
# the function returns. Same trick as the FAKE_LFTP shim above.
@test "acquire_lock_with_recovery: mktemp fallback branch sets sentinel body mode to 0600 (issue #312)" {
  export FAKE_LFTP_RC="0"

  # mktemp() override: return 1 so the `|| _alwr_sentinel_body="..."`
  # fallback fires with a static name.
  mktemp() { return 1; }

  # rm() override: capture the body file path that the function
  # would otherwise delete. The acquire call uses `rm -f <path>`,
  # so we have to scan all args, not just $1 (which would be -f).
  CAPTURED_BODY_FILE=""
  rm() {
    for _arg in "$@"; do
      case "${_arg}" in
        /tmp/.lftp-lock-body.*)
          CAPTURED_BODY_FILE="${_arg}"
          ;;
      esac
    done
    return 0
  }

  unset INPUT_SERVER INPUT_CONCURRENCY_LOCK_PATH INPUT_CONCURRENCY_LOCK_TIMEOUT INPUT_CONCURRENCY_LOCK_POLL_INTERVAL
  INPUT_SERVER="ftp://example.test"
  INPUT_CONCURRENCY_LOCK_PATH=".lftp-deployment.lock"
  INPUT_CONCURRENCY_LOCK_TIMEOUT="5"
  INPUT_CONCURRENCY_LOCK_POLL_INTERVAL="1"
  unset ACQUIRED_LOCK_SENTINEL
  acquire_lock_with_recovery \
    "ftp://example.test" ".lftp-deployment.lock" "5" "1" "ftptest" || rc=$?
  [ "${rc:-0}" -eq 0 ]

  # The rm override should have captured the body file path.
  [ -n "${CAPTURED_BODY_FILE}" ]
  [ -f "${CAPTURED_BODY_FILE}" ]

  # The whole point: mode MUST be 0600. Pre-fix this would be
  # 0644 on the standard 0022 umask CI default (or 0600 only on
  # systems with a 0077 umask — a non-portable coincidence).
  actual_mode=$(stat -c '%a' "${CAPTURED_BODY_FILE}")
  [ "${actual_mode}" = "600" ]

  # Clean up the body file we protected from the rm call.
  command rm -f "${CAPTURED_BODY_FILE}" 2>/dev/null || true
}
# ----------------------------------------------------------------------------
# FND-0043 / FND-0083: sentinel-PUT failure must neither loop without a pause
# nor be reported as a held lock; the takeover path also backs off.
#
# _install_put_fakes builds on _install_lock_fakes (virtual clock, `date`,
# `sleep`) and replaces `lftp` and `sleep` so every call is recorded in one
# ordered event log, FAKE_EVENTS, one line per event:
#   "<clock> mkdir|put|cleanup|recover|list"   (an lftp call)
#   "<clock> sleep <n>"                         (a sleep, before advancing)
# `cleanup` = the DELE+RMD script after a failed PUT; `recover` = the stale
# takeover script (it starts with `cls -la .`). Each lftp call advances the
# clock by 1, so a loop without sleeps still ends at its deadline.
# Behaviour knobs (env):
#   FAKE_PUT_FAIL=1       every sentinel PUT fails
#   FAKE_MKD_OK_UNTIL=N   mkdir calls 1..N succeed, later ones fail
#                         (default: all succeed)
#   FAKE_MKD_AFTER_RMD=1  mkdir fails until an RMD was seen, then succeeds
# After FAKE_MAX_CALLS lftp calls the fake kills FAKE_KILL_PID, so a loop that
# never ends (the FND-0043 bug with timeout "0") fails the test instead of
# hanging it. _run_lock runs the function in a subshell for that reason.
# ----------------------------------------------------------------------------

_install_put_fakes() {
  _install_lock_fakes
  export FAKE_EVENTS="${BATS_TEST_TMPDIR}/events"
  export FAKE_CALL_N="${BATS_TEST_TMPDIR}/call-n"
  export FAKE_MKD_N="${BATS_TEST_TMPDIR}/mkd-n"
  export FAKE_MAX_CALLS=40
  : > "${FAKE_EVENTS}"
  rm -f "${FAKE_CALL_N}" "${FAKE_MKD_N}"
  cat > "${BATS_TEST_TMPDIR}/bin/sleep" <<'FAKE'
#!/bin/sh
echo "$(cat "${FAKE_CLOCK}") sleep $1" >> "${FAKE_EVENTS}"
echo $(( $(cat "${FAKE_CLOCK}") + $1 )) > "${FAKE_CLOCK}"
FAKE
  cat > "${BATS_TEST_TMPDIR}/bin/lftp" <<'FAKE'
#!/bin/sh
printf '%s\n' "$*" >> "${FAKE_LFTP_LOG}"
n=$(( $(cat "${FAKE_CALL_N}" 2>/dev/null || echo 0) + 1 ))
echo "${n}" > "${FAKE_CALL_N}"
if [ "${n}" -gt "${FAKE_MAX_CALLS}" ]; then
  echo "runaway loop: more than ${FAKE_MAX_CALLS} lftp calls" >&2
  kill -KILL "${FAKE_KILL_PID}"
  exit 99
fi
now=$(cat "${FAKE_CLOCK}")
echo $(( now + 1 )) > "${FAKE_CLOCK}"
case "$*" in
  *"put "*)
    echo "${now} put" >> "${FAKE_EVENTS}"
    [ "${FAKE_PUT_FAIL:-0}" = 1 ] && exit 1
    exit 0 ;;
  *"quote RMD"*)
    : > "${FAKE_RMD_DONE}"
    case "$*" in
      *"cls -la ."*) echo "${now} recover" >> "${FAKE_EVENTS}" ;;
      *) echo "${now} cleanup" >> "${FAKE_EVENTS}" ;;
    esac
    exit 0 ;;
  *"mkdir "*)
    echo "${now} mkdir" >> "${FAKE_EVENTS}"
    k=$(( $(cat "${FAKE_MKD_N}" 2>/dev/null || echo 0) + 1 ))
    echo "${k}" > "${FAKE_MKD_N}"
    if [ "${FAKE_MKD_AFTER_RMD:-0}" = 1 ]; then
      [ -e "${FAKE_RMD_DONE}" ] && exit 0
      exit 1
    fi
    [ "${k}" -le "${FAKE_MKD_OK_UNTIL:-1000000}" ] && exit 0
    exit 1 ;;
  *"cls -la "*)
    echo "${now} list" >> "${FAKE_EVENTS}"
    n=$(( $(cat "${FAKE_LIST_N}" 2>/dev/null || echo 0) + 1 ))
    echo "${n}" > "${FAKE_LIST_N}"
    t=$(printf '%s' "$*" | sed -n 's/.*cls -la \([^;]*\);.*/\1/p')
    . "${FAKE_LIST_SH}"
    exit 0 ;;
esac
exit 0
FAKE
  chmod +x "${BATS_TEST_TMPDIR}/bin/sleep" "${BATS_TEST_TMPDIR}/bin/lftp"
}

# _run_lock TIMEOUT POLL: call the function in a subshell (so the runaway
# guard can kill it); sets LOCK_RC, stderr goes to ${LOCK_ERR}.
_run_lock() {
  LOCK_ERR="${BATS_TEST_TMPDIR}/stderr"
  LOCK_RC=0
  (
    FAKE_KILL_PID=${BASHPID}
    export FAKE_KILL_PID
    acquire_lock_with_recovery \
      "ftp://example.test" ".lftp-deployment.lock" "$1" "$2" "ftptest"
  ) 2> "${LOCK_ERR}" || LOCK_RC=$?
}

# _count_events PATTERN: number of FAKE_EVENTS lines matching the ERE.
_count_events() {
  grep -cE "$1" "${FAKE_EVENTS}" || true
}

_dump_lock_debug() {
  echo "rc=${LOCK_RC}"; echo "--- events"; cat "${FAKE_EVENTS}"
  echo "--- stderr"; cat "${LOCK_ERR}"
}

@test "acquire_lock_with_recovery: FND-0043: PUT always fails with timeout 0 -> rc 2 after exactly one MKD/PUT/cleanup cycle, no sleep" {
  _install_put_fakes
  export FAKE_PUT_FAIL=1
  _run_lock 0 5
  _dump_lock_debug
  [ "${LOCK_RC}" -eq 2 ]
  # Exactly 3 lftp calls: mkdir, put, DELE+RMD.
  [ "$(wc -l < "${FAKE_LFTP_LOG}")" -eq 3 ]
  [ "$(_count_events ' mkdir$')" -eq 1 ]
  [ "$(_count_events ' put$')" -eq 1 ]
  [ "$(_count_events ' cleanup$')" -eq 1 ]
  grep -q "quote DELE .lftp-deployment.lock/.lftp-deployment.lock.*quote RMD .lftp-deployment.lock" "${FAKE_LFTP_LOG}"
  # No pause, no listing, no takeover.
  [ "$(_count_events ' sleep ')" -eq 0 ]
  [ "$(_count_events ' (list|recover)$')" -eq 0 ]
  grep -qF "ERROR: lock dir .lftp-deployment.lock was created but the sentinel upload to .lftp-deployment.lock/.lftp-deployment.lock." "${LOCK_ERR}"
  grep -qF "failed; check write permission and quota under concurrency_lock_path" "${LOCK_ERR}"
  if grep -qE "is held by|another deployment" "${LOCK_ERR}"; then
    echo "a PUT failure must not be reported as a held lock"; exit 1
  fi
}

@test "acquire_lock_with_recovery: FND-0043: PUT always fails with a positive timeout -> sleeps after every cleanup, ends rc 2 with the upload error" {
  _install_put_fakes
  export FAKE_PUT_FAIL=1
  # Per round: mkdir +1, put +1, cleanup +1, sleep 3 = 6 virtual seconds.
  # Rounds start at t=0 and t=6 (< 10); the check at t=12 ends the loop.
  _run_lock 10 3
  _dump_lock_debug
  [ "${LOCK_RC}" -eq 2 ]
  [ "$(_count_events ' mkdir$')" -eq 2 ]
  [ "$(_count_events ' cleanup$')" -eq 2 ]
  [ "$(_count_events ' sleep 3$')" -eq 2 ]
  # Every cleanup is followed by a sleep before anything else (the next mkdir).
  awk '
    prev == "cleanup" && $2 != "sleep" { bad = 1 }
    { prev = $2 }
    END { exit bad }
  ' "${FAKE_EVENTS}"
  [ "$(awk '$2 == "cleanup" { getline nxt; split(nxt, a, " "); print a[2] }' "${FAKE_EVENTS}" | sort -u)" = "sleep" ]
  # Never a LIST or a takeover: the lock is not held by anyone.
  [ "$(_count_events ' (list|recover)$')" -eq 0 ]
  grep -qF "was created but the sentinel upload to" "${LOCK_ERR}"
  if grep -qE "is held by|another deployment" "${LOCK_ERR}"; then
    echo "a PUT failure must not be reported as a held lock"; exit 1
  fi
}

@test "acquire_lock_with_recovery: FND-0043: a PUT failure followed by a held MKD reports the held lock (rc 1), not the upload error" {
  fresh_stamp=$(date -u +%Y%m%dT%H%M%SZ)
  _install_put_fakes
  export FAKE_PUT_FAIL=1
  # Round 1: mkdir ok, put fails. From round 2 on mkdir fails (held) and the
  # listing shows a live holder's fresh sentinel.
  export FAKE_MKD_OK_UNTIL=1
  cat > "${FAKE_LIST_SH}" <<LIST
echo ".lftp-deployment.lock.${fresh_stamp}.7.info"
LIST
  _run_lock 10 3
  _dump_lock_debug
  [ "${LOCK_RC}" -eq 1 ]
  [ "$(_count_events ' put$')" -eq 1 ]
  [ "$(_count_events ' list$')" -ge 1 ]
  grep -qF "ERROR: lock .lftp-deployment.lock is held by .lftp-deployment.lock.${fresh_stamp}.7.info" "${LOCK_ERR}"
  if grep -qF "sentinel upload" "${LOCK_ERR}"; then
    echo "the last failure was a held lock, not the PUT"; exit 1
  fi
}

@test "acquire_lock_with_recovery: FND-0043: the takeover path sleeps one poll between the recovery DELE+RMD and the next MKD" {
  old_stamp=$(_stamp_seconds_ago 604800)
  _install_put_fakes
  export FAKE_MKD_AFTER_RMD=1
  cat > "${FAKE_LIST_SH}" <<LIST
echo ".lftp-deployment.lock.${old_stamp}.9.info"
LIST
  _run_lock 60 3
  _dump_lock_debug
  [ "${LOCK_RC}" -eq 0 ]
  [ "$(_count_events ' recover$')" -eq 1 ]
  # recover is directly followed by "sleep 3", then by the next mkdir.
  after=$(awk '$2 == "recover" { for (i = 0; i < 2; i++) { getline l; printf "%s;", l } }' "${FAKE_EVENTS}" \
    | sed -E 's/[0-9]{7} //g')
  [ "${after}" = "sleep 3;mkdir;" ]
}

# FND-0083 (cheap part). Timeline with LOCK_EMPTY_GRACE=20, poll 5: every
# loop is mkdir +1, cls +1, sleep 5 (7 s). The listing is always empty and
# the RMD never removes the dir (mkdir keeps failing). The clock starts at
# the first empty LIST (L1); the 4th LIST is the first one 21 s later, so the
# first takeover is on L4. After it the waiter must time the dir from
# scratch: L5 starts the new clock and the next takeover is on L8, i.e. 4
# LISTs after the first recover. Without the reset the L5 listing already
# exceeds the grace and the second takeover comes right after L5.
@test "acquire_lock_with_recovery: FND-0083: the empty-dir grace clock restarts after our own takeover" {
  _install_put_fakes
  LOCK_EMPTY_GRACE=20
  export FAKE_MKD_OK_UNTIL=0
  : > "${FAKE_LIST_SH}"
  _run_lock 60 5
  _dump_lock_debug
  [ "${LOCK_RC}" -eq 1 ]
  [ "$(_count_events ' recover$')" -ge 2 ]
  # Waiter LISTs between the first and the second recover.
  between=$(awk '$2 == "recover" { n++; next } n == 1 && $2 == "list" { c++ } n == 2 { exit } END { print c + 0 }' "${FAKE_EVENTS}")
  [ "${between}" -eq 4 ]
  # In time: the second recover is >= LOCK_EMPTY_GRACE after the first
  # list that followed the first recover.
  t_list=$(awk '$2 == "recover" { n++; next } n == 1 && $2 == "list" { print $1; exit }' "${FAKE_EVENTS}")
  t_second=$(awk '$2 == "recover" { n++; if (n == 2) { print $1; exit } }' "${FAKE_EVENTS}")
  [ $(( t_second - t_list )) -ge 20 ]
}

# ----------------------------------------------------------------------------
# FND-0043 at the entrypoint level. entrypoint.sh only runs inside the image
# (it sources /app/lib.sh and writes /home/lftp/.netrc), so the test runs a
# scratch copy of it with those two paths rewritten into BATS_TEST_TMPDIR and
# a lib.sh copy whose acquire_lock_with_recovery is replaced by a stub that
# returns $FAKE_ACQ_RC. The real entrypoint code path (validation, netrc, EXIT
# trap, the lock block) executes; no network is involved (the EXIT trap's
# release_lock_safely returns early because no sentinel was acquired).
# ----------------------------------------------------------------------------

_run_entrypoint_with_lock_rc() {
  local root="${BATS_TEST_DIRNAME}/../.."
  local app="${BATS_TEST_TMPDIR}/app"
  mkdir -p "${app}" "${BATS_TEST_TMPDIR}/home/lftp" "${BATS_TEST_TMPDIR}/site"
  cp "${root}/lib.sh" "${app}/lib.sh"
  printf '0.0.0-test\n' > "${app}/VERSION"
  cat >> "${app}/lib.sh" <<'STUB'

acquire_lock_with_recovery() { return "${FAKE_ACQ_RC}"; }
STUB
  sed -e "s#/app/#${app}/#g" -e "s#/home/lftp#${BATS_TEST_TMPDIR}/home/lftp#g" \
    "${root}/entrypoint.sh" > "${app}/entrypoint.sh"
  # bash, not sh: entrypoint.sh needs `set -o pipefail`, which the
  # image's busybox ash has but dash (/bin/sh on ubuntu runners) lacks.
  FAKE_ACQ_RC="$1" \
  INPUT_SERVER="ftp://example.test" INPUT_USER="ftptest" INPUT_PASSWORD="pw" \
  INPUT_LOCAL_DIR="${BATS_TEST_TMPDIR}/site/" INPUT_REMOTE_DIR="./" \
  INPUT_CONCURRENCY_LOCK="true" INPUT_CONCURRENCY_LOCK_TIMEOUT="7" \
    run bash -eu "${app}/entrypoint.sh"
}

@test "entrypoint: FND-0043: lock status 2 (sentinel upload failed) exits 1 without the 'another deployment' line" {
  _run_entrypoint_with_lock_rc 2
  echo "status=${status}"; echo "${output}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"ERROR: could not acquire concurrency lock at .lftp-deployment.lock within 7 seconds"* ]]
  [[ "${output}" != *"another deployment is currently in progress"* ]]
  [[ "${output}" == *'see README "Concurrency / deployment lock"'* ]]
}

@test "entrypoint: FND-0043: lock status 1 (held / timed out) still exits 1 with the 'another deployment' line" {
  _run_entrypoint_with_lock_rc 1
  echo "status=${status}"; echo "${output}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"ERROR: could not acquire concurrency lock at .lftp-deployment.lock within 7 seconds"* ]]
  [[ "${output}" == *"another deployment is currently in progress"* ]]
  [[ "${output}" == *'see README "Concurrency / deployment lock"'* ]]
}

# The status must be captured as `fn ... || LOCK_RC=$?`; `if ! fn` would turn
# status 2 into 1 (the negation) and lose it.
@test "entrypoint: FND-0043: acquire_lock_with_recovery status is captured with '|| LOCK_RC=\$?', not 'if !'" {
  entry="${BATS_TEST_DIRNAME}/../../entrypoint.sh"
  grep -qF '"${INPUT_USER}" || LOCK_RC=$?' "${entry}"
  if grep -Eq '(if|while|until)[[:space:]]+!?[[:space:]]*acquire_lock_with_recovery|!+[[:space:]]*acquire_lock_with_recovery' "${entry}"; then
    echo "acquire_lock_with_recovery is negated or used as a condition"; exit 1
  fi
}

# ----------------------------------------------------------------------------
# FND-0003 at the entrypoint level. A scratch copy of entrypoint.sh (paths
# rewritten into BATS_TEST_TMPDIR, as in the FND-0043 tests above) runs with a
# lib.sh copy whose acquire_lock_with_recovery, run_lftp_once and
# compute_backoff_seconds are stubs that append to one call log, while the
# REAL refresh_lock_sentinel and release_lock_safely run against a fake lftp
# (appending to the same log) and a fake date that advances one second per
# call (so no two refreshes share a stamp). The mirror stub fails on the
# first attempt and succeeds on the second. ENTRYPOINT_SRC overrides the
# entrypoint under test (used to prove the tests fail on the pre-fix one);
# FAKE_MV_FAIL=1 makes the fake lftp fail every `mv`; HB_LOCK overrides
# concurrency_lock.
# ----------------------------------------------------------------------------

_run_entrypoint_heartbeat() {
  local root="${BATS_TEST_DIRNAME}/../.."
  local src="${ENTRYPOINT_SRC:-${root}/entrypoint.sh}"
  local app="${BATS_TEST_TMPDIR}/app"
  mkdir -p "${app}" "${BATS_TEST_TMPDIR}/home/lftp" "${BATS_TEST_TMPDIR}/site"
  cp "${LIB}" "${app}/lib.sh"
  printf '0.0.0-test\n' > "${app}/VERSION"
  cat >> "${app}/lib.sh" <<'STUB'

acquire_lock_with_recovery() {
  printf 'ACQUIRE\n' >> "${CALL_LOG}"
  ACQUIRED_LOCK_SENTINEL=".lftp-deployment.lock.20200101T000000Z.1234.info"
  return 0
}
run_lftp_once() {
  _n=$(cat "${MIRROR_COUNT_FILE}" 2>/dev/null || echo 0)
  _n=$((_n + 1))
  printf '%s\n' "${_n}" > "${MIRROR_COUNT_FILE}"
  printf 'MIRROR %s\n' "${_n}" >> "${CALL_LOG}"
  [ "${_n}" -ge 2 ]
}
compute_backoff_seconds() { echo 0; }
STUB
  sed -e "s#/app/#${app}/#g" -e "s#/home/lftp#${BATS_TEST_TMPDIR}/home/lftp#g" \
    "${src}" > "${app}/entrypoint.sh"

  export CALL_LOG="${BATS_TEST_TMPDIR}/calls.log"
  export MIRROR_COUNT_FILE="${BATS_TEST_TMPDIR}/mirror.count"
  export FAKE_DATE_FILE="${BATS_TEST_TMPDIR}/date.count"
  rm -f "${CALL_LOG}" "${MIRROR_COUNT_FILE}"
  : > "${CALL_LOG}"
  printf '0\n' > "${FAKE_DATE_FILE}"
  cat > "${BATS_TEST_TMPDIR}/bin/date" <<'FAKE'
#!/bin/sh
n=$(cat "${FAKE_DATE_FILE}")
n=$((n + 1))
printf '%s\n' "${n}" > "${FAKE_DATE_FILE}"
printf '20260601T12%04dZ\n' "${n}"
FAKE
  chmod +x "${BATS_TEST_TMPDIR}/bin/date"
  cat > "${BATS_TEST_TMPDIR}/bin/lftp" <<'FAKE'
#!/bin/sh
all="$*"
case "${all}" in
  *" mv "*) printf 'LFTP mv %s\n' "${all#* mv }" >> "${CALL_LOG}"
            if [ -n "${FAKE_MV_FAIL:-}" ]; then exit 5; fi ;;
  *"quote DELE"*) printf 'LFTP release %s\n' "${all#*; quote DELE }" >> "${CALL_LOG}" ;;
  *) printf 'LFTP other %s\n' "${all}" >> "${CALL_LOG}" ;;
esac
exit 0
FAKE
  chmod +x "${BATS_TEST_TMPDIR}/bin/lftp"

  # bash, not sh: see _run_entrypoint_with_lock_rc.
  HOME="${BATS_TEST_TMPDIR}/home" \
  INPUT_SERVER="ftp://example.test" INPUT_USER="ftptest" INPUT_PASSWORD="pw" \
  INPUT_LOCAL_DIR="${BATS_TEST_TMPDIR}/site/" INPUT_REMOTE_DIR="./" \
  INPUT_CONCURRENCY_LOCK="${HB_LOCK:-true}" INPUT_MAX_RETRIES="3" \
    run bash -eu "${app}/entrypoint.sh"
}

_call_kinds() {
  sed -e 's/^\(LFTP [a-z]*\).*/\1/' -e 's/^\(MIRROR\) .*/\1/' "${CALL_LOG}" | tr '\n' ','
}

@test "entrypoint: FND-0003: the sentinel is refreshed before every mirror attempt, in order, and released after (acquire, mv, mirror 1, mv, mirror 2, release)" {
  _run_entrypoint_heartbeat
  echo "status=${status}"; echo "${output}"; cat "${CALL_LOG}"
  [ "${status}" -eq 0 ]
  kinds=$(_call_kinds)
  [ "${kinds}" = "ACQUIRE,LFTP mv,MIRROR,LFTP mv,MIRROR,LFTP release," ] || { echo "order: ${kinds}"; exit 1; }
  # The chain is acquire name -> stamp 1 -> stamp 2: the second mv starts
  # from the name the first one produced, and the release DELEs the last
  # name only (both renames succeeded, so TRIED is empty).
  p=".lftp-deployment.lock"
  old="${p}/.lftp-deployment.lock.20200101T000000Z.1234.info"
  mv1=$(grep '^LFTP mv' "${CALL_LOG}" | sed -n 1p)
  mv2=$(grep '^LFTP mv' "${CALL_LOG}" | sed -n 2p)
  [[ "${mv1}" == "LFTP mv ${old} ${p}/.lftp-deployment.lock.2026"*".info; quit;" ]] || { echo "mv1: ${mv1}"; exit 1; }
  n1=${mv1#"LFTP mv ${old} "}
  n1=${n1%"; quit;"}
  [[ "${mv2}" == "LFTP mv ${n1} ${p}/.lftp-deployment.lock.2026"*".info; quit;" ]] || { echo "mv2: ${mv2} (n1=${n1})"; exit 1; }
  n2=${mv2#"LFTP mv ${n1} "}
  n2=${n2%"; quit;"}
  [ "${n1}" != "${n2}" ] || exit 1
  rel=$(grep '^LFTP release' "${CALL_LOG}")
  [ "${rel}" = "LFTP release ${n2}; quote RMD ${p}; quit;" ] || { echo "release: ${rel}"; exit 1; }
}

@test "entrypoint: FND-0003: a refresh failure during the run only warns; the deploy still succeeds and the release DELEs the TRIED names" {
  FAKE_MV_FAIL=1 _run_entrypoint_heartbeat
  echo "status=${status}"; echo "${output}"; cat "${CALL_LOG}"
  [ "${status}" -eq 0 ]
  n=$(printf '%s\n' "${output}" | grep -c '^::warning::concurrency lock: could not refresh the sentinel')
  [ "${n}" -eq 2 ]
  kinds=$(_call_kinds)
  [ "${kinds}" = "ACQUIRE,LFTP mv,MIRROR,LFTP mv,MIRROR,LFTP release," ] || { echo "order: ${kinds}"; exit 1; }
  # Both renames started from the unchanged old name; the release DELEs the
  # old name and both attempted names, then the RMD.
  p=".lftp-deployment.lock"
  old="${p}/.lftp-deployment.lock.20200101T000000Z.1234.info"
  [ "$(grep -c "^LFTP mv ${old} " "${CALL_LOG}")" -eq 2 ] || exit 1
  rel=$(grep '^LFTP release' "${CALL_LOG}")
  [[ "${rel}" == "LFTP release ${old}; quote DELE ${p}/.lftp-deployment.lock.2026"*".info; quote DELE ${p}/.lftp-deployment.lock.2026"*".info; quote RMD ${p}; quit;" ]] || { echo "release: ${rel}"; exit 1; }
}

@test "entrypoint: FND-0003: concurrency_lock=false makes no refresh and no release call" {
  HB_LOCK=false _run_entrypoint_heartbeat
  echo "status=${status}"; echo "${output}"; cat "${CALL_LOG}"
  [ "${status}" -eq 0 ]
  [ "$(_call_kinds)" = "MIRROR,MIRROR," ]
}

# ----------------------------------------------------------------------------
# FND-0101: ACQUIRED_LOCK_SENTINEL was never initialised, so a value inherited
# from the environment reached release_lock_safely through the EXIT trap after
# a FAILED acquire: it skipped the never-acquired guard (#188), sent
# `quote RMD` for a lock this run never held and pasted the value unvalidated
# into the lftp -e script (`quote DELE <path>/<name>;`), i.e. lftp command
# injection (`!cmd` is lftp's shell escape). The scratch entrypoint below runs
# with a stubbed acquire_lock_with_recovery (returns $FAKE_ACQ_RC, sets no
# sentinel) and the REAL release_lock_safely against a fake lftp that logs
# every -e script, one per line. ENTRYPOINT_SRC points at the entrypoint under
# test (the tests were proven to fail on `git show HEAD:entrypoint.sh`).
# ----------------------------------------------------------------------------

_run_entrypoint_inherited_sentinel() {
  local root="${BATS_TEST_DIRNAME}/../.."
  local src="${ENTRYPOINT_SRC:-${root}/entrypoint.sh}"
  local app="${BATS_TEST_TMPDIR}/app"
  mkdir -p "${app}" "${BATS_TEST_TMPDIR}/home/lftp" "${BATS_TEST_TMPDIR}/site"
  cp "${LIB}" "${app}/lib.sh"
  printf '0.0.0-test\n' > "${app}/VERSION"
  cat >> "${app}/lib.sh" <<'STUB'

acquire_lock_with_recovery() {
  if [ "${FAKE_ACQ_RC}" -eq 0 ]; then
    ACQUIRED_LOCK_SENTINEL=".lftp-deployment.lock.20200101T000000Z.1234.info"
  fi
  return "${FAKE_ACQ_RC}"
}
STUB
  sed -e "s#/app/#${app}/#g" -e "s#/home/lftp#${BATS_TEST_TMPDIR}/home/lftp#g" \
    "${src}" > "${app}/entrypoint.sh"
  export CALL_LOG="${BATS_TEST_TMPDIR}/calls.log"
  : > "${CALL_LOG}"
  cat > "${BATS_TEST_TMPDIR}/bin/lftp" <<'FAKE'
#!/bin/sh
printf 'LFTP %s\n' "$*" >> "${CALL_LOG}"
case " $* " in
  *" mv "*) [ -z "${FAKE_MV_FAIL:-}" ] || exit 5 ;;
esac
exit 0
FAKE
  chmod +x "${BATS_TEST_TMPDIR}/bin/lftp"
  # bash, not sh: see _run_entrypoint_with_lock_rc. timeout: a regression
  # must fail the test, never hang it.
  HOME="${BATS_TEST_TMPDIR}/home" \
  INPUT_SERVER="ftp://example.test" INPUT_USER="ftptest" INPUT_PASSWORD="pw" \
  INPUT_LOCAL_DIR="${BATS_TEST_TMPDIR}/site/" INPUT_REMOTE_DIR="./" \
  INPUT_CONCURRENCY_LOCK="true" INPUT_CONCURRENCY_LOCK_TIMEOUT="0" \
  INPUT_MAX_RETRIES="1" FAKE_ACQ_RC="$1" \
    run timeout 60 bash -eu "${app}/entrypoint.sh"
}

@test "entrypoint: FND-0101: an inherited ACQUIRED_LOCK_SENTINEL(_TRIED) is never released or injected into lftp after a failed acquire" {
  pwned="${BATS_TEST_TMPDIR}/PWNED"
  export ACQUIRED_LOCK_SENTINEL="x; !touch ${pwned}"
  export ACQUIRED_LOCK_SENTINEL_TRIED="inherited-tried-name"
  _run_entrypoint_inherited_sentinel 1
  echo "status=${status}"; echo "${output}"; cat "${CALL_LOG}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"ERROR: could not acquire concurrency lock"* ]]
  # No lftp call at all: the never-acquired guard returned early.
  [ ! -s "${CALL_LOG}" ]
  run grep -cF 'quote DELE' "${CALL_LOG}"
  [ "${output}" = "0" ]
  run grep -cF 'quote RMD' "${CALL_LOG}"
  [ "${output}" = "0" ]
  run grep -cF 'PWNED' "${CALL_LOG}"
  [ "${output}" = "0" ]
  run grep -cF 'inherited-tried-name' "${CALL_LOG}"
  [ "${output}" = "0" ]
  [ ! -e "${pwned}" ]
}

# Positive control (the same stub, successful acquire, nothing inherited):
# the release still DELEs this run's sentinel and RMDs the lock directory.
# (The FND-0003 heartbeat test above covers the same path with refreshes.)
@test "entrypoint: FND-0101: positive control: a successful acquire is still released (DELE this run's sentinel, then RMD)" {
  unset ACQUIRED_LOCK_SENTINEL ACQUIRED_LOCK_SENTINEL_TRIED
  _run_entrypoint_inherited_sentinel 0
  echo "status=${status}"; echo "${output}"; cat "${CALL_LOG}"
  [ "${status}" -eq 0 ]
  p=".lftp-deployment.lock"
  [ "$(grep -c '^LFTP ' "${CALL_LOG}")" -ge 1 ]
  rel=$(grep -F 'quote DELE' "${CALL_LOG}")
  # The heartbeat renamed the stubbed name to a fresh stamp; the release
  # DELEs that current name (exactly one DELE), then RMDs.
  [ "$(grep -cF 'quote DELE' "${CALL_LOG}")" -eq 1 ]
  [[ "${rel}" == *"quote DELE ${p}/.lftp-deployment.lock.2026"*".info; quote RMD ${p}; quit;" ]] || { echo "release: ${rel}"; exit 1; }
}

# The TRIED reset is invisible on a failed acquire (TRIED is read only when a
# sentinel exists). On the success path an inherited TRIED survives when the
# attempt-1 refresh does not clear it (here: the refresh mv fails), and the
# release would then DELE the inherited names: injection into the lftp script.
@test "entrypoint: FND-0101: an inherited ACQUIRED_LOCK_SENTINEL_TRIED is not DELEd or injected by the release after a successful acquire with a failed refresh" {
  pwned="${BATS_TEST_TMPDIR}/PWNED"
  export ACQUIRED_LOCK_SENTINEL_TRIED="inh-tried-marker; !touch ${pwned}"
  unset ACQUIRED_LOCK_SENTINEL
  FAKE_MV_FAIL=1 _run_entrypoint_inherited_sentinel 0
  echo "status=${status}"; echo "${output}"; cat "${CALL_LOG}"
  [ "${status}" -eq 0 ]
  # The refresh mv really ran and failed (so TRIED was not cleared by it).
  [ "$(grep -c ' mv ' "${CALL_LOG}")" -ge 1 ]
  p=".lftp-deployment.lock"
  rel=$(grep -F 'quote DELE' "${CALL_LOG}")
  [ "$(grep -cF 'quote DELE' "${CALL_LOG}")" -eq 1 ]
  [[ "${rel}" == *"quote DELE ${p}/.lftp-deployment.lock.20200101T000000Z.1234.info; quote DELE ${p}/.lftp-deployment.lock.2026"*".info; quote RMD ${p}; quit;" ]] || { echo "release: ${rel}"; exit 1; }
  run grep -cF 'inh-tried-marker' "${CALL_LOG}"
  [ "${output}" = "0" ]
  run grep -cF 'PWNED' "${CALL_LOG}"
  [ "${output}" = "0" ]
  [ ! -e "${pwned}" ]
}
