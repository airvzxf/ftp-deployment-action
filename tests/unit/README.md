# tests/unit — bats unit tests for `lib.sh`

This directory contains unit tests for the pure functions in
[`lib.sh`](../../lib.sh). They use
[`bats-core`](https://github.com/bats-core/bats-core) (Bash
Automated Testing System).

## What's covered

| File | Functions |
|---|---|
| `validate.bats` | `validate_int`, `validate_path`, `validate_lftp_settings` |
| `deprecation.bats` | `emit_deprecation_warning` |
| `parse.bats` | `_indirection`, `extract_netrc_host`, `build_ftp_settings`, `build_mirror_command`, `normalize_dir` |
| `retry.bats` | `classify_permanent_error`, `compute_backoff_seconds` |
| `report.bats` | `add_masks`, `print_inputs_dump`, `print_success_banner`, `print_failure_banner` |

The `run_lftp_once` and `write_netrc` helpers are not unit-tested
here because they require either network I/O or filesystem
side-effects. They are exercised by the integration
[`tests/smoke.sh`](../smoke.sh), which runs the whole
`entrypoint.sh` against an unreachable server in a real alpine
container.

## Running locally

```sh
# Install bats (Ubuntu/Debian):
sudo apt-get install -y bats

# Or build from source (any distro):
git clone https://github.com/bats-core/bats-core.git
cd bats-core
sudo ./install.sh /usr/local

# Run the unit tests:
make unit
# or directly:
bats tests/unit
```

`make unit` is a separate target from `make test` (which runs
the contract + smoke tests). Splitting them lets you run the fast
unit tests during local iteration without needing docker/podman,
and the slower smoke tests before pushing.

## In CI

A dedicated `unit` job in `.github/workflows/ci.yml` installs
`bats` via `apt-get` and runs `make unit`. The job runs in
parallel with the existing `shellcheck` / `actionlint` /
`hadolint` / `contract` / `smoke` jobs.

## Adding a new test

1. Identify which file in `tests/unit/` covers the function
   (see the table above). If the function is in a new logical
   group, create a new `*.bats` file alongside the others.
2. Add a `@test "..."` block. Each block is a function that
   returns non-zero on failure. Use `run` to capture the exit
   code and combined stdout/stderr of the function under test.
3. Don't `set -u` in your test (the `setup()` block already
   disables it so unset `INPUT_*` don't trigger errexit). The
   functions under test use `${VAR-}` so they are safe under
   `set -u` from the caller's perspective.
4. Run `make unit` to verify before pushing.
