#!/usr/bin/env bats
# tests/unit/retry.bats — unit tests for the retry-loop helpers in
# lib.sh: classify_permanent_error, compute_backoff_seconds. The
# file-IO part of run_lftp_once is exercised by tests/smoke.sh.

setup() {
  set +u
  LIB="${BATS_TESTDIR}/../../lib.sh" 2>/dev/null
  if [ -z "${LIB}" ] || [ ! -f "${LIB}" ]; then
    LIB="${BATS_TEST_DIRNAME}/../../lib.sh"
  fi
  # shellcheck disable=SC1090
  . "${LIB}"
}

# ----------------------------------------------------------------------------
# classify_permanent_error
# ----------------------------------------------------------------------------

@test "classify_permanent_error: '530 Login authentication failed' is permanent" {
  f=$(mktemp)
  printf 'Trying to login...\n< 530 Login authentication failed\n' > "$f"
  run classify_permanent_error "$f"
  [ "$status" -eq 0 ]
  rm -f "$f"
}

@test "classify_permanent_error: '530 Login incorrect' is permanent" {
  f=$(mktemp)
  printf '< 530 Login incorrect.\n' > "$f"
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
    [ "$n" -ge 1 ] && [ "$n" -le 3 ]
  done
}

@test "compute_backoff_seconds: counter=4 -> in [2, 6] (delay=4, ±2 jitter)" {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    run compute_backoff_seconds 4
    n=$output
    [ "$n" -ge 2 ] && [ "$n" -le 6 ]
  done
}

@test "compute_backoff_seconds: counter=5 -> in [4, 12] (delay=8, ±4 jitter)" {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    run compute_backoff_seconds 5
    n=$output
    [ "$n" -ge 4 ] && [ "$n" -le 12 ]
  done
}

@test "compute_backoff_seconds: counter=6 -> in [8, 24] (delay=16, ±8 jitter)" {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    run compute_backoff_seconds 6
    n=$output
    [ "$n" -ge 8 ] && [ "$n" -le 24 ]
  done
}

@test "compute_backoff_seconds: counter=10 (above cap) -> in [15, 45] (delay=30, ±15 jitter)" {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    run compute_backoff_seconds 10
    n=$output
    [ "$n" -ge 15 ] && [ "$n" -le 45 ]
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
  [ "$n" -ge 4 ] && [ "$n" -le 12 ]
}
