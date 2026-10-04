#!/usr/bin/env bats
# tests/acceptance/behavior.bats — frozen acceptance tests for lib.sh.
#
# These tests describe the business rules, not the implementation:
#   1. "No inputs set" must behave exactly like "inputs set to the
#      action.yml defaults" (GitHub always injects the defaults; local
#      runs and tests do not).
#   2. `exclude` is a comma-separated list of shell globs. Every item
#      becomes one `-X <glob>` mirror option (lftp excludes it from
#      upload AND from --delete). `exclude_delete` no longer exists.

setup() {
  set +u
  ROOT="${BATS_TEST_DIRNAME}/../.."
  # shellcheck disable=SC1090
  . "${ROOT}/lib.sh"
  # Start every test from a clean INPUT_* environment.
  for _v in $(env | sed -n 's/^\(INPUT_[A-Z_]*\)=.*/\1/p'); do unset "${_v}"; done
}

# Export INPUT_<NAME>=<default> for every input that declares a default
# in action.yml.
export_action_defaults() {
  eval "$(awk '
    /^inputs:/                { in_inputs = 1; next }
    /^[^ ]/                   { in_inputs = 0 }
    in_inputs && /^  [a-z_]+:[ ]*$/ { name = $1; sub(":", "", name); next }
    in_inputs && /^    default:/ {
      v = $0
      sub(/^    default:[ ]*/, "", v)
      if (v ~ /^\x27.*\x27$/) { v = substr(v, 2, length(v) - 2); gsub(/\x27\x27/, "\x27", v) }
      gsub(/\x27/, "\x27\\\x27\x27", v)
      print "export INPUT_" toupper(name) "=\x27" v "\x27"
    }
  ' "${ROOT}/action.yml")"
}

# ----------------------------------------------------------------------------
# Rule 1 — defaults parity
# ----------------------------------------------------------------------------

@test "defaults parity: build_ftp_settings with no inputs == with action.yml defaults" {
  no_inputs=$(build_ftp_settings)
  export_action_defaults
  with_defaults=$(build_ftp_settings)
  echo "no inputs:     ${no_inputs}"
  echo "with defaults: ${with_defaults}"
  [ "${no_inputs}" = "${with_defaults}" ]
}

@test "defaults: lftp gets 'set net:max-retries 1;' + persist-retries 0 when nothing is set" {
  run build_ftp_settings
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" == *"set net:max-retries 1;"* ]]
  [[ "$output" == *"set net:persist-retries 0;"* ]]
}

@test "defaults: lftp gets 'set net:max-retries 1;' + persist-retries 0 with action.yml defaults" {
  export_action_defaults
  run build_ftp_settings
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" == *"set net:max-retries 1;"* ]]
  [[ "$output" == *"set net:persist-retries 0;"* ]]
}

# ----------------------------------------------------------------------------
# Rule 2 — exclude is a comma-separated glob list mapped to -X
# ----------------------------------------------------------------------------

@test "exclude: single glob becomes one -X option and no -x option" {
  export INPUT_EXCLUDE='*.map'
  run build_mirror_command
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" == *" -X *.map"* ]]
  [[ "$output" != *" -x "* ]]
}

@test "exclude: comma list keeps order, trims spaces, one -X per item" {
  export INPUT_EXCLUDE='*.map, *.bak ,node_modules/'
  run build_mirror_command
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" == *" -X *.map -X *.bak -X node_modules/"* ]]
  [[ "$output" != *" -x "* ]]
}

@test "exclude: empty items are ignored" {
  export INPUT_EXCLUDE=' , *.log ,, '
  run build_mirror_command
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" == *" -X *.log"* ]]
  [ "$(printf '%s' "$output" | grep -o ' -X ' | wc -l)" -eq 1 ]
}

@test "exclude: unset or empty produces no -X / -x option" {
  run build_mirror_command
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" != *" -X "* ]]
  [[ "$output" != *" -x "* ]]
}

@test "exclude_delete: input is ignored (removed feature)" {
  export INPUT_EXCLUDE_DELETE='*.log'
  run build_mirror_command
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" != *"*.log"* ]]
}

@test "exclude: -X options come after --delete when both are set" {
  export INPUT_DELETE=true
  export INPUT_EXCLUDE='*.log'
  run build_mirror_command
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" == *"--delete"*"-X *.log"* ]]
}

# ----------------------------------------------------------------------------
# Rule 2b — exclude validation (exit 2 = invalid input)
# ----------------------------------------------------------------------------

@test "exclude validation: spaces around commas are accepted" {
  run validate_glob_pattern "exclude" "*.map, *.bak , node_modules/"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "exclude validation: a space inside one pattern is rejected with exit 2" {
  run validate_glob_pattern "exclude" "*.map, my file.txt"
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"exclude"* ]]
}

@test "exclude validation: an item starting with a dash is rejected with exit 2" {
  run validate_glob_pattern "exclude" "*.map, -rf"
  echo "$output"
  [ "$status" -eq 2 ]
}

@test "exclude validation: lftp command separators are rejected with exit 2" {
  for bad in '*.map;rm x' '*.map&' '*.map|x' '*."map'; do
    run validate_glob_pattern "exclude" "${bad}"
    echo "input=${bad} status=${status} output=${output}"
    [ "$status" -eq 2 ]
  done
}

@test "exclude validation: newline is rejected with exit 2" {
  run validate_glob_pattern "exclude" "$(printf '*.map\n!id')"
  echo "$output"
  [ "$status" -eq 2 ]
}
