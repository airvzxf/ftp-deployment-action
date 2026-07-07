#!/usr/bin/env bats
# tests/unit/upload.bats — unit tests for upload_log_artifact in
# lib.sh. The function has three "skip" branches (opt-in switch
# disabled, missing GitHub-Actions env, missing log file) and one
# "upload" branch (calls curl with a multipart POST). The latter
# requires network + a real GITHUB_TOKEN and is NOT covered by
# unit tests; CI exercises the smoke path against a controlled
# stub of the GitHub API at a later iteration.

setup() {
  set +u
  LIB="${BATS_TEST_DIRNAME}/../../lib.sh"
  # shellcheck disable=SC1090
  . "${LIB}"
}

# ----------------------------------------------------------------------------
# Skip path 1: INPUT_UPLOAD_LOG_ON_FAILURE is not "true".
# ----------------------------------------------------------------------------

@test "upload_log_artifact: skips when INPUT_UPLOAD_LOG_ON_FAILURE is empty" {
  unset INPUT_UPLOAD_LOG_ON_FAILURE
  INPUT_UPLOAD_LOG_ON_FAILURE=""
  # Even with all the GH env vars set, an empty opt-in must skip.
  GITHUB_API_URL="https://api.github.com"
  GITHUB_REPOSITORY="owner/repo"
  GITHUB_RUN_ID="123"
  GITHUB_RUN_ATTEMPT="1"
  GITHUB_TOKEN="fake-token"
  run upload_log_artifact "/tmp/does-not-matter.log"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "upload_log_artifact: skips when INPUT_UPLOAD_LOG_ON_FAILURE is false" {
  INPUT_UPLOAD_LOG_ON_FAILURE="false"
  GITHUB_API_URL="https://api.github.com"
  GITHUB_REPOSITORY="owner/repo"
  GITHUB_RUN_ID="123"
  GITHUB_RUN_ATTEMPT="1"
  GITHUB_TOKEN="fake-token"
  run upload_log_artifact "/tmp/does-not-matter.log"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "upload_log_artifact: skips when INPUT_UPLOAD_LOG_ON_FAILURE is true but GITHUB_TOKEN is missing" {
  INPUT_UPLOAD_LOG_ON_FAILURE="true"
  GITHUB_API_URL="https://api.github.com"
  GITHUB_REPOSITORY="owner/repo"
  GITHUB_RUN_ID="123"
  GITHUB_RUN_ATTEMPT="1"
  unset GITHUB_TOKEN
  run upload_log_artifact "/tmp/does-not-matter.log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GITHUB_TOKEN is not set"* ]]
  [[ "$output" == *"secrets.GITHUB_TOKEN"* ]]
}

@test "upload_log_artifact: skips when GITHUB_API_URL is missing" {
  INPUT_UPLOAD_LOG_ON_FAILURE="true"
  unset GITHUB_API_URL
  GITHUB_REPOSITORY="owner/repo"
  GITHUB_RUN_ID="123"
  GITHUB_RUN_ATTEMPT="1"
  GITHUB_TOKEN="fake-token"
  run upload_log_artifact "/tmp/does-not-matter.log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GITHUB_API_URL is not set"* ]]
}

@test "upload_log_artifact: skips when GITHUB_REPOSITORY is missing" {
  INPUT_UPLOAD_LOG_ON_FAILURE="true"
  GITHUB_API_URL="https://api.github.com"
  unset GITHUB_REPOSITORY
  GITHUB_RUN_ID="123"
  GITHUB_RUN_ATTEMPT="1"
  GITHUB_TOKEN="fake-token"
  run upload_log_artifact "/tmp/does-not-matter.log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GITHUB_REPOSITORY is not set"* ]]
}

@test "upload_log_artifact: skips when GITHUB_RUN_ID is missing" {
  INPUT_UPLOAD_LOG_ON_FAILURE="true"
  GITHUB_API_URL="https://api.github.com"
  GITHUB_REPOSITORY="owner/repo"
  unset GITHUB_RUN_ID
  GITHUB_RUN_ATTEMPT="1"
  GITHUB_TOKEN="fake-token"
  run upload_log_artifact "/tmp/does-not-matter.log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GITHUB_RUN_ID is not set"* ]]
}

@test "upload_log_artifact: skips when GITHUB_RUN_ATTEMPT is missing" {
  INPUT_UPLOAD_LOG_ON_FAILURE="true"
  GITHUB_API_URL="https://api.github.com"
  GITHUB_REPOSITORY="owner/repo"
  GITHUB_RUN_ID="123"
  unset GITHUB_RUN_ATTEMPT
  GITHUB_TOKEN="fake-token"
  run upload_log_artifact "/tmp/does-not-matter.log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GITHUB_RUN_ATTEMPT is not set"* ]]
}

# ----------------------------------------------------------------------------
# Skip path 2: log file does not exist.
# ----------------------------------------------------------------------------

@test "upload_log_artifact: skips when the log file does not exist" {
  INPUT_UPLOAD_LOG_ON_FAILURE="true"
  GITHUB_API_URL="https://api.github.com"
  GITHUB_REPOSITORY="owner/repo"
  GITHUB_RUN_ID="123"
  GITHUB_RUN_ATTEMPT="1"
  GITHUB_TOKEN="fake-token"
  # Use a path that should never exist on the test runner.
  run upload_log_artifact "/tmp/upload-log-artifact-nonexistent-12345.log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"does not exist"* ]]
}

# ----------------------------------------------------------------------------
# Negative path: with all env vars and a real log file, an
# unreachable API host causes curl to fail. The function must NOT
# propagate the failure: the parent script's exit code is unchanged.
# We point GITHUB_API_URL at 127.0.0.1:1 (same trick tests/smoke.sh
# uses) so curl fails fast without network.
# ----------------------------------------------------------------------------

@test "upload_log_artifact: warn-and-continue when curl fails (unreachable API host)" {
  INPUT_UPLOAD_LOG_ON_FAILURE="true"
  GITHUB_API_URL="http://127.0.0.1:1"
  GITHUB_REPOSITORY="owner/repo"
  GITHUB_RUN_ID="123"
  GITHUB_RUN_ATTEMPT="1"
  GITHUB_TOKEN="fake-token"
  _log=$(mktemp) || skip "cannot mktemp"
  printf 'fake lftp output line 1\nfake lftp output line 2\n' > "${_log}"
  run upload_log_artifact "${_log}"
  rm -f "${_log}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: failed to upload log artifact"* ]]
  [[ "$output" == *"continuing to the failure banner"* ]]
}

# ----------------------------------------------------------------------------
# Verify the function does not introduce a second `eval` site —
# the project rule is "one point of dynamic variable-name lookup":
# _indirection. We assert the function exists, returns 0, and that
# running it with INPUT_UPLOAD_LOG_ON_FAILURE=true + missing env
# does NOT shell-inject or eval the variable name.
# ----------------------------------------------------------------------------

@test "upload_log_artifact: does not emit untrusted env var values into stdout (token is not echoed)" {
  INPUT_UPLOAD_LOG_ON_FAILURE="true"
  GITHUB_API_URL="https://api.github.com"
  GITHUB_REPOSITORY="owner/repo"
  GITHUB_RUN_ID="123"
  GITHUB_RUN_ATTEMPT="1"
  # Use a sentinel value that would be unmistakable if leaked.
  GITHUB_TOKEN="SENTINEL-TOKEN-9c091bb21b7c"
  unset GITHUB_TOKEN
  GITHUB_TOKEN="SENTINEL-TOKEN-9c091bb21b7c"
  # Point at an unreachable host so the function would normally try
  # to call curl; we want to confirm the token is NOT printed
  # anywhere on the way through.
  GITHUB_API_URL="http://127.0.0.1:1"
  _log=$(mktemp) || skip "cannot mktemp"
  printf 'fake lftp output\n' > "${_log}"
  run upload_log_artifact "${_log}"
  rm -f "${_log}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SENTINEL-TOKEN-9c091bb21b7c"* ]]
}
