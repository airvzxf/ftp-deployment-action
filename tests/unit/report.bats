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
  [[ "$output" == *"::add-mask::example.com"* ]]
  # Exactly 4 lines (password, user, server, server host).
  n=$(printf '%s\n' "$output" | grep -c '^::add-mask::')
  [ "$n" -eq 4 ]
}

@test "add_masks: masks the bare server host that lftp prints in its URLs" {
  INPUT_SERVER="ftp://ftp.example.com:2121/www"
  unset INPUT_PASSWORD INPUT_USER
  run add_masks
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx '::add-mask::ftp.example.com'
}

@test "add_masks: a bare-host server is masked once" {
  INPUT_SERVER="ftp.example.com"
  unset INPUT_PASSWORD INPUT_USER
  run add_masks
  [ "$status" -eq 0 ]
  [ "$output" = "::add-mask::ftp.example.com" ]
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
  [ "$n" -eq 3 ]
}

# F2 audit (#314): ::add-mask:: is a SINGLE-LINE workflow command.
# If INPUT_PASSWORD (or INPUT_USER / INPUT_SERVER) contains CR/LF,
# the raw value would put its post-newline part on a bare line of
# the add_masks output. #314 avoided that by registering the value
# with CR/LF removed, but that collapsed form never appears in the
# log, so it masked nothing (FND-0046). add_masks now registers each
# non-empty CR/LF-separated piece on its own `::add-mask::` line:
# those pieces are what a multi-line value prints as. The assertions
# changed accordingly: `::add-mask::first-line-password` is now
# required (it was forbidden), the collapsed form is now forbidden,
# and the count is 5. The no-bare-line check is unchanged.
@test "add_masks: multi-line INPUT_PASSWORD masks each line on its own (issue #314, FND-0046)" {
  INPUT_PASSWORD="first-line-password
second-line-password"
  INPUT_USER="me"
  INPUT_SERVER="ftp://example.com"
  run add_masks
  [ "$status" -eq 0 ]
  # Exactly 5 lines (two password pieces, user, server, server host).
  n=$(printf '%s\n' "$output" | grep -c '^::add-mask::')
  [ "$n" -eq 5 ]
  # The post-newline portion must NOT appear on its own line —
  # a bare `second-line-password` line would be the partial-leak
  # signature the runner's single-line parser would expose.
  if printf '%s\n' "$output" | grep -qx "second-line-password"; then
    echo "post-newline password leaked on its own line (issue #314 regression)"
    printf '%s\n' "$output"
    false
  fi
  # Each printed line of the value is registered as its own mask.
  printf '%s\n' "$output" | grep -qx "::add-mask::first-line-password"
  printf '%s\n' "$output" | grep -qx "::add-mask::second-line-password"
  # The collapsed form never appears in the log; registering it is
  # the FND-0046 shape.
  if printf '%s\n' "$output" | grep -qx "::add-mask::first-line-passwordsecond-line-password"; then
    echo "collapsed form registered instead of the printed lines (FND-0046 regression)"
    printf '%s\n' "$output"
    false
  fi
}

@test "add_masks: CR in INPUT_USER splits the value and never reaches the output (issue #314)" {
  INPUT_PASSWORD="secret"
  # Mix CR + BEL + ESC. FND-0046: CR is a line break, so the value
  # is split there; BEL and ESC are not line breaks and are kept,
  # because the mask must equal the printed text.
  INPUT_USER=$'alice\rNUL\x07\x1b'
  INPUT_SERVER="ftp://example.com"
  run add_masks
  [ "$status" -eq 0 ]
  # Exactly 5 masked lines (FND-0046: the user value is two pieces,
  # `alice` and `NUL<BEL><ESC>`; the server host is the 5th). The
  # bare "alice" must appear, with no CR residue.
  n=$(printf '%s\n' "$output" | grep -c '^::add-mask::')
  [ "$n" -eq 5 ]
  printf '%s\n' "$output" | grep -q "::add-mask::alice"
  if printf '%s' "$output" | grep -q $'\r'; then
    echo "CR survived add_masks stripping (issue #314 regression)"
    printf '%s\n' "$output" | cat -A
    false
  fi
}

# FND-0046: a multi-line password is printed as separate lines, so
# each line gets exactly one directive. Counts use grep -cxF (whole
# line, fixed string); `|| true` keeps a zero count from aborting
# the test before the assertion.
@test "add_masks: FND-0046 multi-line password gets exactly one mask per line" {
  INPUT_PASSWORD=$'first-line-password\nsecond-line-password'
  unset INPUT_USER INPUT_SERVER
  run add_masks
  [ "$status" -eq 0 ]
  n=$(printf '%s\n' "$output" | grep -cxF '::add-mask::first-line-password' || true)
  [ "$n" -eq 1 ]
  n=$(printf '%s\n' "$output" | grep -cxF '::add-mask::second-line-password' || true)
  [ "$n" -eq 1 ]
  # Issue #314: no bare post-newline line the runner would not parse.
  n=$(printf '%s\n' "$output" | grep -cxF 'second-line-password' || true)
  [ "$n" -eq 0 ]
  # The collapsed form is never printed, so it must not be registered.
  n=$(printf '%s\n' "$output" | grep -cF 'first-line-passwordsecond-line-password' || true)
  [ "$n" -eq 0 ]
  n=$(printf '%s\n' "$output" | grep -c '' || true)
  [ "$n" -eq 2 ]
}

@test "add_masks: FND-0046 CRLF password has no CR and no empty mask line" {
  INPUT_PASSWORD=$'first-line-password\r\nsecond-line-password\r\n'
  unset INPUT_USER INPUT_SERVER
  run add_masks
  [ "$status" -eq 0 ]
  n=$(printf '%s' "$output" | grep -c $'\r' || true)
  [ "$n" -eq 0 ]
  n=$(printf '%s\n' "$output" | grep -cxF '::add-mask::' || true)
  [ "$n" -eq 0 ]
  n=$(printf '%s\n' "$output" | grep -cxF '::add-mask::first-line-password' || true)
  [ "$n" -eq 1 ]
  n=$(printf '%s\n' "$output" | grep -cxF '::add-mask::second-line-password' || true)
  [ "$n" -eq 1 ]
  n=$(printf '%s\n' "$output" | grep -c '' || true)
  [ "$n" -eq 2 ]
}

@test "add_masks: FND-0046 a bare CR separates pieces like a newline" {
  INPUT_PASSWORD=$'one\rtwo'
  unset INPUT_USER INPUT_SERVER
  run add_masks
  [ "$status" -eq 0 ]
  n=$(printf '%s\n' "$output" | grep -cxF '::add-mask::one' || true)
  [ "$n" -eq 1 ]
  n=$(printf '%s\n' "$output" | grep -cxF '::add-mask::two' || true)
  [ "$n" -eq 1 ]
}

# The runner unescapes %25, %0D and %0A in command data, so a literal
# `%` must be registered as `%25` and nothing else may change.
@test "add_masks: FND-0046 literal %25 and %0A in a password are escaped" {
  INPUT_PASSWORD='p%25w%0Ad'
  unset INPUT_USER INPUT_SERVER
  run add_masks
  [ "$status" -eq 0 ]
  n=$(printf '%s\n' "$output" | grep -cxF '::add-mask::p%2525w%250Ad' || true)
  [ "$n" -eq 1 ]
  n=$(printf '%s\n' "$output" | grep -c '' || true)
  [ "$n" -eq 1 ]
}

@test "add_masks: FND-0046 leading and trailing spaces of a piece are kept" {
  INPUT_PASSWORD=$'  lead\ntrail  \n  both  '
  unset INPUT_USER INPUT_SERVER
  run add_masks
  [ "$status" -eq 0 ]
  n=$(printf '%s\n' "$output" | grep -cxF '::add-mask::  lead' || true)
  [ "$n" -eq 1 ]
  n=$(printf '%s\n' "$output" | grep -cxF '::add-mask::trail  ' || true)
  [ "$n" -eq 1 ]
  n=$(printf '%s\n' "$output" | grep -cxF '::add-mask::  both  ' || true)
  [ "$n" -eq 1 ]
}

@test "add_masks: FND-0046 the extracted server host is escaped too" {
  INPUT_SERVER='ftp://h%25st.example:21'
  unset INPUT_PASSWORD INPUT_USER
  run add_masks
  [ "$status" -eq 0 ]
  n=$(printf '%s\n' "$output" | grep -cxF '::add-mask::h%2525st.example' || true)
  [ "$n" -eq 1 ]
  n=$(printf '%s\n' "$output" | grep -cxF '::add-mask::ftp://h%2525st.example:21' || true)
  [ "$n" -eq 1 ]
  # No unescaped form may be registered.
  n=$(printf '%s\n' "$output" | grep -cF 'h%25st' || true)
  [ "$n" -eq 0 ]
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
  # FND-0046: the password value is never printed, even with debug.
  [[ "$output" == *"password:"*"(set, hidden)"* ]]
  [[ "$output" != *"secret"* ]]
  [[ "$output" == *"max_retries:"*"5"* ]]
  [[ "$output" == *"local_dir:"*"./public_html"* ]]
}

@test "print_inputs_dump: FND-0046 debug=true never prints the password value" {
  INPUT_PASSWORD='Hunter2-Not-In-Output'
  INPUT_SERVER="ftp://example.com"
  INPUT_USER="me"
  run print_inputs_dump "true"
  [ "$status" -eq 0 ]
  n=$(printf '%s\n' "$output" | grep -cF 'Hunter2-Not-In-Output' || true)
  [ "$n" -eq 0 ]
  n=$(printf '%s\n' "$output" | grep -cE '^  password:[ ]+\(set, hidden\)$' || true)
  [ "$n" -eq 1 ]
}

@test "print_inputs_dump: FND-0046 debug=true shows (empty) for an empty password" {
  INPUT_PASSWORD=""
  INPUT_SERVER="ftp://example.com"
  INPUT_USER="me"
  run print_inputs_dump "true"
  [ "$status" -eq 0 ]
  n=$(printf '%s\n' "$output" | grep -cE '^  password:[ ]+\(empty\)$' || true)
  [ "$n" -eq 1 ]
  n=$(printf '%s\n' "$output" | grep -cF '(set, hidden)' || true)
  [ "$n" -eq 0 ]
}

@test "print_inputs_dump: FND-0046 a multi-line password leaks no fragment in debug" {
  INPUT_PASSWORD=$'first-line-password\nsecond-line-password'
  run print_inputs_dump "true"
  [ "$status" -eq 0 ]
  n=$(printf '%s\n' "$output" | grep -cF 'line-password' || true)
  [ "$n" -eq 0 ]
  n=$(printf '%s\n' "$output" | grep -cE '^  password:[ ]+\(set, hidden\)$' || true)
  [ "$n" -eq 1 ]
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

@test "print_inputs_dump: the dump loop covers all 28 declared inputs (v2.11.8 #257 + #227)" {
  unset INPUT_SERVER INPUT_USER INPUT_PASSWORD INPUT_LOCAL_DIR INPUT_REMOTE_DIR \
        INPUT_DELETE INPUT_NO_SYMLINKS INPUT_MAX_RETRIES INPUT_MIRROR_VERBOSE \
        INPUT_FTP_SSL_ALLOW INPUT_SSL_VERIFY_CERTIFICATE INPUT_SSL_CHECK_HOSTNAME \
        INPUT_FTP_PASSIVE_MODE INPUT_FTP_USE_FEAT INPUT_FTP_NOP_INTERVAL \
        INPUT_NET_MAX_RETRIES INPUT_NET_PERSIST_RETRIES INPUT_NET_TIMEOUT \
        INPUT_DNS_MAX_RETRIES INPUT_DNS_FATAL_TIMEOUT INPUT_LFTP_SETTINGS \
        INPUT_EXCLUDE INPUT_DEBUG \
        INPUT_DRY_RUN INPUT_CONCURRENCY_LOCK \
        INPUT_CONCURRENCY_LOCK_PATH INPUT_CONCURRENCY_LOCK_TIMEOUT \
        INPUT_CONCURRENCY_LOCK_POLL_INTERVAL
  run print_inputs_dump "false"
  [ "$status" -eq 0 ]
  for name in server user password local_dir remote_dir delete max_retries \
              no_symlinks mirror_verbose ftp_ssl_allow ssl_verify_certificate \
              ssl_check_hostname ftp_passive_mode ftp_use_feat ftp_nop_interval \
              net_max_retries net_persist_retries net_timeout dns_max_retries \
              dns_fatal_timeout lftp_settings exclude debug \
              dry_run concurrency_lock \
              concurrency_lock_path concurrency_lock_timeout \
              concurrency_lock_poll_interval; do
    [[ "$output" == *"${name}:"* ]]
  done
  [[ "$output" != *"fail_on_deprecated"* ]]
}

@test "print_inputs_dump: debug=true covers all 28 declared inputs (v2.11.8 #181)" {
  # A regression that drops an input from the printf block would
  # slip past the other tests; this test locks the contract.
  unset INPUT_SERVER INPUT_USER INPUT_PASSWORD INPUT_LOCAL_DIR INPUT_REMOTE_DIR \
        INPUT_DELETE INPUT_NO_SYMLINKS INPUT_MAX_RETRIES INPUT_MIRROR_VERBOSE \
        INPUT_FTP_SSL_ALLOW INPUT_SSL_VERIFY_CERTIFICATE INPUT_SSL_CHECK_HOSTNAME \
        INPUT_FTP_PASSIVE_MODE INPUT_FTP_USE_FEAT INPUT_FTP_NOP_INTERVAL \
        INPUT_NET_MAX_RETRIES INPUT_NET_PERSIST_RETRIES INPUT_NET_TIMEOUT \
        INPUT_DNS_MAX_RETRIES INPUT_DNS_FATAL_TIMEOUT INPUT_LFTP_SETTINGS \
        INPUT_EXCLUDE INPUT_DEBUG \
        INPUT_DRY_RUN INPUT_CONCURRENCY_LOCK \
        INPUT_CONCURRENCY_LOCK_PATH INPUT_CONCURRENCY_LOCK_TIMEOUT \
        INPUT_CONCURRENCY_LOCK_POLL_INTERVAL
  run print_inputs_dump "true"
  [ "$status" -eq 0 ]
  for name in server user password local_dir remote_dir delete max_retries \
              no_symlinks mirror_verbose ftp_ssl_allow ssl_verify_certificate \
              ssl_check_hostname ftp_passive_mode ftp_use_feat ftp_nop_interval \
              net_max_retries net_persist_retries net_timeout dns_max_retries \
              dns_fatal_timeout lftp_settings exclude debug \
              dry_run concurrency_lock \
              concurrency_lock_path concurrency_lock_timeout \
              concurrency_lock_poll_interval; do
    [[ "$output" == *"${name}:"* ]]
  done
  [[ "$output" != *"fail_on_deprecated"* ]]
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

# FND-0050: with debug=true the listing of a missing or unreadable local_dir
# must not abort the script (errexit) inside the open "Resolved configuration"
# group. bats `run` disables errexit for the function, so these tests run it in
# a child shell with `set -e`. The function is POSIX sh, so dash is enough.

@test "print_resolved_config: FND-0050 a missing local_dir does not abort under set -e and closes the group" {
  missing="${BATS_TEST_TMPDIR}/no-such-dir/"
  run env LIB="${LIB}" INPUT_LOCAL_DIR="${missing}" INPUT_REMOTE_DIR="/" \
    sh -ec '. "$LIB"; print_resolved_config; echo AFTER-RC=$?'

  echo "status=${status}"; echo "${output}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(cannot list ${missing})"* ]]
  [[ "$output" == *"=== LFTP Settings ==="* ]]
  # The group is closed after the message, and the caller carries on.
  after="${output#*"(cannot list ${missing})"}"
  [[ "$after" == *"::endgroup::"* ]]
  [[ "$output" == *"AFTER-RC=0"* ]]
}

@test "print_resolved_config: FND-0050 an existing local_dir still prints the listing under set -e" {
  dir="${BATS_TEST_TMPDIR}/site"
  mkdir -p "${dir}"
  : > "${dir}/index.html"
  run env LIB="${LIB}" INPUT_LOCAL_DIR="${dir}/" INPUT_REMOTE_DIR="/" \
    sh -ec '. "$LIB"; print_resolved_config'

  [ "$status" -eq 0 ]
  [[ "$output" == *"index.html"* ]]
  [[ "$output" != *"(cannot list"* ]]
  [[ "$output" == *"::endgroup::"* ]]
}

@test "print_resolved_config: FND-0050 an unreadable local_dir does not abort under set -e" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "root bypasses directory permissions"
  fi
  dir="${BATS_TEST_TMPDIR}/locked"
  mkdir -p "${dir}"
  chmod 000 "${dir}"
  run env LIB="${LIB}" INPUT_LOCAL_DIR="${dir}/" INPUT_REMOTE_DIR="/" \
    sh -ec '. "$LIB"; print_resolved_config'
  chmod 755 "${dir}"

  echo "status=${status}"; echo "${output}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"(cannot list ${dir}/)"* ]]
  [[ "$output" == *"::endgroup::"* ]]
}

# Entrypoint level. entrypoint.sh only runs inside the image, so (as in
# lock.bats and validate.bats) the test runs a scratch copy with /app and
# /home/lftp rewritten into BATS_TEST_TMPDIR, and a fake lftp on PATH that
# fails the way the real one does for a missing directory. It runs under
# `bash -eu` (the shebang's -eu; bash because entrypoint.sh needs pipefail,
# which dash lacks). tests/smoke.sh used to run `sh ./entrypoint.sh`,
# which dropped -e, so smoke could not catch this bug (fixed in FND-0098).

_run_entrypoint_missing_local_dir() {
  local debug=$1
  local root="${BATS_TEST_DIRNAME}/../.."
  local app="${BATS_TEST_TMPDIR}/app"
  mkdir -p "${app}" "${BATS_TEST_TMPDIR}/home/lftp" "${BATS_TEST_TMPDIR}/bin"
  cp "${root}/lib.sh" "${app}/lib.sh"
  printf '0.0.0-test\n' > "${app}/VERSION"
  sed -e "s#/app/#${app}/#g" -e "s#/home/lftp#${BATS_TEST_TMPDIR}/home/lftp#g" \
    "${root}/entrypoint.sh" > "${app}/entrypoint.sh"
  cat > "${BATS_TEST_TMPDIR}/bin/lftp" <<'FAKE'
#!/bin/sh
echo "mirror: Access failed: ${FAKE_MISSING_DIR}: No such file or directory"
exit 1
FAKE
  chmod +x "${BATS_TEST_TMPDIR}/bin/lftp"
  FAKE_MISSING_DIR="${BATS_TEST_TMPDIR}/nope/" \
  PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" HOME="${BATS_TEST_TMPDIR}/home/lftp" \
  INPUT_SERVER="ftp://example.test" INPUT_USER="ftptest" INPUT_PASSWORD="pw" \
  INPUT_LOCAL_DIR="${BATS_TEST_TMPDIR}/nope/" INPUT_REMOTE_DIR="./" \
  INPUT_MAX_RETRIES="1" INPUT_DEBUG="${debug}" \
    run bash -eu "${app}/entrypoint.sh"
}

@test "entrypoint: FND-0050 debug=true with a missing local_dir reaches the lftp failure path like debug=false" {
  _run_entrypoint_missing_local_dir false
  false_status=$status
  false_output=$output
  [ "$false_status" -eq 1 ]
  [[ "$false_output" == *"Access failed"* ]]

  _run_entrypoint_missing_local_dir true
  echo "status=${status}"; echo "${output}"
  [ "$status" -eq "$false_status" ]
  [[ "$output" == *"::group::Resolved configuration"* ]]
  [[ "$output" == *"(cannot list ${BATS_TEST_TMPDIR}/nope/)"* ]]
  # The Resolved configuration group closes before the Upload group opens.
  before_upload="${output%%::group::Upload*}"
  seg="${before_upload##*::group::Resolved configuration}"
  [[ "$seg" == *"::endgroup::"* ]]
  # The lftp failure path ran: the lftp error and the failure banner.
  [[ "$output" == *"Access failed"* ]]
  [[ "$output" == *"ERROR: UPLOAD FAILED"* ]]
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

@test "print_failure_banner: emits ERROR: UPLOAD FAILED and points to the lftp output" {
  run print_failure_banner "1" "" "/home/lftp/.lftp-logs/run-20260706T193427Z.log" "5h" "30s"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: UPLOAD FAILED"* ]]
  [[ "$output" == *"Last lftp exit code: 1"* ]]
  [[ "$output" == *"The server's reply is in the lftp output above."* ]]
  [[ "$output" != *"/home/lftp/.lftp-logs"* ]]
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

@test "print_failure_banner: bare 'max-retries exceeded' prints the no-reply hint (#342)" {
  _log="${BATS_TEST_TMPDIR}/run.log"
  printf 'Try #1\nmirror: Fatal error: max-retries exceeded\n' > "${_log}"
  run print_failure_banner "1" "" "${_log}" "5h" "30s"
  [ "$status" -eq 1 ]
  [[ "$output" == *"lftp got no reply from the server"* ]]
  [[ "$output" == *"firewall"* ]]
  [[ "$output" != *"The server's reply is in the lftp output above."* ]]
}

@test "print_failure_banner: 'max-retries exceeded (Connection refused)' keeps the default line" {
  _log="${BATS_TEST_TMPDIR}/run.log"
  printf 'mirror: Fatal error: max-retries exceeded (Connection refused)\n' > "${_log}"
  run print_failure_banner "1" "" "${_log}" "5h" "30s"
  [ "$status" -eq 1 ]
  [[ "$output" != *"no reply from the server"* ]]
  [[ "$output" == *"The server's reply is in the lftp output above."* ]]
}

@test "print_failure_banner: PERMANENT error never prints the no-reply hint" {
  _log="${BATS_TEST_TMPDIR}/run.log"
  printf 'mirror: Login failed: 530 Login incorrect.\nmirror: Fatal error: max-retries exceeded\n' > "${_log}"
  run print_failure_banner "1" "true" "${_log}" "5h" "30s"
  [ "$status" -eq 1 ]
  [[ "$output" != *"no reply from the server"* ]]
}

@test "print_failure_banner: missing log file keeps the default line" {
  run print_failure_banner "1" "" "${BATS_TEST_TMPDIR}/does-not-exist.log" "5h" "30s"
  [ "$status" -eq 1 ]
  [[ "$output" == *"The server's reply is in the lftp output above."* ]]
}
