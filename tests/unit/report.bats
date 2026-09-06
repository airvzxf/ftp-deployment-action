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

# F2 audit (#314): ::add-mask:: is a SINGLE-LINE workflow command.
# If INPUT_PASSWORD (or INPUT_USER / INPUT_SERVER) contains CR/LF,
# pre-fix the runner only masks the FIRST line and the remainder
# surfaces UNMASKED in the log. Post-fix add_masks strips CR/LF and
# the rest of the C0 control range from each value before emitting
# the directive so a multi-line secret collapses into a single
# masked line.
@test "add_masks: multi-line INPUT_PASSWORD collapses to a single masked line (issue #314)" {
  INPUT_PASSWORD="first-line-password
second-line-password"
  INPUT_USER="me"
  INPUT_SERVER="ftp://example.com"
  run add_masks
  [ "$status" -eq 0 ]
  # Exactly 3 lines (one per non-empty input).
  n=$(printf '%s\n' "$output" | grep -c '^::add-mask::')
  [ "$n" -eq 3 ]
  # The post-newline portion must NOT appear on its own line —
  # a bare `second-line-password` line would be the partial-leak
  # signature the runner's single-line parser would expose.
  if printf '%s\n' "$output" | grep -qx "second-line-password"; then
    echo "post-newline password leaked on its own line (issue #314 regression)"
    printf '%s\n' "$output"
    false
  fi
  # The first add-mask line must contain the COLLAPSED value
  # (CR/LF stripped), NOT just the pre-newline portion. Pre-fix
  # the line would have been `::add-mask::first-line-password`
  # with `second-line-password` on a separate unmasked line.
  printf '%s\n' "$output" | grep -qx "::add-mask::first-line-passwordsecond-line-password"
  if printf '%s\n' "$output" | grep -qx "::add-mask::first-line-password"; then
    echo "pre-fix shape detected: add-mask line stops at the first newline (issue #314 regression)"
    printf '%s\n' "$output"
    false
  fi
}

@test "add_masks: CR and other control chars in INPUT_USER are stripped (issue #314)" {
  INPUT_PASSWORD="secret"
  # Mix CR + NUL + BEL — NUL and BEL are in the C0 control range
  # but the runner's parser does not treat them as line breaks; the
  # defense-in-depth strip removes all C0 anyway.
  INPUT_USER=$'alice\rNUL\x07\x1b'
  INPUT_SERVER="ftp://example.com"
  run add_masks
  [ "$status" -eq 0 ]
  # Exactly 3 masked lines; the bare "alice" must appear, with no
  # CR / NUL / BEL residue and no post-newline leakage.
  n=$(printf '%s\n' "$output" | grep -c '^::add-mask::')
  [ "$n" -eq 3 ]
  printf '%s\n' "$output" | grep -q "::add-mask::alice"
  if printf '%s' "$output" | grep -q $'\r'; then
    echo "CR survived add_masks stripping (issue #314 regression)"
    printf '%s\n' "$output" | cat -A
    false
  fi
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

@test "print_inputs_dump: the dump loop covers all 31 declared inputs (v2.11.8 #257 + #227)" {
  unset INPUT_SERVER INPUT_USER INPUT_PASSWORD INPUT_LOCAL_DIR INPUT_REMOTE_DIR \
        INPUT_DELETE INPUT_NO_SYMLINKS INPUT_MAX_RETRIES INPUT_MIRROR_VERBOSE \
        INPUT_FTP_SSL_ALLOW INPUT_SSL_VERIFY_CERTIFICATE INPUT_SSL_CHECK_HOSTNAME \
        INPUT_FTP_PASSIVE_MODE INPUT_FTP_USE_FEAT INPUT_FTP_NOP_INTERVAL \
        INPUT_NET_MAX_RETRIES INPUT_NET_PERSIST_RETRIES INPUT_NET_TIMEOUT \
        INPUT_DNS_MAX_RETRIES INPUT_DNS_FATAL_TIMEOUT INPUT_LFTP_SETTINGS \
        INPUT_EXCLUDE INPUT_EXCLUDE_DELETE INPUT_DEBUG INPUT_FAIL_ON_DEPRECATED \
        INPUT_DRY_RUN INPUT_UPLOAD_LOG_ON_FAILURE INPUT_CONCURRENCY_LOCK \
        INPUT_CONCURRENCY_LOCK_PATH INPUT_CONCURRENCY_LOCK_TIMEOUT \
        INPUT_CONCURRENCY_LOCK_POLL_INTERVAL
  run print_inputs_dump "false"
  [ "$status" -eq 0 ]
  for name in server user password local_dir remote_dir delete max_retries \
              no_symlinks mirror_verbose ftp_ssl_allow ssl_verify_certificate \
              ssl_check_hostname ftp_passive_mode ftp_use_feat ftp_nop_interval \
              net_max_retries net_persist_retries net_timeout dns_max_retries \
              dns_fatal_timeout lftp_settings exclude exclude_delete debug \
              fail_on_deprecated dry_run upload_log_on_failure concurrency_lock \
              concurrency_lock_path concurrency_lock_timeout \
              concurrency_lock_poll_interval; do
    [[ "$output" == *"${name}:"* ]]
  done
}

@test "print_inputs_dump: debug=true covers all 31 declared inputs (v2.11.8 #181)" {
  # Previously the debug=true printf block was silently missing
  # fail_on_deprecated and dry_run (29 entries vs 31). A regression
  # that drops either from the printf block would have slipped
  # past tests; this test locks the contract.
  unset INPUT_SERVER INPUT_USER INPUT_PASSWORD INPUT_LOCAL_DIR INPUT_REMOTE_DIR \
        INPUT_DELETE INPUT_NO_SYMLINKS INPUT_MAX_RETRIES INPUT_MIRROR_VERBOSE \
        INPUT_FTP_SSL_ALLOW INPUT_SSL_VERIFY_CERTIFICATE INPUT_SSL_CHECK_HOSTNAME \
        INPUT_FTP_PASSIVE_MODE INPUT_FTP_USE_FEAT INPUT_FTP_NOP_INTERVAL \
        INPUT_NET_MAX_RETRIES INPUT_NET_PERSIST_RETRIES INPUT_NET_TIMEOUT \
        INPUT_DNS_MAX_RETRIES INPUT_DNS_FATAL_TIMEOUT INPUT_LFTP_SETTINGS \
        INPUT_EXCLUDE INPUT_EXCLUDE_DELETE INPUT_DEBUG INPUT_FAIL_ON_DEPRECATED \
        INPUT_DRY_RUN INPUT_UPLOAD_LOG_ON_FAILURE INPUT_CONCURRENCY_LOCK \
        INPUT_CONCURRENCY_LOCK_PATH INPUT_CONCURRENCY_LOCK_TIMEOUT \
        INPUT_CONCURRENCY_LOCK_POLL_INTERVAL
  run print_inputs_dump "true"
  [ "$status" -eq 0 ]
  for name in server user password local_dir remote_dir delete max_retries \
              no_symlinks mirror_verbose ftp_ssl_allow ssl_verify_certificate \
              ssl_check_hostname ftp_passive_mode ftp_use_feat ftp_nop_interval \
              net_max_retries net_persist_retries net_timeout dns_max_retries \
              dns_fatal_timeout lftp_settings exclude exclude_delete debug \
              fail_on_deprecated dry_run upload_log_on_failure concurrency_lock \
              concurrency_lock_path concurrency_lock_timeout \
              concurrency_lock_poll_interval; do
    [[ "$output" == *"${name}:"* ]]
  done
}

@test "print_inputs_dump: debug=true label order matches action.yml (v2.11.8 #181)" {
  # Spot-check the order: action.yml declares `delete` BEFORE
  # `max_retries`; the previous printf block had them swapped.
  INPUT_SERVER="ftp://example.com"
  INPUT_DELETE="false"
  INPUT_MAX_RETRIES="10"
  run print_inputs_dump "true"
  [ "$status" -eq 0 ]
  delete_pos=$(printf '%s' "$output" | grep -n 'delete:' | head -1 | cut -d: -f1)
  mr_pos=$(printf '%s' "$output" | grep -n 'max_retries:' | head -1 | cut -d: -f1)
  [ "${delete_pos}" -lt "${mr_pos}" ]
}

# ----------------------------------------------------------------------------
# print_resolved_config
# ----------------------------------------------------------------------------

@test "print_resolved_config: emits resolved values inside group markers" {
  INPUT_LOCAL_DIR="${BATS_TEST_DIRNAME}/../integration/fixtures/sample-public-html"
  INPUT_REMOTE_DIR="/remote/"
  FTP_SETTINGS="set ftp:ssl-allow false;"
  MIRROR_COMMAND="mirror --reverse --verbose=1"
  INPUT_MAX_RETRIES="5"

  run print_resolved_config

  [ "$status" -eq 0 ]
  [[ "$output" == *"::group::Resolved configuration"* ]]
  [[ "$output" == *"::endgroup::"* ]]
  [[ "$output" == *"=== Directories ==="* ]]
  [[ "$output" == *"INPUT_LOCAL_DIR: ${INPUT_LOCAL_DIR}"* ]]
  [[ "$output" == *"INPUT_REMOTE_DIR: ${INPUT_REMOTE_DIR}"* ]]
  [[ "$output" == *"=== List local directory ==="* ]]
  [[ "$output" == *"=== LFTP Settings ==="* ]]
  [[ "$output" == *"FTP_SETTINGS"* ]]
  [[ "$output" == *"-> ${FTP_SETTINGS}"* ]]
  [[ "$output" == *"MIRROR_COMMAND"* ]]
  [[ "$output" == *"${MIRROR_COMMAND}"* ]]
  [[ "$output" == *"INPUT_MAX_RETRIES -> 5"* ]]
}

@test "print_resolved_config: includes the local directory listing" {
  INPUT_LOCAL_DIR="${BATS_TEST_DIRNAME}/../integration/fixtures/sample-public-html"
  INPUT_REMOTE_DIR="/"

  unset FTP_SETTINGS MIRROR_COMMAND INPUT_MAX_RETRIES
  run print_resolved_config

  [ "$status" -eq 0 ]
  [[ "$output" == *"${INPUT_LOCAL_DIR}"* ]]
  [[ "$output" == *"index.html"* ]]
  [[ "$output" == *"about.html"* ]]
}

@test "print_resolved_config: prints empty resolved settings explicitly" {
  INPUT_LOCAL_DIR="${BATS_TEST_DIRNAME}/../integration/fixtures/sample-public-html"
  INPUT_REMOTE_DIR="/"

  unset FTP_SETTINGS MIRROR_COMMAND INPUT_MAX_RETRIES
  run print_resolved_config

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Eq '^ FTP_SETTINGS +-> *$'
  printf '%s\n' "$output" | grep -Eq '^ MIRROR_COMMAND +-> *$'
  printf '%s\n' "$output" | grep -Eq '^ INPUT_MAX_RETRIES +-> *$'
  [[ "$output" == *"::endgroup::"* ]]
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
