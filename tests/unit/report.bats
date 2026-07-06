#!/usr/bin/env bats
# tests/unit/report.bats — unit tests for the reporting helpers in
# lib.sh: add_masks, print_inputs_dump, print_resolved_config,
# print_failure_banner, print_success_banner.
#
# These functions only print; the assertions are regex matches
# against the captured stdout/stderr. We do not assert pixel-perfect
# output (that is the contract of tests/smoke.sh against the
# integrated image); we just verify the expected groups, banners
# and ::warning::/::add-mask:: commands appear.

setup() {
  set +u
  LIB="${BATS_TEST_DIRNAME}/../../lib.sh"
  # shellcheck disable=SC1090
  . "${LIB}"
}

# ----------------------------------------------------------------------------
# add_masks
# ----------------------------------------------------------------------------

@test "add_masks: emits one ::add-mask:: line per non-empty input" {
  INPUT_PASSWORD="secret"
  INPUT_USER="me"
  INPUT_SERVER="ftp://example.com"
  run add_masks
  [ "$status" -eq 0 ]
  [[ "$output" == *"::add-mask::secret"* ]]
  [[ "$output" == *"::add-mask::me"* ]]
  [[ "$output" == *"::add-mask::ftp://example.com"* ]]
  # Exactly 3 lines.
  n=$(printf '%s\n' "$output" | grep -c '^::add-mask::')
  [ "$n" -eq 3 ]
}

@test "add_masks: empty inputs are skipped" {
  unset INPUT_PASSWORD INPUT_USER INPUT_SERVER
  run add_masks
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "add_masks: a single empty value (the others set) emits one line" {
  unset INPUT_PASSWORD
  INPUT_USER="me"
  INPUT_SERVER="ftp://example.com"
  run add_masks
  [ "$status" -eq 0 ]
  n=$(printf '%s\n' "$output" | grep -c '^::add-mask::')
  [ "$n" -eq 2 ]
}

# ----------------------------------------------------------------------------
# print_inputs_dump
# ----------------------------------------------------------------------------

@test "print_inputs_dump: debug=true echoes resolved values" {
  INPUT_SERVER="ftp://example.com"
  INPUT_USER="me"
  INPUT_PASSWORD="secret"
  INPUT_LOCAL_DIR="./public_html"
  INPUT_MAX_RETRIES="5"
  run print_inputs_dump "true"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::group::Inputs received"* ]]
  [[ "$output" == *"::endgroup::"* ]]
  # The format is "  %-26s %s\n" — so the label is padded to 26
  # characters, then one space, then the value. The exact count
  # of padding spaces depends on the label's length, so we
  # assert by stripping both leading whitespace and the known
  # "label: value" pattern instead of exact bytes.
  [[ "$output" == *"server:"*"ftp://example.com"* ]]
  [[ "$output" == *"password:"*"secret"* ]]
  [[ "$output" == *"max_retries:"*"5"* ]]
  [[ "$output" == *"local_dir:"*"./public_html"* ]]
}

@test "print_inputs_dump: debug=false emits (set)/(using default) per input" {
  INPUT_SERVER="ftp://example.com"
  INPUT_USER="me"
  unset INPUT_PASSWORD
  run print_inputs_dump "false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::group::Inputs received"* ]]
  # The (set) / (using default) suffix is what matters; the
  # exact whitespace before the suffix depends on the label's
  # length (26-char field + 1 space).
  [[ "$output" == *"server:"*"(set)"* ]]
  [[ "$output" == *"user:"*"(set)"* ]]
  [[ "$output" == *"password:"*"(using default)"* ]]
}

@test "print_inputs_dump: the dump loop covers all 24 declared inputs" {
  unset INPUT_SERVER INPUT_USER INPUT_PASSWORD INPUT_LOCAL_DIR INPUT_REMOTE_DIR \
        INPUT_DELETE INPUT_NO_SYMLINKS INPUT_MAX_RETRIES INPUT_MIRROR_VERBOSE \
        INPUT_FTP_SSL_ALLOW INPUT_SSL_VERIFY_CERTIFICATE INPUT_SSL_CHECK_HOSTNAME \
        INPUT_FTP_PASSIVE_MODE INPUT_FTP_USE_FEAT INPUT_FTP_NOP_INTERVAL \
        INPUT_NET_MAX_RETRIES INPUT_NET_PERSIST_RETRIES INPUT_NET_TIMEOUT \
        INPUT_DNS_MAX_RETRIES INPUT_DNS_FATAL_TIMEOUT INPUT_LFTP_SETTINGS \
        INPUT_DEBUG INPUT_FAIL_ON_DEPRECATED INPUT_DRY_RUN
  run print_inputs_dump "false"
  [ "$status" -eq 0 ]
  for name in server user password local_dir remote_dir max_retries delete \
              no_symlinks mirror_verbose ftp_ssl_allow ssl_verify_certificate \
              ssl_check_hostname ftp_passive_mode ftp_use_feat ftp_nop_interval \
              net_max_retries net_persist_retries net_timeout dns_max_retries \
              dns_fatal_timeout lftp_settings debug fail_on_deprecated dry_run; do
    [[ "$output" == *"${name}:"* ]]
  done
}

# ----------------------------------------------------------------------------
# print_success_banner
# ----------------------------------------------------------------------------

@test "print_success_banner: dry_run=true shows the DRY RUN variant" {
  run print_success_banner "true"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FTP DRY RUN COMPLETED"* ]]
  [[ "$output" == *"(no files transferred)"* ]]
  [[ "$output" != *"FTP UPLOADED FINISHED!"* ]]
}

@test "print_success_banner: dry_run=false shows the standard success banner" {
  run print_success_banner "false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FTP UPLOADED FINISHED!"* ]]
  [[ "$output" != *"FTP DRY RUN COMPLETED"* ]]
}

@test "print_success_banner: dry_run=empty falls through to the standard banner" {
  run print_success_banner ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"FTP UPLOADED FINISHED!"* ]]
}

# ----------------------------------------------------------------------------
# print_failure_banner
# ----------------------------------------------------------------------------

@test "print_failure_banner: emits ERROR: UPLOAD FAILED and the lftp log path" {
  run print_failure_banner "1" "" "/home/lftp/.lftp-logs/run-20260706T193427Z.log" "5h" "30s"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: UPLOAD FAILED"* ]]
  [[ "$output" == *"Last lftp exit code: 1"* ]]
  [[ "$output" == *"Full lftp output: /home/lftp/.lftp-logs/run-20260706T193427Z.log"* ]]
}

@test "print_failure_banner: PERMANENT error is mentioned when set" {
  run print_failure_banner "1" "true" "/tmp/log" "5h" "30s"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failure type: PERMANENT"* ]]
  [[ "$output" == *"Check credentials"* ]]
}

@test "print_failure_banner: documents the timeout exit code 124" {
  run print_failure_banner "124" "" "/tmp/log" "5h" "30s"
  [ "$status" -eq 1 ]
  [[ "$output" == *"124  timeout reached"* ]]
  [[ "$output" == *"max wall-clock 5h"* ]]
}

@test "print_failure_banner: documents the SIGKILL exit code 137" {
  run print_failure_banner "137" "" "/tmp/log" "5h" "30s"
  [ "$status" -eq 1 ]
  [[ "$output" == *"137  process killed"* ]]
  [[ "$output" == *"SIGKILL after 30s grace"* ]]
}
