#!/usr/bin/env bats
# tests/unit/validate.bats — unit tests for the validator functions
# in lib.sh: validate_int, validate_path, validate_lftp_settings.
#
# bats is bash + tap. Each `@test` block is a function that returns
# non-zero on failure. The shared setup() sources lib.sh in a clean
# environment (no INPUT_* set, set -u off) so the validators can be
# called with explicit arguments.

setup() {
  # Source the library under test. We disable set -u in this shell
  # so unset INPUT_* don't trigger errexit. The lib.sh functions
  # themselves use set -u-safe patterns (e.g. ${VAR-}).
  set +u
  LIB="${BATS_TEST_DIRNAME}/../../lib.sh"
  # shellcheck disable=SC1090
  . "${LIB}"
}

# ----------------------------------------------------------------------------
# validate_int
# ----------------------------------------------------------------------------

@test "validate_int accepts a positive integer" {
  run validate_int "max_retries" "10"
  [ "$status" -eq 0 ]
}

@test "validate_int accepts 0 (the retry-forever sentinel)" {
  run validate_int "max_retries" "0"
  [ "$status" -eq 0 ]
}

@test "validate_int rejects a non-numeric value with exit 2" {
  run validate_int "max_retries" "abc"
  [ "$status" -eq 2 ]
  [[ "$output" == *"max_retries must be a non-negative integer"* ]]
}

@test "validate_int rejects an empty string with exit 2" {
  run validate_int "max_retries" ""
  [ "$status" -eq 2 ]
  [[ "$output" == *"max_retries must be a non-negative integer"* ]]
}

@test "validate_int rejects a value with letters" {
  run validate_int "max_retries" "10s"
  [ "$status" -eq 2 ]
}

@test "validate_int rejects a negative integer with exit 2" {
  run validate_int "max_retries" "-1"
  [ "$status" -eq 2 ]
}

@test "validate_int rejects a float with exit 2" {
  run validate_int "max_retries" "1.5"
  [ "$status" -eq 2 ]
}

# ----------------------------------------------------------------------------
# validate_path
# ----------------------------------------------------------------------------

@test "validate_path accepts a simple relative path" {
  run validate_path "local_dir" "./public_html/"
  [ "$status" -eq 0 ]
}

@test "validate_path accepts a simple absolute path" {
  run validate_path "remote_dir" "/www/user/home/"
  [ "$status" -eq 0 ]
}

@test "validate_path accepts './'" {
  run validate_path "local_dir" "./"
  [ "$status" -eq 0 ]
}

@test "validate_path rejects a '..' path-traversal component" {
  run validate_path "local_dir" "../../etc/"
  [ "$status" -eq 2 ]
  [[ "$output" == *"local_dir contains \"..\" path traversal"* ]]
}

@test "validate_path rejects a '..' in the middle of the path" {
  run validate_path "remote_dir" "/foo/../bar/"
  [ "$status" -eq 2 ]
}

@test "validate_path rejects a leading dash (would be misread as lftp option)" {
  run validate_path "local_dir" "-rf"
  [ "$status" -eq 2 ]
  [[ "$output" == *"starts with a dash"* ]]
}

@test "validate_path rejects control characters" {
  # Use a tab (0x09) as the control character. Newlines would
  # be split into separate lines by grep, and grep's [:cntrl:]
  # would not match the newline between them.
  run validate_path "local_dir" $'foo\tbar'
  [ "$status" -eq 2 ]
  [[ "$output" == *"control characters"* ]]
}

@test "validate_path rejects the ';' shell metacharacter" {
  run validate_path "local_dir" "foo;rm -rf /"
  [ "$status" -eq 2 ]
  [[ "$output" == *"forbidden shell metacharacter"* ]]
}

@test "validate_path rejects the '&' shell metacharacter" {
  run validate_path "local_dir" "foo&bar"
  [ "$status" -eq 2 ]
}

@test "validate_path rejects the '|' shell metacharacter" {
  run validate_path "local_dir" "foo|bar"
  [ "$status" -eq 2 ]
}

@test "validate_path rejects the backtick shell substitution" {
  run validate_path "local_dir" 'foo`whoami`'
  [ "$status" -eq 2 ]
}

@test "validate_path rejects the dollar shell substitution" {
  run validate_path "local_dir" 'foo$HOME'
  [ "$status" -eq 2 ]
  [[ "$output" == *"dollar"* ]]
}

@test "validate_path rejects '!' (lftp shell escape — v2.11.3 #172)" {
  run validate_path "local_dir" 'foo!cat /home/lftp/.netrc'
  [ "$status" -eq 2 ]
  [[ "$output" == *"\"!\""* ]]
}

@test "validate_path rejects double-quote (lftp command parsing — v2.11.3 #172)" {
  run validate_path "remote_dir" 'foo"; cls; quit;'
  [ "$status" -eq 2 ]
  [[ "$output" == *"double-quote"* ]]
}

# ----------------------------------------------------------------------------
# validate_bool — v2.11.3 (#171)
# ----------------------------------------------------------------------------

@test "validate_bool accepts the documented canonical set" {
  for v in true false yes no on off 0 1 ""; do
    run validate_bool "ftp_ssl_allow" "$v"
    [ "$status" -eq 0 ]
  done
}

@test "validate_bool rejects a malicious payload containing '!' (RCE via lftp -e)" {
  run validate_bool "ftp_ssl_allow" 'true; !cat /home/lftp/.netrc'
  [ "$status" -eq 2 ]
  [[ "$output" == *"ftp_ssl_allow must be a bool"* ]]
}

@test "validate_bool rejects a value with a leading semicolon" {
  run validate_bool "ssl_check_hostname" '; !uname'
  [ "$status" -eq 2 ]
}

@test "validate_bool rejects a capitalised value" {
  run validate_bool "ssl_verify_certificate" "True"
  [ "$status" -eq 2 ]
}

@test "validate_bool rejects a numeric string with a suffix" {
  run validate_bool "ftp_use_feat" "1s"
  [ "$status" -eq 2 ]
}

# ----------------------------------------------------------------------------
# validate_duration — v2.11.3 (#171)
# ----------------------------------------------------------------------------

@test "validate_duration accepts the empty string (default applies)" {
  run validate_duration "net_timeout" ""
  [ "$status" -eq 0 ]
}

@test "validate_duration accepts 'never' (lftp's documented disable sentinel)" {
  run validate_duration "dns_fatal_timeout" "never"
  [ "$status" -eq 0 ]
}

@test "validate_duration accepts digits with s/m/h/d (case-insensitive)" {
  for v in 15 15s 5m 1h 2d 30S 5M 1H 1D; do
    run validate_duration "net_timeout" "$v"
    [ "$status" -eq 0 ]
  done
}

@test "validate_duration rejects unit-only and repeated-unit values" {
  for v in s mhd 5s5m dd 15ss; do
    run validate_duration "net_timeout" "$v"
    [ "$status" -eq 2 ]
    [[ "$output" == *"net_timeout must be a duration"* ]]
  done
}

@test "validate_duration rejects a malicious payload containing '; !'" {
  run validate_duration "net_timeout" '15s; !cat /home/lftp/.netrc'
  [ "$status" -eq 2 ]
  [[ "$output" == *"net_timeout must be a duration"* ]]
}

@test "validate_duration rejects a float" {
  run validate_duration "dns_fatal_timeout" "1.5"
  [ "$status" -eq 2 ]
}

@test "validate_duration rejects a value with embedded text" {
  run validate_duration "net_timeout" "1abc"
  [ "$status" -eq 2 ]
}

@test "validate_duration rejects a negative value" {
  run validate_duration "net_timeout" "-1"
  [ "$status" -eq 2 ]
}

# ----------------------------------------------------------------------------
# validate_glob_pattern — v2.11.3 (#160)
# ----------------------------------------------------------------------------

@test "validate_glob_pattern accepts a simple glob" {
  run validate_glob_pattern "exclude" "*.bak"
  [ "$status" -eq 0 ]
}

@test "validate_glob_pattern accepts a regex with '!' (the over-rejection v2.11.3 fixes)" {
  run validate_glob_pattern "exclude" '!important\.txt'
  [ "$status" -eq 0 ]
}

@test "validate_glob_pattern accepts a glob with backtick, dollar, !, space" {
  # v2.11.3.1 (post-release F2 audit): the v2.11.3 fix accepted `;`
  # and `"` on the premise that the value is "a single argv slot
  # to mirror, never parsed by a shell". That premise was wrong:
  # build_mirror_command concatenates the value unquoted into the
  # `lftp -e` script body, and lftp 4.9.3's parser treats `;`, `&`,
  # `|`, and `"` as command separators / string delimiters even
  # mid-token. So `;`, `&`, `|`, `"` are now rejected (alongside
  # leading-dash and control chars); backtick, dollar, `!`, and
  # space remain accepted as legitimate PatternSet / regex
  # metacharacters.
  run validate_glob_pattern "exclude" 'foo$bar`baz!qux and a space'
  [ "$status" -eq 0 ]
}

@test "validate_glob_pattern rejects semicolon (lftp -e command separator)" {
  run validate_glob_pattern "exclude" 'foo;echo X;quit'
  [ "$status" -eq 2 ]
  [[ "$output" == *"lftp command separator"* ]]
}

@test "validate_glob_pattern rejects ampersand and pipe" {
  run validate_glob_pattern "exclude" 'foo&bar'
  [ "$status" -eq 2 ]
  run validate_glob_pattern "exclude" 'foo|bar'
  [ "$status" -eq 2 ]
}

@test "validate_glob_pattern rejects double-quote (lftp string delimiter)" {
  run validate_glob_pattern "exclude_delete" '"X"'
  [ "$status" -eq 2 ]
}

@test "validate_glob_pattern accepts an empty string" {
  run validate_glob_pattern "exclude_delete" ""
  [ "$status" -eq 0 ]
}

@test "validate_glob_pattern rejects newline" {
  # v2.11.3.1: grep's POSIX [:cntrl:] never matches \n (grep
  # splits on \n before matching), so the v2.11.3 implementation
  # was incomplete. Add an explicit newline check via case.
  run validate_glob_pattern "exclude" 'foo
bar'
  [ "$status" -eq 2 ]
}

@test "validate_glob_pattern rejects a leading dash (would be misread as mirror option)" {
  run validate_glob_pattern "exclude" "-rf"
  [ "$status" -eq 2 ]
  [[ "$output" == *"starts with a dash"* ]]
}

# ----------------------------------------------------------------------------
# validate_lftp_settings
# ----------------------------------------------------------------------------

@test "validate_lftp_settings accepts the empty string" {
  run validate_lftp_settings ""
  [ "$status" -eq 0 ]
}

@test "validate_lftp_settings accepts 1 ';' chained directive" {
  run validate_lftp_settings "set cache:cache-empty-listings true;"
  [ "$status" -eq 0 ]
}

@test "validate_lftp_settings accepts 3 ';' chained directives (documented max)" {
  run validate_lftp_settings "set a:1; set b:2; set c:3;"
  [ "$status" -eq 0 ]
}

@test "validate_lftp_settings rejects 4 ';' chained directives" {
  run validate_lftp_settings "set a:1; set b:2; set c:3; set d:4;"
  [ "$status" -eq 2 ]
  [[ "$output" == *"\";\" characters (max 3)"* ]]
}

@test "validate_lftp_settings rejects control characters" {
  # Use a tab; see the note in validate_path's control-character
  # test for why newlines would not be caught.
  run validate_lftp_settings $'set foo:bar\t'
  [ "$status" -eq 2 ]
  [[ "$output" == *"control characters"* ]]
}

@test "validate_lftp_settings rejects backtick" {
  run validate_lftp_settings "set foo:\`uname\`"
  [ "$status" -eq 2 ]
  [[ "$output" == *"backtick"* ]]
}

@test "validate_lftp_settings rejects dollar" {
  run validate_lftp_settings "set foo:\$HOME"
  [ "$status" -eq 2 ]
  [[ "$output" == *"dollar"* ]]
}

@test "validate_lftp_settings rejects '!' (lftp shell escape)" {
  run validate_lftp_settings "set x:y; !uname; set a:b"
  [ "$status" -eq 2 ]
  [[ "$output" == *"\"!\""* ]]
}
