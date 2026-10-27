#!/usr/bin/env bats
# tests/unit/retry.bats — unit tests for the retry-loop helpers in
# lib.sh: classify_permanent_error, compute_backoff_seconds. The
# file-IO part of run_lftp_once is exercised by tests/smoke.sh.

setup() {
  set +u
  # v2.11.12 (F2 audit): drop the dead BATS_TESTDIR (no-underscores)
  # branch. The correct bats-core variable is BATS_TEST_DIRNAME; the
  # no-underscore form expands to empty under `set +u`, producing
  # `LIB="/../../lib.sh"` which is non-empty (so the fallback never
  # fires) and the file path is invalid. The other 6 .bats files
  # already use BATS_TEST_DIRNAME directly; align.
  LIB="${BATS_TEST_DIRNAME}/../../lib.sh"
  # shellcheck disable=SC1090
  . "${LIB}"
}

# ----------------------------------------------------------------------------
# classify_permanent_error
# ----------------------------------------------------------------------------

@test "classify_permanent_error: '530 Login authentication failed' is permanent" {
  f=$(mktemp)
  printf 'Trying to login...\n< 530 Login authentication failed\nmirror: Login failed: 530 Login authentication failed\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 0 ]
  rm -f "$f"
}

@test "classify_permanent_error: '530 Login incorrect' is permanent" {
  f=$(mktemp)
  printf '< 530 Login incorrect.\nmirror: Login failed: 530 Login incorrect.\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 0 ]
  rm -f "$f"
}

@test "classify_permanent_error: '550 Permission denied' is permanent" {
  f=$(mktemp)
  printf 'mirror: Access failed: 550 Permission denied\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 0 ]
  rm -f "$f"
}

@test "classify_permanent_error: '550 ... No such file' is permanent" {
  f=$(mktemp)
  printf 'mirror: Access failed: 550 /foo/bar: No such file or directory\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 0 ]
  rm -f "$f"
}

@test "classify_permanent_error: 'Connection refused' is transient (not permanent)" {
  f=$(mktemp)
  printf 'connect: Connection refused\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 1 ]
  rm -f "$f"
}

@test "classify_permanent_error: an empty log is transient" {
  f=$(mktemp)
  : > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 1 ]
  rm -f "$f"
}

# F2 audit (#330): when the action uses net:max-retries=0 (the
# v2.11.14 default) lftp does NOT internally retry, so the FIRST
# attempt's server "530 Login incorrect" error is preserved verbatim
# in the log. The classifier must match it as PERMANENT. Before
# v2.11.14 the default was net:max-retries=1 and lftp's internal
# retry overwrote the 530 with "max-retries exceeded", silently
# breaking PERMANENT classification for this entire class of errors.
@test "classify_permanent_error: 'mirror: Login failed: 530 Login incorrect' is permanent (v2.11.14 #330 regression test)" {
  f=$(mktemp)
  printf 'Trying ftp://user@host:21\n---> PASS wrong\n<--- 530 Login incorrect.\nmirror: Login failed: 530 Login incorrect.\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 0 ]
  rm -f "$f"
}

# ----------------------------------------------------------------------------
# FND-0045: classify_permanent_error matches only lftp's own error lines
# ("<cmd>: Login failed: ..." / "<cmd>: Access failed: 550 ..."), only in
# the bytes after OFFSET (the current attempt). Lines below are lftp 4.9.3
# output (maintainer evidence). Every assertion is a `run` + `[ ]` in the
# test body, so a wrong status fails the test.
# ----------------------------------------------------------------------------

@test "FND-0045: 'mirror: Login failed: 530 Login incorrect.' is permanent" {
  f=$(mktemp)
  printf 'mirror: Login failed: 530 Login incorrect.\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 0 ]
  rm -f "$f"
}

@test "FND-0045: 'mirror: Access failed: 550 Failed to change directory.' is permanent" {
  f=$(mktemp)
  printf 'mirror: Access failed: 550 Failed to change directory. (/nope)\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 0 ]
  rm -f "$f"
}

@test "FND-0045: a Login failed line after OFFSET is permanent (earlier bytes are unrelated)" {
  f=$(mktemp)
  printf 'Try #1\n-------\nconnect: Connection refused\n' > "$f"
  offset=$(wc -c < "$f" | tr -d '[:space:]')
  printf 'Try #2\n-------\nmirror: Login failed: 530 Login incorrect.\n' >> "$f"
  run classify_permanent_error "$f" "$offset"
  [ "$status" -eq 0 ]
  rm -f "$f"
}

@test "FND-0045: 'Fatal error: max-retries exceeded (530 ...)' (connection limit) is transient" {
  f=$(mktemp)
  printf 'mirror: Fatal error: max-retries exceeded (530 Sorry, the maximum number of clients (5) from your host are already connected.)\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 1 ]
  rm -f "$f"
}

@test "FND-0045: a 'Transferring file' line whose path says '530 login failed' is transient" {
  f=$(mktemp)
  printf "Transferring file \`530 login failed.txt'\n" > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 1 ]
  rm -f "$f"
}

@test "FND-0045: mirror statistics with 530 files or bytes are transient" {
  f=$(mktemp)
  printf 'Total: 3 directories, 530 files, 0 symlinks\nNew: 530 files, 0 symlinks\n530 bytes transferred\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 1 ]
  rm -f "$f"
}

@test "FND-0045: a Login failed line BEFORE OFFSET (earlier attempt) does not count" {
  f=$(mktemp)
  printf 'Try #1\n-------\nmirror: Login failed: 530 Login incorrect.\n' > "$f"
  offset=$(wc -c < "$f" | tr -d '[:space:]')
  printf 'Try #2\n-------\nmirror: Fatal error: max-retries exceeded (530 Sorry, the maximum number of clients (5) from your host are already connected.)\n' >> "$f"
  run classify_permanent_error "$f" "$offset"
  [ "$status" -eq 1 ]
  # Control: the same file without OFFSET still sees attempt 1.
  run classify_permanent_error "$f"
  [ "$status" -eq 0 ]
  rm -f "$f"
}

@test "FND-0045: lowercase 'mirror: login failed: 530 ...' is not permanent (case-sensitive)" {
  f=$(mktemp)
  printf 'mirror: login failed: 530 Login incorrect.\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 1 ]
  rm -f "$f"
}

@test "FND-0045: OFFSET equal to the file size leaves an empty tail (transient)" {
  f=$(mktemp)
  printf 'mirror: Login failed: 530 Login incorrect.\n' > "$f"
  offset=$(wc -c < "$f" | tr -d '[:space:]')
  run classify_permanent_error "$f" "$offset"
  [ "$status" -eq 1 ]
  rm -f "$f"
}

@test "FND-0045: OFFSET past the end of the file leaves an empty tail (transient)" {
  f=$(mktemp)
  printf 'mirror: Login failed: 530 Login incorrect.\n' > "$f"
  run classify_permanent_error "$f" 100000
  [ "$status" -eq 1 ]
  rm -f "$f"
}

@test "FND-0045: without OFFSET the whole file is read" {
  f=$(mktemp)
  printf 'Try #1\nmirror: Access failed: 550 Failed to change directory. (/nope)\nTry #2\nconnect: Connection refused\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 0 ]
  run classify_permanent_error "$f" 0
  [ "$status" -eq 0 ]
  rm -f "$f"
}

# ----------------------------------------------------------------------------
# compute_backoff_seconds
# ----------------------------------------------------------------------------

@test "compute_backoff_seconds: counter=1 -> 1" {
  run compute_backoff_seconds 1
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "compute_backoff_seconds: counter=2 -> 1 (no jitter at delay=1)" {
  run compute_backoff_seconds 2
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "compute_backoff_seconds: counter=3 -> 2 (with ±1 jitter, 1..3)" {
  # Run several times to exercise the jitter. The output should
  # always be in [1, 3] (delay=2, jitter range [-1, +1], floor 1).
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    run compute_backoff_seconds 3
    [ "$status" -eq 0 ]
    n=$output
    [ "$n" -ge 1 ]
    [ "$n" -le 3 ]
  done
}

@test "compute_backoff_seconds: counter=4 -> in [2, 6] (delay=4, ±2 jitter)" {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    run compute_backoff_seconds 4
    n=$output
    [ "$n" -ge 2 ]
    [ "$n" -le 6 ]
  done
}

@test "compute_backoff_seconds: counter=5 -> in [4, 12] (delay=8, ±4 jitter)" {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    run compute_backoff_seconds 5
    n=$output
    [ "$n" -ge 4 ]
    [ "$n" -le 12 ]
  done
}

@test "compute_backoff_seconds: counter=6 -> in [8, 24] (delay=16, ±8 jitter)" {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    run compute_backoff_seconds 6
    n=$output
    [ "$n" -ge 8 ]
    [ "$n" -le 24 ]
  done
}

@test "compute_backoff_seconds: counter=10 (above cap) -> in [15, 45] (delay=30, ±15 jitter)" {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    run compute_backoff_seconds 10
    n=$output
    [ "$n" -ge 15 ]
    [ "$n" -le 45 ]
  done
}

@test "compute_backoff_seconds: result is always >= 1 (floor enforced)" {
  for counter in 1 2 3 4 5 6 10 20 100; do
    run compute_backoff_seconds "$counter"
    n=$output
    [ "$n" -ge 1 ]
  done
}

@test "compute_backoff_seconds: works when \$RANDOM is unset (v2.11.8 #179, POSIX sh)" {
  # Regression test for the busybox-ash-only $RANDOM dependency.
  # On a strict POSIX /bin/sh (e.g. dash on Debian), $RANDOM is
  # unset; the pre-fix jitter collapsed to zero and every retry
  # fired at the same instant. The new awk-based jitter has no
  # dependency on $RANDOM.
  #
  # Run lib.sh under `env -u RANDOM bash -c` to mimic a POSIX sh
  # that does not pre-set $RANDOM, then call compute_backoff_seconds
  # with counter=5 (delay=8, ±4 jitter) and assert the output is in
  # [4, 12]. The contract is unchanged for callers that do have
  # $RANDOM (existing tests above still pass), and the fix is
  # transparent to them.
  unset RANDOM
  run compute_backoff_seconds 5
  [ "$status" -eq 0 ]
  n=$output
  [ "$n" -ge 4 ]
  [ "$n" -le 12 ]
}

# ----------------------------------------------------------------------------
# FND-0049: the jitter seed is per process, not per second
# ----------------------------------------------------------------------------
# Helper. Runs compute_backoff_seconds in $1 separate bash processes
# (counter $2) and leaves the values, one per line, in $BATCH. The
# batch is retried (up to 5 times) when the wall-clock second changed
# while it ran, so every accepted batch ran inside one second. That
# is the condition under which the old bare `srand()` gave identical
# values. A bare `bash -c` is used because /bin/sh is dash on CI and
# pipefail is a bash feature. BACKOFF_LIB can point at another
# lib.sh (used to prove the tests fail on the pre-fix file).
_backoff_batch() {
  _bb_n=$1
  _bb_counter=$2
  _bb_lib="${BACKOFF_LIB:-${LIB}}"
  _bb_try=0
  while [ "${_bb_try}" -lt 5 ]; do
    _bb_try=$((_bb_try + 1))
    _bb_t0=$(date +%s)
    BATCH=''
    _bb_i=0
    while [ "${_bb_i}" -lt "${_bb_n}" ]; do
      _bb_i=$((_bb_i + 1))
      _bb_v=$(bash -c 'set -eu; set -o pipefail; . "$1"; compute_backoff_seconds "$2"' _ "${_bb_lib}" "${_bb_counter}")
      BATCH="${BATCH}${_bb_v}
"
    done
    _bb_t1=$(date +%s)
    [ "${_bb_t0}" = "${_bb_t1}" ] && return 0
  done
  return 1
}

# Asserts every line of $BATCH is an integer in [$1, $2] and that
# more than one distinct value occurs.
_assert_spread_in_range() {
  _as_lo=$1
  _as_hi=$2
  _as_distinct=$(printf '%s' "${BATCH}" | sort -u | wc -l)
  [ "${_as_distinct}" -gt 1 ]
  for _as_v in ${BATCH}; do
    case "${_as_v}" in
      '' | *[!0-9]*) return 1 ;;
    esac
    [ "${_as_v}" -ge "${_as_lo}" ]
    [ "${_as_v}" -le "${_as_hi}" ]
  done
}

@test "FND-0049: separate processes in the same second get different jitter, within range" {
  # counter=6 -> delay=16, jitter in [-8, 8], sleep in [8, 24]
  # (17 values; 20 identical results by chance is about 17^-19).
  _backoff_batch 20 6
  _assert_spread_in_range 8 24
}

@test "FND-0049: with od failing, the call neither aborts nor collapses to one value" {
  # The fallback seed is time + $$, so PIDs still separate processes
  # in the same second. A failing od must not abort under
  # `set -eu` + pipefail.
  stub="${BATS_TEST_TMPDIR}/odfail"
  mkdir -p "$stub"
  printf '#!/bin/sh\nexit 1\n' > "$stub/od"
  chmod +x "$stub/od"
  PATH="$stub:$PATH"
  export PATH
  run od -An -N4 -tu4 /dev/urandom
  [ "$status" -eq 1 ]
  _backoff_batch 20 6
  _assert_spread_in_range 8 24
}

@test "FND-0049: with od printing non-numeric text, the fallback seed is used" {
  stub="${BATS_TEST_TMPDIR}/odjunk"
  mkdir -p "$stub"
  printf '#!/bin/sh\necho "od: garbage"\nexit 0\n' > "$stub/od"
  chmod +x "$stub/od"
  PATH="$stub:$PATH"
  export PATH
  _backoff_batch 20 6
  _assert_spread_in_range 8 24
}
