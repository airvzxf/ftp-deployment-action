#!/usr/bin/env bats
# tests/unit/lock.bats — unit tests for the concurrency-lock
# functions in lib.sh: build_lock_acquire_script,
# build_lock_release_script, run_lftp_lock_release.
#
# The functions read INPUT_CONCURRENCY_LOCK and friends via
# _indirection. The tests set those variables to exercise the
# relevant branch.

setup() {
  set +u
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
}

# ----------------------------------------------------------------------------
# build_lock_acquire_script — disabled
# ----------------------------------------------------------------------------

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

@test "build_lock_acquire_script: empty when INPUT_CONCURRENCY_LOCK is anything but 'true'" {
  INPUT_CONCURRENCY_LOCK="TRUE"  # case-sensitive: only "true" enables
  run build_lock_acquire_script
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ----------------------------------------------------------------------------
# build_lock_acquire_script — enabled
# ----------------------------------------------------------------------------

@test "build_lock_acquire_script: emits a non-empty script when enabled with defaults" {
  INPUT_CONCURRENCY_LOCK="true"
  INPUT_CONCURRENCY_LOCK_PATH=".lftp-deployment.lock"
  INPUT_CONCURRENCY_LOCK_TIMEOUT="300"
  INPUT_CONCURRENCY_LOCK_POLL_INTERVAL="5"
  run build_lock_acquire_script
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # The acquire script must contain a repeat-based lock loop.
  echo "$output" | grep -q "repeat --until-ok"
  echo "$output" | grep -q "quote MKD .lftp-deployment.lock"
  # count = ceil(300/5) = 60
  echo "$output" | grep -q -- "-c 60"
  echo "$output" | grep -q -- "-d 5"
  # The script must end with `&& ` so the next lftp command (the
  # mirror) only runs if the acquire succeeded.
  echo "$output" | grep -qE '&& *$'
}

@test "build_lock_acquire_script: with timeout=0 produces count=1 (single try, no retry)" {
  INPUT_CONCURRENCY_LOCK="true"
  INPUT_CONCURRENCY_LOCK_PATH=".lock"
  INPUT_CONCURRENCY_LOCK_TIMEOUT="0"
  INPUT_CONCURRENCY_LOCK_POLL_INTERVAL="5"
  run build_lock_acquire_script
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "-c 1"
}

@test "build_lock_acquire_script: counts ceil(timeout/poll) correctly" {
  INPUT_CONCURRENCY_LOCK="true"
  INPUT_CONCURRENCY_LOCK_PATH=".lock"
  INPUT_CONCURRENCY_LOCK_TIMEOUT="300"
  INPUT_CONCURRENCY_LOCK_POLL_INTERVAL="7"
  # ceil(300/7) = 43
  run build_lock_acquire_script
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "-c 43"
  echo "$output" | grep -q -- "-d 7"
}

@test "build_lock_acquire_script: passes the lock path verbatim to quote MKD" {
  INPUT_CONCURRENCY_LOCK="true"
  INPUT_CONCURRENCY_LOCK_PATH="/var/locks/deploy.lock"
  INPUT_CONCURRENCY_LOCK_TIMEOUT="60"
  INPUT_CONCURRENCY_LOCK_POLL_INTERVAL="5"
  run build_lock_acquire_script
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "quote MKD /var/locks/deploy.lock"
}

# ----------------------------------------------------------------------------
# build_lock_release_script
# ----------------------------------------------------------------------------

@test "build_lock_release_script: empty when disabled" {
  unset INPUT_CONCURRENCY_LOCK
  run build_lock_release_script
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "build_lock_release_script: emits quote RMD when enabled" {
  INPUT_CONCURRENCY_LOCK="true"
  INPUT_CONCURRENCY_LOCK_PATH=".lftp-deployment.lock"
  run build_lock_release_script
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  echo "$output" | grep -q "quote RMD .lftp-deployment.lock"
  # Release is best-effort: the next lftp command (quit) must still
  # run, which is what the trailing `; ` guarantees.
  echo "$output" | grep -qE '; *$'
}

# ----------------------------------------------------------------------------
# run_lftp_lock_release
# ----------------------------------------------------------------------------

@test "run_lftp_lock_release: no-op when lock path is empty" {
  # We need a fake server URL and netrc file that the function
  # would otherwise try to use. The no-op path is checked first
  # by an explicit `if [ -z "${_rlr_lock_path}" ]`, so we can pass
  # a non-existent netrc without harm.
  run run_lftp_lock_release "ftp://nonexistent.invalid" \
                            "/tmp/does-not-exist-netrc" \
                            ""
  [ "$status" -eq 0 ]
}

@test "run_lftp_lock_release: no-op when netrc file is missing" {
  run run_lftp_lock_release "ftp://nonexistent.invalid" \
                            "/tmp/does-not-exist-netrc" \
                            ".lftp-deployment.lock"
  [ "$status" -eq 0 ]
}
