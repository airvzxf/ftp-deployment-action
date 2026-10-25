#!/usr/bin/env bats
# tests/unit/parse.bats — unit tests for the parser/builder functions
# in lib.sh: extract_netrc_host, build_ftp_settings,
# build_mirror_command, normalize_dir, _indirection, and the .netrc
# writer write_netrc.

setup() {
  set +u
  LIB="${BATS_TEST_DIRNAME}/../../lib.sh"
  # shellcheck disable=SC1090
  . "${LIB}"
}

# ----------------------------------------------------------------------------
# _indirection
# ----------------------------------------------------------------------------

@test "_indirection returns the value of a set variable" {
  INPUT_FOO="bar"
  run _indirection "INPUT_FOO"
  [ "$status" -eq 0 ]
  [ "$output" = "bar" ]
}

@test "_indirection returns empty for an unset variable" {
  unset INPUT_UNSET || true
  run _indirection "INPUT_UNSET"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ----------------------------------------------------------------------------
# extract_netrc_host
# ----------------------------------------------------------------------------

@test "extract_netrc_host: ftp://host -> host" {
  run extract_netrc_host "ftp://example.com"
  [ "$status" -eq 0 ]
  [ "$output" = "example.com" ]
}

@test "extract_netrc_host: ftp://user:pw@host:21 -> host" {
  run extract_netrc_host "ftp://user:pw@example.com:21"
  [ "$status" -eq 0 ]
  [ "$output" = "example.com" ]
}

@test "extract_netrc_host: ftps://[::1]:990 -> ::1" {
  run extract_netrc_host "ftps://[::1]:990"
  [ "$status" -eq 0 ]
  [ "$output" = "::1" ]
}

@test "extract_netrc_host: ftps://[::1] -> ::1" {
  run extract_netrc_host "ftps://[::1]"
  [ "$status" -eq 0 ]
  [ "$output" = "::1" ]
}

@test "extract_netrc_host: bare host (no scheme) -> host" {
  run extract_netrc_host "example.com"
  [ "$status" -eq 0 ]
  [ "$output" = "example.com" ]
}

@test "extract_netrc_host: ftp://host/path -> host" {
  run extract_netrc_host "ftp://example.com/some/path"
  [ "$status" -eq 0 ]
  [ "$output" = "example.com" ]
}

@test "extract_netrc_host: ftp://host?query -> host (v2.11.8 #185)" {
  run extract_netrc_host "ftp://example.com?token=abc"
  [ "$status" -eq 0 ]
  [ "$output" = "example.com" ]
}

@test "extract_netrc_host: ftp://host#frag -> host (v2.11.8 #185)" {
  run extract_netrc_host "ftp://example.com#section"
  [ "$status" -eq 0 ]
  [ "$output" = "example.com" ]
}

@test "extract_netrc_host: ftp://host:21?query -> host (v2.11.8 #185)" {
  run extract_netrc_host "ftp://example.com:21?token=abc"
  [ "$status" -eq 0 ]
  [ "$output" = "example.com" ]
}

@test "extract_netrc_host: ftps://[::1]:990?query -> ::1 (v2.11.8 #185)" {
  run extract_netrc_host "ftps://[::1]:990?x=1"
  [ "$status" -eq 0 ]
  [ "$output" = "::1" ]
}

@test "extract_netrc_host: ftp://user:pw@host?query -> host (v2.11.8 #185 + userinfo)" {
  run extract_netrc_host "ftp://deploy:plaintext@example.com?token=abc"
  [ "$status" -eq 0 ]
  [ "$output" = "example.com" ]
}

# v2.11.11 (#182): close the coverage gaps for URL forms
# that flow through extract_netrc_host into the .netrc
# "machine" line. RFC 6874 zone-id is the only genuinely
# missing case (query / fragment / userinfo were covered by
# the v2.11.8 #185 batch at tests/unit/parse.bats:71-99).
# Path-prefix + query/fragment combos are included here as
# belt-and-braces coverage: they are already implicitly
# covered, but pinning the exact behaviour mechanically in
# the test suite makes a future sed-regex regression fail
# loudly rather than silently producing an empty "machine"
# line and a confusing 530 Login authentication failed
# downstream.

@test "extract_netrc_host: ftp://host/path?query -> host (v2.11.11 #182, path+query)" {
  run extract_netrc_host "ftp://example.com/some/path?token=abc"
  [ "$status" -eq 0 ]
  [ "$output" = "example.com" ]
}

@test "extract_netrc_host: ftp://host/path#frag -> host (v2.11.11 #182, path+fragment)" {
  run extract_netrc_host "ftp://example.com/some/path#section"
  [ "$status" -eq 0 ]
  [ "$output" = "example.com" ]
}

@test "extract_netrc_host: ftp://user:pw@host/path -> host (v2.11.11 #182, userinfo+path)" {
  run extract_netrc_host "ftp://deploy:plaintext@example.com/some/path"
  [ "$status" -eq 0 ]
  [ "$output" = "example.com" ]
}

@test "extract_netrc_host: ftps://[fe80::1%25eth0]/path -> fe80::1%25eth0 (v2.11.11 #182, IPv6 zone-id)" {
  # RFC 6874: the zone-id in a URL is %25-encoded so the '%'
  # is not misread as a percent-escape. extract_netrc_host
  # must preserve the zone-id verbatim in the .netrc
  # "machine" line. `%` is not a sed metacharacter inside a
  # bracket character class, so the existing regex in
  # extract_netrc_host preserves it correctly.
  run extract_netrc_host "ftps://[fe80::1%25eth0]/path"
  [ "$status" -eq 0 ]
  [ "$output" = "fe80::1%25eth0" ]
}

# ----------------------------------------------------------------------------
# build_ftp_settings
# ----------------------------------------------------------------------------

@test "build_ftp_settings: with all defaults produces 11 set directives" {
  unset INPUT_FTP_SSL_ALLOW INPUT_SSL_VERIFY_CERTIFICATE INPUT_SSL_CHECK_HOSTNAME \
        INPUT_FTP_PASSIVE_MODE INPUT_FTP_USE_FEAT INPUT_FTP_NOP_INTERVAL \
        INPUT_NET_MAX_RETRIES INPUT_NET_PERSIST_RETRIES INPUT_NET_TIMEOUT \
        INPUT_DNS_MAX_RETRIES INPUT_DNS_FATAL_TIMEOUT INPUT_LFTP_SETTINGS
  run build_ftp_settings
  [ "$status" -eq 0 ]
  # Count 'set ' occurrences. There should be exactly 11 (no
  # lftp_settings extension): ftp:ssl-allow, ssl:verify-certificate,
  # ssl:check-hostname, ftp:passive-mode, ftp:use-feat,
  # ftp:nop-interval, net:max-retries, net:persist-retries,
  # net:timeout, dns:max-retries, dns:fatal-timeout.
  n=$(printf '%s' "$output" | grep -oE 'set ' | wc -l | tr -d ' ')
  [ "$n" -eq 11 ]
  # Spot-check the documented v2 defaults.
  [[ "$output" == *"set ssl:verify-certificate true;"* ]]
  [[ "$output" == *"set net:timeout 15s;"* ]]
  [[ "$output" == *"set dns:fatal-timeout 10s;"* ]]
}

@test "build_ftp_settings: an empty INPUT_FTP_SSL_ALLOW falls back to default" {
  unset INPUT_FTP_SSL_ALLOW
  INPUT_FTP_SSL_ALLOW=""
  unset INPUT_SSL_VERIFY_CERTIFICATE INPUT_SSL_CHECK_HOSTNAME \
        INPUT_FTP_PASSIVE_MODE INPUT_FTP_USE_FEAT INPUT_FTP_NOP_INTERVAL \
        INPUT_NET_MAX_RETRIES INPUT_NET_PERSIST_RETRIES INPUT_NET_TIMEOUT \
        INPUT_DNS_MAX_RETRIES INPUT_DNS_FATAL_TIMEOUT INPUT_LFTP_SETTINGS
  run build_ftp_settings
  [ "$status" -eq 0 ]
  [[ "$output" == *"set ftp:ssl-allow true;"* ]]
}

@test "build_ftp_settings: an explicit INPUT_FTP_SSL_ALLOW=false is preserved" {
  unset INPUT_FTP_SSL_ALLOW
  INPUT_FTP_SSL_ALLOW="false"
  unset INPUT_SSL_VERIFY_CERTIFICATE INPUT_SSL_CHECK_HOSTNAME \
        INPUT_FTP_PASSIVE_MODE INPUT_FTP_USE_FEAT INPUT_FTP_NOP_INTERVAL \
        INPUT_NET_MAX_RETRIES INPUT_NET_PERSIST_RETRIES INPUT_NET_TIMEOUT \
        INPUT_DNS_MAX_RETRIES INPUT_DNS_FATAL_TIMEOUT INPUT_LFTP_SETTINGS
  run build_ftp_settings
  [ "$status" -eq 0 ]
  [[ "$output" == *"set ftp:ssl-allow false;"* ]]
}

@test "build_ftp_settings: lftp_settings is appended without leading space" {
  unset INPUT_FTP_SSL_ALLOW INPUT_SSL_VERIFY_CERTIFICATE INPUT_SSL_CHECK_HOSTNAME \
        INPUT_FTP_PASSIVE_MODE INPUT_FTP_USE_FEAT INPUT_FTP_NOP_INTERVAL \
        INPUT_NET_MAX_RETRIES INPUT_NET_PERSIST_RETRIES INPUT_NET_TIMEOUT \
        INPUT_DNS_MAX_RETRIES INPUT_DNS_FATAL_TIMEOUT
  INPUT_LFTP_SETTINGS="set cmd:status-interval 1s"
  run build_ftp_settings
  [ "$status" -eq 0 ]
  [[ "$output" == *"set cmd:status-interval 1s;"* ]]
  # The first character should not be a space.
  first_char=$(printf '%s' "$output" | head -c 1)
  [ "$first_char" = "s" ]
}

# ----------------------------------------------------------------------------
# build_ftp_settings: exclude is a mirror option, not a `set` directive
# ----------------------------------------------------------------------------

@test "build_ftp_settings: with empty INPUT_EXCLUDE produces 11 directives (no exclude injection)" {
  unset INPUT_FTP_SSL_ALLOW INPUT_SSL_VERIFY_CERTIFICATE INPUT_SSL_CHECK_HOSTNAME \
        INPUT_FTP_PASSIVE_MODE INPUT_FTP_USE_FEAT INPUT_FTP_NOP_INTERVAL \
        INPUT_NET_MAX_RETRIES INPUT_NET_PERSIST_RETRIES INPUT_NET_TIMEOUT \
        INPUT_DNS_MAX_RETRIES INPUT_DNS_FATAL_TIMEOUT INPUT_LFTP_SETTINGS \
        INPUT_EXCLUDE
  run build_ftp_settings
  [ "$status" -eq 0 ]
  n=$(printf '%s' "$output" | grep -oE 'set ' | wc -l | tr -d ' ')
  [ "$n" -eq 11 ]
  [[ "$output" != *"mirror:exclude"* ]]
}

@test "build_ftp_settings: INPUT_EXCLUDE does not emit a `set mirror:exclude*` directive (it is a build_mirror_command option)" {
  unset INPUT_FTP_SSL_ALLOW INPUT_SSL_VERIFY_CERTIFICATE INPUT_SSL_CHECK_HOSTNAME \
        INPUT_FTP_PASSIVE_MODE INPUT_FTP_USE_FEAT INPUT_FTP_NOP_INTERVAL \
        INPUT_NET_MAX_RETRIES INPUT_NET_PERSIST_RETRIES INPUT_NET_TIMEOUT \
        INPUT_DNS_MAX_RETRIES INPUT_DNS_FATAL_TIMEOUT INPUT_LFTP_SETTINGS
  INPUT_EXCLUDE="*.map, *.bak"
  run build_ftp_settings
  [ "$status" -eq 0 ]
  [[ "$output" != *"mirror:exclude"* ]]
  n=$(printf '%s' "$output" | grep -oE 'set ' | wc -l | tr -d ' ')
  [ "$n" -eq 11 ]
}

# ----------------------------------------------------------------------------
# build_mirror_command
# ----------------------------------------------------------------------------

@test "build_mirror_command: defaults produce 'mirror --continue --reverse --verbose=1'" {
  unset INPUT_MIRROR_VERBOSE INPUT_NO_SYMLINKS INPUT_DELETE INPUT_DRY_RUN
  run build_mirror_command
  [ "$status" -eq 0 ]
  [ "$output" = "mirror --continue --reverse --verbose=1" ]
}

@test "build_mirror_command: --verbose=2 when INPUT_MIRROR_VERBOSE=2" {
  INPUT_MIRROR_VERBOSE="2"
  unset INPUT_NO_SYMLINKS INPUT_DELETE INPUT_DRY_RUN
  run build_mirror_command
  [ "$status" -eq 0 ]
  [ "$output" = "mirror --continue --reverse --verbose=2" ]
}

@test "build_mirror_command: --no-symlinks when INPUT_NO_SYMLINKS=true" {
  unset INPUT_MIRROR_VERBOSE
  INPUT_NO_SYMLINKS="true"
  unset INPUT_DELETE INPUT_DRY_RUN
  run build_mirror_command
  [ "$status" -eq 0 ]
  [ "$output" = "mirror --continue --reverse --verbose=1 --no-symlinks" ]
}

@test "build_mirror_command: --delete when INPUT_DELETE=true" {
  unset INPUT_MIRROR_VERBOSE INPUT_NO_SYMLINKS
  INPUT_DELETE="true"
  unset INPUT_DRY_RUN
  run build_mirror_command
  [ "$status" -eq 0 ]
  [ "$output" = "mirror --continue --reverse --verbose=1 --delete" ]
}

@test "build_mirror_command: NOOP check + --dry-run when INPUT_DRY_RUN=true" {
  unset INPUT_MIRROR_VERBOSE INPUT_NO_SYMLINKS INPUT_DELETE
  INPUT_DRY_RUN="true"
  run build_mirror_command
  [ "$status" -eq 0 ]
  [ "$output" = "quote NOOP > /dev/null && mirror --continue --reverse --verbose=1 --dry-run" ]
}

@test "build_mirror_command: all flags together" {
  INPUT_MIRROR_VERBOSE="3"
  INPUT_NO_SYMLINKS="true"
  INPUT_DELETE="true"
  INPUT_DRY_RUN="true"
  run build_mirror_command
  [ "$status" -eq 0 ]
  [ "$output" = "quote NOOP > /dev/null && mirror --continue --reverse --verbose=3 --no-symlinks --delete --dry-run" ]
}

@test "build_mirror_command: INPUT_EXCLUDE='*.map' stays literal when the cwd has a.map" {
  # Without `set -f` around the comma split, `*.map` expands against
  # the cwd and the command becomes `-X a.map`.
  _trap_dir=$(mktemp -d)
  touch "${_trap_dir}/a.map"
  cd "${_trap_dir}"
  unset INPUT_MIRROR_VERBOSE INPUT_NO_SYMLINKS INPUT_DELETE INPUT_DRY_RUN
  INPUT_EXCLUDE='*.map'
  run build_mirror_command
  cd "${BATS_TEST_DIRNAME}/../.."
  rm -rf "${_trap_dir}"
  [ "$status" -eq 0 ]
  [ "$output" = "mirror --continue --reverse --verbose=1 -X *.map" ]
}

# ----------------------------------------------------------------------------
# normalize_dir
# ----------------------------------------------------------------------------

@test "normalize_dir: empty input -> './'" {
  run normalize_dir ""
  [ "$status" -eq 0 ]
  [ "$output" = "./" ]
}

@test "normalize_dir: '/www/x' -> '/www/x/'" {
  run normalize_dir "/www/x"
  [ "$status" -eq 0 ]
  [ "$output" = "/www/x/" ]
}

@test "normalize_dir: '/www/x/' (already trailing slash) -> '/www/x/' (idempotent)" {
  run normalize_dir "/www/x/"
  [ "$status" -eq 0 ]
  [ "$output" = "/www/x/" ]
}

@test "normalize_dir: './public_html' -> './public_html/'" {
  run normalize_dir "./public_html"
  [ "$status" -eq 0 ]
  [ "$output" = "./public_html/" ]
}

@test "normalize_dir: does NOT validate the path (caller's job)" {
  # normalize_dir is pure normalization; the caller runs
  # validate_path in the main shell context. A path-traversal
  # value here must NOT exit 2 (the function would not be
  # testable in a unit test if it did).
  run normalize_dir "../../etc"
  [ "$status" -eq 0 ]
  [ "$output" = "../../etc/" ]
}

# F2 audit (#334, follow-up to #330): build_ftp_settings default for
# net:max-retries is 1 (reverted from the v2.11.14 #330 default of 0).
# The #330 default of 0 preserved the FIRST attempt's server error
# (e.g. "530 Login authentication failed") in the lftp log for
# classify_permanent_error, but it broke the integration tests:
# scenarios 07 / 08 / 09 / 10 / 11 / 12 all set INPUT_REMOTE_DIR=/,
# and lftp's `mirror -R local/ /` preflights with `MKD /` which
# vsftpd / proftpd / pure-ftpd reject with `550 Create directory
# operation failed`. With net:max-retries=0 lftp entered an infinite
# `net:persist-retries=5 × reconnect` loop on that 550 and the
# action's `run_lftp_once` wrapper hung for the 5-minute CI job
# timeout. With net:max-retries=1 lftp's mirror aborts the retry
# loop after the first failed MKD attempt (treats the 550 as
# "dir already exists", which is correct for a root MKD), the
# action's outer INPUT_MAX_RETRIES loop retries the whole command,
# and the mirror eventually succeeds. The #330 trade-off (the FIRST
# attempt's 530 can be overwritten by the retry's `max-retries
# exceeded` line in the lftp log) is accepted because the integration
# tests were red on every CI run for 21 days. TODO(#330): revisit
# once lftp grows a flag to surface the first attempt's error AND
# let mirror skip the MKD-on-root preflight.
@test "build_ftp_settings: net:max-retries default is 1 (v2.11.14 #334, follow-up to #330)" {
  unset INPUT_FTP_SSL_ALLOW INPUT_SSL_VERIFY_CERTIFICATE INPUT_SSL_CHECK_HOSTNAME INPUT_FTP_PASSIVE_MODE INPUT_FTP_USE_FEAT INPUT_FTP_NOP_INTERVAL INPUT_NET_MAX_RETRIES INPUT_NET_PERSIST_RETRIES INPUT_NET_TIMEOUT INPUT_DNS_MAX_RETRIES INPUT_DNS_FATAL_TIMEOUT INPUT_LFTP_SETTINGS
  out=$(build_ftp_settings)
  echo "$out" | grep -q "set net:max-retries 1;" \
    || { echo "FAIL: net:max-retries default is not 1; got: $out"; return 1; }
}

# ----------------------------------------------------------------------------
# write_netrc (FND-0048)
#
# write_netrc installs an EXIT trap, so every test calls it in a child
# `sh -eu -c` (the entrypoint's own errexit/nounset) and never in the
# bats shell, whose EXIT trap it would replace.
#
# A `chmod` shell function stands in for the real one and prints the
# file's mode and the EXIT trap before it runs `command chmod`. The
# chmod 600 is the last step of write_netrc, so the stub sees the file
# exactly as the write left it: the mode it was created (or reopened)
# with, i.e. the mode it had while the password was in it. Checking
# only the final mode could not fail, because the chmod 600 fixes it
# up either way.
# ----------------------------------------------------------------------------

# Prints "write-mode=<mode>", "trap=<trap -p EXIT output>",
# "final-mode=<mode>" and then the file contents, all from inside the
# child shell (the EXIT trap removes the file when it exits).
_wn_run() {
  run sh -eu -c '
    . "$1"
    umask 022
    chmod() {
      printf "write-mode=%s\n" "$(stat -c %a "$2")"
      printf "trap=%s\n" "$(trap -p EXIT)"
      command chmod "$@"
    }
    write_netrc "$2" example.com deploy "p@ss w0rd"
    printf "final-mode=%s\n" "$(stat -c %a "$2")"
    cat "$2"
  ' _ "${LIB}" "$1"
}

@test "write_netrc: under umask 022 the file is already 0600 when the password is written" {
  netrc="${BATS_TEST_TMPDIR}/netrc"
  _wn_run "${netrc}"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "write-mode=600" ]
  [ "${lines[2]}" = "final-mode=600" ]
}

@test "write_netrc: a pre-existing 0644 file is replaced, never written while 0644" {
  netrc="${BATS_TEST_TMPDIR}/netrc"
  printf 'OLD-CONTENT-THAT-IS-LONGER-THAN-THE-NEW-LINE-%s\nsecond old line\n' \
    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" > "${netrc}"
  chmod 644 "${netrc}"
  [ "$(stat -c %a "${netrc}")" = "644" ]
  _wn_run "${netrc}"
  [ "$status" -eq 0 ]
  # A `>` redirection keeps an existing file's mode, so without the
  # rm -f the password would be written into the 0644 file.
  [ "${lines[0]}" = "write-mode=600" ]
  [ "${lines[2]}" = "final-mode=600" ]
  [ "${#lines[@]}" -eq 4 ]
  [ "${lines[3]}" = "machine example.com login deploy password p@ss w0rd" ]
  [[ "$output" != *OLD-CONTENT* ]]
}

@test "write_netrc: writes the single machine/login/password line unchanged" {
  netrc="${BATS_TEST_TMPDIR}/netrc"
  _wn_run "${netrc}"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
  [ "${lines[3]}" = "machine example.com login deploy password p@ss w0rd" ]
}

@test "write_netrc: the cleanup trap is installed before the write and removes the file on exit" {
  netrc="${BATS_TEST_TMPDIR}/netrc"
  _wn_run "${netrc}"
  [ "$status" -eq 0 ]
  # The stub runs after the write: the trap must already be there.
  [[ "${lines[1]}" == "trap="*"rm -f"*"EXIT" ]]
  [ ! -e "${netrc}" ]
}

@test "write_netrc: the trap removes the file when errexit aborts the caller" {
  netrc="${BATS_TEST_TMPDIR}/netrc"
  run sh -eu -c '
    . "$1"
    write_netrc "$2" example.com deploy pw
    [ -f "$2" ] || exit 3
    false
  ' _ "${LIB}" "${netrc}"
  [ "$status" -eq 1 ]
  [ ! -e "${netrc}" ]
}

@test "write_netrc: if the old file cannot be removed it fails and does not write into it" {
  if [ "$(id -u)" -eq 0 ]; then
    skip "root ignores the read-only directory"
  fi
  dir="${BATS_TEST_TMPDIR}/ro"
  mkdir "${dir}"
  netrc="${dir}/netrc"
  printf 'old\n' > "${netrc}"
  chmod 666 "${netrc}"
  chmod 555 "${dir}"
  run sh -eu -c '
    . "$1"
    write_netrc "$2" example.com deploy pw
    echo reached-after-write_netrc
  ' _ "${LIB}" "${netrc}"
  chmod 755 "${dir}"
  [ "$status" -ne 0 ]
  [[ "$output" != *reached-after-write_netrc* ]]
  [ "$(cat "${netrc}")" = "old" ]
}
