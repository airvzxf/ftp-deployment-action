#!/usr/bin/env bats
# tests/unit/parse.bats — unit tests for the parser/builder functions
# in lib.sh: extract_netrc_host, build_ftp_settings,
# build_mirror_command, normalize_dir, _indirection.

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

@test "build_mirror_command: --dry-run when INPUT_DRY_RUN=true" {
  unset INPUT_MIRROR_VERBOSE INPUT_NO_SYMLINKS INPUT_DELETE
  INPUT_DRY_RUN="true"
  run build_mirror_command
  [ "$status" -eq 0 ]
  [ "$output" = "mirror --continue --reverse --verbose=1 --dry-run" ]
}

@test "build_mirror_command: all flags together" {
  INPUT_MIRROR_VERBOSE="3"
  INPUT_NO_SYMLINKS="true"
  INPUT_DELETE="true"
  INPUT_DRY_RUN="true"
  run build_mirror_command
  [ "$status" -eq 0 ]
  [ "$output" = "mirror --continue --reverse --verbose=3 --no-symlinks --delete --dry-run" ]
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
