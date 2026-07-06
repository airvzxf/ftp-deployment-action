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
