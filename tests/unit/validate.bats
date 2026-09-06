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

@test "validate_int rejects 00 (leading zeros would break retry-forever sentinel)" {
  run validate_int "max_retries" "00"
  [ "$status" -eq 2 ]
  [[ "$output" == *"without leading zeros"* ]]
}

@test "validate_int rejects 007 (leading zeros on positive integer)" {
  run validate_int "max_retries" "007"
  [ "$status" -eq 2 ]
}

@test "validate_int rejects 08 / 09 (would be parsed as invalid octal in \$((...)))" {
  run validate_int "concurrency_lock_poll_interval" "08"
  [ "$status" -eq 2 ]
  run validate_int "concurrency_lock_poll_interval" "09"
  [ "$status" -eq 2 ]
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

@test "validate_path rejects ASCII space (lftp -e token parsing — v2.11.8 #174)" {
  # server-dir / remote_dir values are interpolated into the
  # `lftp -e` script body where lftp 4.9.3 tokenises on whitespace.
  # /my data/site/ would split into `cd /my` + leftover `data/site/`.
  run validate_path "remote_dir" "/my data/site/"
  [ "$status" -eq 2 ]
  [[ "$output" == *"space"* ]]
}

@test "validate_path rejects a leading space (v2.11.8 #174)" {
  run validate_path "remote_dir" " /leading"
  [ "$status" -eq 2 ]
  [[ "$output" == *"space"* ]]
}

@test "validate_path rejects a trailing space (v2.11.8 #174)" {
  run validate_path "remote_dir" "trailing "
  [ "$status" -eq 2 ]
  [[ "$output" == *"space"* ]]
}

@test "validate_path accepts valid FTP / FTPS URL-shaped inputs (v2.11.8 #190)" {
  # New use case for validate_path: INPUT_SERVER. Valid FTP / FTPS
  # URL shapes (bare host, with port, bracketed IPv6) must all pass.
  run validate_path "server" "ftp://example.com"
  [ "$status" -eq 0 ]
  run validate_path "server" "ftp://example.com:21"
  [ "$status" -eq 0 ]
  run validate_path "server" "ftps://[::1]:990"
  [ "$status" -eq 0 ]
  run validate_path "server" "example.com"
  [ "$status" -eq 0 ]
}

@test "validate_path rejects shell metacharacters in INPUT_SERVER (v2.11.8 #190)" {
  run validate_path "server" 'ftp://example.com"; cls; quit;'
  [ "$status" -eq 2 ]
  [[ "$output" == *"double-quote"* ]]
  run validate_path "server" 'ftp://h;rm -rf /'
  [ "$status" -eq 2 ]
  [[ "$output" == *"forbidden shell metacharacter"* ]]
}

# F2 audit v2.11.10 (#295): bracket-balance guard for IPv6 URLs.
# Pre-fix, validate_path let `ftp://[::1` through and
# extract_netrc_host returned empty (the IPv6 sed requires a
# closing `]`). write_netrc then emitted `machine  login user
# password` — invalid .netrc syntax — and the user got a
# confusing "530 Login authentication failed" instead of a
# precise URL-shape error. Post-fix: validate_path rejects
# any value whose `[` and `]` counts don't match.
@test "validate_path rejects unbalanced IPv6 brackets — missing close (issue #295)" {
  run validate_path "server" 'ftp://[::1'
  [ "$status" -eq 2 ]
  [[ "$output" == *"unbalanced IPv6 brackets"* ]]
  # The error message embeds the counts so the user can see
  # which side is unbalanced (1 "[" vs 0 "]").
  [[ "$output" == *"1"* ]]
  [[ "$output" == *"0"* ]]
}

@test "validate_path rejects unbalanced IPv6 brackets — extra close (issue #295)" {
  run validate_path "server" 'ftp://::1]'
  [ "$status" -eq 2 ]
  [[ "$output" == *"unbalanced IPv6 brackets"* ]]
  # Counts: 0 "[" vs 1 "]". The `0` substring matches both the
  # count field and the literal `0]` in the message body; the
  # `1` substring matches the count. We assert the count
  # direction by requiring `0 "["` and `1 "]"` next to each other.
  [[ "$output" == *"0 \"[\""* ]]
  [[ "$output" == *"1 \"]\""* ]]
}

@test "validate_path rejects unbalanced IPv6 brackets — mismatched pairs (issue #295)" {
  # Two `[` and one `]`: the most common "I tried to write two
  # brackets" typo. Counts must balance.
  run validate_path "server" 'ftp://[[::1]'
  [ "$status" -eq 2 ]
  [[ "$output" == *"unbalanced IPv6 brackets"* ]]
}

@test "validate_path accepts balanced IPv6 brackets — documented form (issue #295)" {
  # The documented IPv6 form passes (balanced brackets) and
  # does NOT trip the new guard.
  run validate_path "server" 'ftps://[::1]:990'
  [ "$status" -eq 0 ]
  run validate_path "server" 'ftps://[::1]'
  [ "$status" -eq 0 ]
  run validate_path "server" 'ftp://[2001:db8::1]:21'
  [ "$status" -eq 0 ]
}

@test "validate_path accepts values with no brackets unchanged (issue #295)" {
  # The guard must be invisible for the common case where no
  # bracket appears at all — count is (0, 0) and the comparison
  # is equal. Regression guard against an over-broad rule that
  # would block every server value.
  run validate_path "server" 'ftp://example.com'
  [ "$status" -eq 0 ]
  run validate_path "server" 'ftp://example.com:21'
  [ "$status" -eq 0 ]
  run validate_path "local_dir" '/var/www/site/'
  [ "$status" -eq 0 ]
  run validate_path "remote_dir" '/www/user/home/'
  [ "$status" -eq 0 ]
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
# normalize_bool — v2.11.7 (#252)
# ----------------------------------------------------------------------------

@test "normalize_bool canonicalises truthy aliases to 'true'" {
  for v in true yes on 1; do
    run normalize_bool "concurrency_lock" "$v"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
  done
}

@test "normalize_bool canonicalises falsy aliases to 'false'" {
  for v in false no off 0 ""; do
    run normalize_bool "delete" "$v"
    [ "$status" -eq 0 ]
    [ "$output" = "false" ]
  done
}

@test "normalize_bool rejects a capitalised value (validate_bool layer)" {
  run normalize_bool "dry_run" "True"
  [ "$status" -eq 2 ]
}

@test "normalize_bool rejects an RCE payload" {
  run normalize_bool "concurrency_lock" 'true; !cat /home/lftp/.netrc'
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

@test "validate_lftp_settings accepts double-quote (documented set-directive string delimiter — F2 audit finding #172 reviewed in v2.11.8)" {
  # F2 audit (#172) claimed validate_lftp_settings should reject
  # `"` because the value flows into the `lftp -e` body. Validated
  # against the documented use case in action.yml:85: the example
  # `set http:user-agent "firefox";` is a 3-`;`-chained string with
  # embedded double-quotes, and tests/smoke.sh:286 pins it as a
  # documented happy path. The closing of #172 therefore means
  # ensuring the validator rejects `"` only where it is dangerous
  # (paths in validate_path; mirror -x/-X values in
  # validate_glob_pattern), not in validate_lftp_settings where
  # `"` is the documented string-delimiter for lftp's
  # `set <key> "value";` directive. v2.11.8 close-doc.
  run validate_lftp_settings 'set cache:cache-empty-listings true; set cmd:status-interval 1s; set http:user-agent "firefox";'
  [ "$status" -eq 0 ]
}
