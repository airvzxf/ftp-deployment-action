# tests/unit — bats unit tests for `lib.sh`

This directory contains unit tests for the pure functions in
[`lib.sh`](../../lib.sh). They use
[`bats-core`](https://github.com/bats-core/bats-core) (Bash
Automated Testing System).

## What's covered

| File | Functions |
|---|---|
| `validate.bats` | `validate_int`, `validate_path`, `validate_lftp_settings`, `validate_credential`, `validate_glob_pattern`, `validate_local_dir_outside_home`, `_canon_path`; the `run_lftp_once` `-e` script (with a fake `timeout`); `entrypoint.sh` validation paths |
| `parse.bats` | `_indirection`, `extract_netrc_host`, `build_ftp_settings`, `build_mirror_command`, `normalize_dir`, `write_netrc` |
| `retry.bats` | `classify_permanent_error`, `compute_backoff_seconds` |
| `report.bats` | `add_masks`, `print_inputs_dump`, `print_resolved_config`, `print_success_banner`, `print_failure_banner` |
| `lock.bats` | the concurrency-lock helpers (`_lock_sentinel_name`, `_lock_age_seconds`, `_lock_parse_sentinel_listing`, `acquire_lock_with_recovery`, `refresh_lock_sentinel`, `release_lock_safely`) and `rewrite_lftp_url`, with a fake `lftp`; the entrypoint's lock block with a stubbed `acquire_lock_with_recovery` |
| `verify-tag.bats` | `scripts/verify-tag.sh` (not `lib.sh`), run against throwaway git fixtures |

`run_lftp_once` is only partly unit-tested here: `validate.bats`
captures the `-e` script it builds with a fake `timeout`, and never
starts the real lftp. Its behaviour against a server (a real
connection, retries, exit codes) needs network I/O and is exercised by
the integration [`tests/smoke.sh`](../smoke.sh), which runs the whole
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

`make unit` is also one of the three targets `make test` runs
(`make test` = `contract unit smoke`), but it can be run on its own.
That lets you run the fast unit tests during local iteration without
needing docker/podman, and the slower smoke tests before pushing.

## In CI

A dedicated `unit` job in `.github/workflows/ci.yml` installs
`bats` via `apt-get` and runs `bats tests/unit` directly (not
`make unit`, which also skips quietly when bats is missing; CI
installs it, so the job cannot skip). No job declares `needs:`, so
the `unit` job runs in parallel with the other seven: `shellcheck`,
`actionlint`, `hadolint`, `contract`, `smoke`, `integration` and
`acceptance`.

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
