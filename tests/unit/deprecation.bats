#!/usr/bin/env bats
# tests/unit/deprecation.bats — unit tests for emit_deprecation_warning
# in lib.sh. The function reads from $GITHUB_ACTION_REF indirectly
# (via its first argument), so the test sets that argument
# explicitly. The function may call `exit 1` on the
# fail_on_deprecated path; bats `run` captures both stdout/stderr
# and the exit code.

setup() {
  set +u
  LIB="${BATS_TEST_DIRNAME}/../../lib.sh"
  # shellcheck disable=SC1090
  . "${LIB}"
}

@test "emit_deprecation_warning: @latest emits a 'Deprecated usage' warning" {
  run emit_deprecation_warning "latest" "v2.4.1" "false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning file=action.yml,title=Deprecated usage::"* ]]
  [[ "$output" == *"moving target"* ]]
  [[ "$output" == *"image version: v2.4.1"* ]]
}

@test "emit_deprecation_warning: empty ref is silent (local checkout)" {
  run emit_deprecation_warning "" "v2.4.1" "false"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "emit_deprecation_warning: @master emits a 'Branch usage' warning" {
  run emit_deprecation_warning "master" "v2.4.1" "false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning file=action.yml,title=Branch usage::"* ]]
  [[ "$output" == *"@master"* ]]
}

@test "emit_deprecation_warning: @main emits a 'Branch usage' warning" {
  run emit_deprecation_warning "main" "v2.4.1" "false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning file=action.yml,title=Branch usage::"* ]]
  [[ "$output" == *"@main"* ]]
}

@test "emit_deprecation_warning: v1.3.3 (EOL) emits an 'End-of-life' warning" {
  run emit_deprecation_warning "v1.3.3" "v2.4.1" "false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning file=action.yml,title=End-of-life version::"* ]]
  [[ "$output" == *"v1.3.3 is end-of-life"* ]]
}

@test "emit_deprecation_warning: v1.0-alpha.1 (EOL) emits a warning" {
  run emit_deprecation_warning "v1.0-alpha.1" "v2.4.1" "false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"End-of-life version"* ]]
}

@test "emit_deprecation_warning: v1.1 (EOL) emits a warning" {
  run emit_deprecation_warning "v1.1" "v2.4.1" "false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"End-of-life version"* ]]
}

@test "emit_deprecation_warning: v1.2.0 (EOL) emits a warning" {
  run emit_deprecation_warning "v1.2.0" "v2.4.1" "false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"End-of-life version"* ]]
}

@test "emit_deprecation_warning: v1.5.0 (current line v1.x) emits a 'v2 is available' notice" {
  run emit_deprecation_warning "v1.5.0" "v2.4.1" "false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice file=action.yml,title=New major available::"* ]]
  [[ "$output" == *"v2 is available"* ]]
}

@test "emit_deprecation_warning: v1.7.0 (current line v1.x) emits a notice" {
  run emit_deprecation_warning "v1.7.0" "v2.4.1" "false"
  [ "$status" -eq 0 ]
  [[ "$output" == *"v2 is available"* ]]
}

@test "emit_deprecation_warning: v2.0.1 (current line) is silent" {
  run emit_deprecation_warning "v2.0.1" "v2.4.1" "false"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "emit_deprecation_warning: v2.5.0 (current line) is silent" {
  run emit_deprecation_warning "v2.5.0" "v2.4.1" "false"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "emit_deprecation_warning: EOL ref + fail_on_deprecated=true exits 1 with ::error::" {
  run emit_deprecation_warning "v1.3.3" "v2.4.1" "true"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error file=action.yml::"* ]]
  [[ "$output" == *"fail_on_deprecated is true"* ]]
}

@test "emit_deprecation_warning: EOL ref + fail_on_deprecated=false (default) is advisory" {
  run emit_deprecation_warning "v1.3.3" "v2.4.1" ""
  [ "$status" -eq 0 ]
  [[ "$output" != *"::error"* ]]
}

@test "emit_deprecation_warning: @latest + fail_on_deprecated=true is still advisory (not EOL)" {
  # @latest is "moving target" but is not in the EOL list, so
  # fail_on_deprecated does NOT promote it to an error. Only the
  # explicit EOL list does.
  run emit_deprecation_warning "latest" "v2.4.1" "true"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning"* ]]
  [[ "$output" != *"::error"* ]]
}
