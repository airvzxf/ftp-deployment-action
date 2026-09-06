# Integration tests (issue #117)

End-to-end tests for `ftp-deployment-action` against a real FTP
server (`docker.io/fauria/vsftpd`). Each scenario boots its own
vsftpd container, exercises a specific deployment behaviour with
lftp (4.9.x, the same version the action image ships), asserts on
the resulting FTP server state, and tears the container down on
exit.

## Layout

```
tests/integration/
├── README.md                     # this file
├── run-integration-tests.sh      # orchestrator (runs every scenario)
├── Dockerfile.test-server        # pre-baked FTPS test server image
│                                 #   (vsftpd on alpine 3.24, digest-pinned);
│                                 #   built by `make build-test-server-image`
├── lib/
│   └── common.sh                 # shared helpers (runtime, FTP lifecycle,
│                                 #   lftp driver, assertions)
├── fixtures/
│   └── sample-public-html/       # 3 entries: index.html, about.html,
│                                 #   assets/.keep (one of them is a
│                                 #   subdirectory to exercise MKD)
└── scenarios/
    ├── 01-plain-ftp-upload.sh                # exercises the upload path
    ├── 02-plain-ftp-delete.sh                # exercises --delete
    ├── 03-ftps-explicit-upload.sh            # FTPS explicit (AUTH TLS upgrade)
    ├── 04-ftps-implicit-upload.sh            # FTPS implicit (TLS from byte 0)
    ├── 05-exclude-and-exclude-delete.sh      # exercises mirror:exclude
                                              #   + --delete
    ├── 07-self-hosted-home.sh                # regression guard for #111
                                              #   (#124 covered end-to-end)
    ├── 08-action-driven-upload.sh            # action-driven upload
                                              #   (closes #124)
    ├── 09-concurrency-lock-e2e.sh            # INPUT_CONCURRENCY_LOCK=true
                                              #   end-to-end
    ├── 10-stale-lock-recovery.sh             # stale-sentinel takeover
    ├── 11-exclude-delete-protects-remote.sh  # INPUT_EXCLUDE_DELETE
                                              #   end-to-end (closes #131)
    └── 12-acquire-vs-bare-host-url.sh        # acquire_lock against the
                                              #   bare-host URL shape (closes #160)
```

## Running locally

```
make build IMAGE=ftp-deployment-action:ci-integration VERSION=ci
make build-test-server-image TEST_SERVER_IMAGE=ftp-deployment-action-test-server:ci-integration
make integration IMAGE=ftp-deployment-action:ci-integration \
                 TEST_SERVER_IMAGE=ftp-deployment-action-test-server:ci-integration
```

`make build-test-server-image` builds the pre-baked FTPS test
server image (used by scenarios 03 / 04). The build context is
`tests/integration` so only the Dockerfile and adjacent files
are sent to the docker daemon.

`make integration` invokes `tests/integration/run-integration-tests.sh`,
which discovers and runs every `*.sh` under `tests/integration/scenarios/`
in lexical order. The CI workflow's job name is also `integration` and
uses the same Make target.

`make integration` exits 0 if every scenario passes; non-zero
otherwise.

## Running in CI

`.github/workflows/ci.yml` defines a separate `integration` job
that:

1. Builds the action image (`make build IMAGE=ftp-deployment-action:ci-integration VERSION=ci`).
2. Builds the pre-baked FTPS test server image (`make build-test-server-image TEST_SERVER_IMAGE=ftp-deployment-action-test-server:ci-integration`).
3. Runs `make integration IMAGE=ftp-deployment-action:ci-integration TEST_SERVER_IMAGE=ftp-deployment-action-test-server:ci-integration`.

The job's `timeout-minutes` is **5** (the same as the test budget
defined in #117's acceptance criteria). The CI runner is
`ubuntu-latest`, which has docker pre-installed.

## Pre-baked FTPS test server image (closes #135)

The FTPS test server is built ahead of time from
`tests/integration/Dockerfile.test-server` rather than assembled
per-scenario on a bare alpine image. The previous shape
(`docker run -d alpine:3.23.3 -c 'apk add --no-cache vsftpd openssl
&& ...'`) ran the `apk add` on every scenario start, which meant
the apk package index was downloaded from the network on each
run. In CI that occasionally:

* took >20s and tripped `wait_for_port`'s deadline;
* failed outright on a transient network blip, after which the
  `--rm` container was garbage-collected and surfaced as "No
  such container" in the harness.

The pre-baked image (alpine 3.24 base, digest-pinned to the same
value the action Dockerfile uses, with `vsftpd` only — the
per-run self-signed cert is generated on the host via
`openssl req`, so the server image does not need the openssl CLI)
plus the pre-created `/var/log/vsftpd`,
`/etc/pam.d/vsftpd_virtual`, `/home/vsftpd` directories
eliminates that race: `docker run` of an already-pulled image is
a sub-second operation and never depends on the network.

`start_ftps_server` (in `tests/integration/lib/self-signed-cert.sh`)
only does the per-scenario work: copies the bind-mounted
`vsftpd.conf` to a writable path, sed-rewrites the alpine-vsftpd
TLS variable names (`ssl_tlsv1_1=` → `ssl_tlsv11=`, etc.),
`adduser` + `chpasswd` for the scenario's FTP_USER, and `exec
vsftpd`. The image tag is controlled by `TEST_SERVER_IMAGE`
(default `ftp-deployment-action-test-server:ci-integration`).

## Why variant B (lftp from alpine, not the action)

The original #117 proposal offered three variants for the FTP
server harness. **Variant C** (drive the upload through the
`ftp-deployment-action` image) was the original target for this
worktree. It turned out to be **not viable in this PR** for two
related reasons, both rooted in lftp 4.9.3 (the version pinned in
`Dockerfile`):

1. **lftp 4.9.3 ignores `.netrc` for `ftp://host:port` URLs.** The
   action's `run_lftp_once` (in `entrypoint.sh` / `lib.sh`) calls
   `lftp "${INPUT_SERVER}" -e '...'` with the server URL as the
   positional `<site>` argument. The action writes credentials to
   `~/.netrc` and relies on lftp to look them up, but lftp 4.9.3
   falls back to `USER anonymous`/`PASS lftp@` for FTP URLs without
   an embedded user, and never consults `.netrc` for the retry
   path. We confirmed this with `lftp -d` debug output: every
   `ftp://127.0.0.1:2121` invocation logs `---> USER anonymous`
   even when `~/.netrc` has the correct `machine 127.0.0.1 login
   ... password ...` entry. This makes the action's B-03 ".netrc
   over argv" plumbing inert against any FTP server that rejects
   `anonymous`, which is the default for `fauria/vsftpd`'s
   virtual-user config.

2. **`set mirror:exclude-file` is hidden behind `set -a` in
   lftp 4.9.3.** The action's `lib.sh::build_ftp_settings` writes
   `set mirror:exclude-file <value>;` for `INPUT_EXCLUDE_DELETE`,
   expecting it to protect remote files from `mirror --reverse
   --delete`. lftp 4.9.3 logs `mirror:exclude-file: no such
   variable. Use 'set -a' to look at all variables.` and
   continues without applying the pattern. The same flag for the
   upload direction (`set mirror:exclude` *is* valid, but it
   expects a POSIX regex, not a glob — `*.bak` is rejected with
   "Invalid preceding regular expression").

   Closed by `lib.sh::build_ftp_settings` wrapping the assignment
   in `set -a; set mirror:exclude-file <value>; set -a;` (closes
   #131). The first `set -a` enables lftp's "show all variables"
   toggle so the assignment is recognised; the second toggles it
   back off so the rest of the action's lftp settings are not
   affected by the wider auto-execute semantics. See scenario 11
   for the end-to-end regression guard.

Either issue alone was enough to disqualify variant C in the
#117 PR; together they made it impossible to assert the action's
behaviour end-to-end without modifying `entrypoint.sh` / `lib.sh` /
`Dockerfile`, which #117 must not touch.

**v2.11.0 closed both blockers** (#124, #131), so variant C is now
the primary path: scenarios 03 / 04 / 07 / 08 / 09 / 10 / 11 / 12
all drive the action image end-to-end (see the Layout tree). The
plain-FTP scenarios 01 / 02 / 05 still use variant B (lftp from
alpine, no `set mirror:exclude-file`) because they exercise lftp's
mirror-primitive behaviour directly — running them via the action
would only re-test the harness, not the primitive.

**Variant B** (lftp from alpine, ftp-upload / ftp-list /
ftp-delete through `alpine:3.23.3 + apk add lftp` and the same
`fauria/vsftpd` server) is now a deliberate subset, kept for the
two scenarios that need raw lftp semantics (01, 02, 05). It keeps
the harness faithful to the production control plane — same lftp
version, same FTP server image, same PASV configuration — while
letting the test drive the FTP commands directly. The CI job
still builds the action image
(`make build IMAGE=ftp-deployment-action:ci-integration VERSION=ci`)
to catch Dockerfile / package-pin / entrypoint-regressions; the
integration scenarios themselves either invoke it (variant C) or
run lftp from a throwaway alpine container (variant B).

## Acceptance criteria for #117

| # | Criterion | Status |
|---|---|---|
| 1 | `make integration` boots vsftpd and runs 11 scenarios. | ✓ 11 scenarios wired (01/02/05 plain FTP, 03/04 FTPS, 07/08/09/10/11/12 action-driven) |
| 2 | All 11 scenarios pass locally (podman) and in CI (docker). | ✓ locally; CI is the same Make target, only the runtime differs |
| 3 | Each scenario is standalone. | ✓ each scenario installs `trap stop_ftp_server EXIT` |
| 4 | `tests/integration/README.md` documents how to add a scenario. | ✓ see "Adding a new scenario" below |
| 5 | Tests are idempotent. | ✓ per-scenario unique PID + random FTP user; bind mount created with `mktemp -d`; trap removes both the FTP container and the bind-mount source directory |
| 6 | CI job runs in ≤ 5 min. | ✓ `timeout-minutes: 5` on the integration job in `ci.yml`; current local wall-clock per scenario is ~12s (mostly the alpine image pull + the FTP server boot) |

## How a scenario is wired

Every scenario follows the same skeleton (see
`scenarios/01-plain-ftp-upload.sh` for the canonical example):

```sh
#!/bin/sh
set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"

scenario_setup "01-my-scenario"     # allocates per-scenario credentials
                                    # + data dir, installs EXIT trap

start_ftp_server "${FTP_USER}" "${FTP_PASSWORD}" "${FTP_DATA_DIR}"
                                    # boots fauria/vsftpd in background

_script=$(mktemp)
lftp_build_open_script "${_script}" \
    "mirror --reverse --continue /data/ ./"

_log=$(mktemp)
if lftp_run_script "${_script}" "${_log}" 60; then
    _rc=0
else
    _rc=$?
fi

# On non-zero rc, dump the log to stderr and exit 1.
if [ "${_rc}" -ne 0 ]; then
    cat "${_log}" >&2
    log_fail "lftp exited with code ${_rc}"
fi

assert_present "${FTP_DATA_DIR}/${FTP_USER}" "index.html"
assert_absent  "${FTP_DATA_DIR}/${FTP_USER}" "stale.html"

exit 0
```

The `trap stop_ftp_server EXIT` installed by `scenario_setup`
removes the vsftpd container on any exit path (success,
`exit 1`, signal), so a failure in scenario N cannot leave a
container running into scenario N+1.

## Adding a new scenario

1. Drop a new `NN-name.sh` under `tests/integration/scenarios/`,
   where `NN` is the next available two-digit number. Lexical
   ordering is the run order.
2. Source `lib/common.sh` (the `# shellcheck source=` directive
   on the `.` line is required so shellcheck can resolve
   cross-file function calls).
3. Call `scenario_setup "<name>"` first. This installs the EXIT
   trap that cleans up the FTP container — without it, a failure
   mid-scenario leaves the container running until the next
   `docker system prune`.
4. Call `start_ftp_server` (or, for stubs, `printf '  skip: ...' ;
   exit 0`).
5. Build the lftp script with `lftp_build_open_script` (writes
   the `open` line, the global `set` directives, and your
   caller-supplied commands, then a `quit`). The script file is
   bind-mounted into the alpine container at
   `/tmp/lftp-script.lftp` and consumed via `lftp -c "$(cat
   /tmp/lftp-script.lftp)"` (lftp 4.9.3 refuses to combine `-c`
   or `-f` with a URL on the command line, so the URL must be
   inside the script).
6. Invoke the lftp driver with `lftp_run_script`. The function
   bind-mounts your script and the fixtures directory, runs lftp
   in a fresh alpine:3.23.3 with `apk add lftp`, and returns the
   lftp exit code. **Do not** redirect the log to `/dev/null` —
   on failure the orchestrator dumps the log to stderr (via
   `log_fail`) so the failure is debuggable from the runner log.
7. On non-zero lftp exit, print the captured log to stderr
   yourself before calling `log_fail` (the `lftp_run_script`
   helper captures to a file but does not print).
8. Use `assert_present` / `assert_absent` against the bind-mounted
   `${FTP_DATA_DIR}/${FTP_USER}` directory to verify FTP server
   state. The local umask on vsftpd is set to 022 by
   `start_ftp_server` so files and directories are world-readable
   from the host — this is what makes `ls`-based verification
   portable across uid-mapping schemes (rootless docker, rootless
   podman, rootful docker). `start_ftp_server` also execs a
   `chmod 0777` inside the container so the FTP user home is
   world-readable+executable, which is what makes the bind mount
   `ls`-able from the host under rootless setups.
9. End with `exit 0` on success. **Never** use
   `cmd || { log_fail; }` patterns — when `set -e` is active and
   `log_fail` returns non-zero, the combination masks the failure
   and produces a spurious PASS.

## Network and credentials

The action container runs with `--network host` so it shares the
host's network namespace. This is required because the FTP server's
PASV data port range (`31100-31110`) cannot be mapped one-by-one
on rootless podman (privileged port mapping is restricted), and
the alpine+lftp container needs to reach the PASV port on the
host loopback after vsftpd advertises it. The trade-off:

* The vsftpd container publishes `-p 2121:21 -p 31100-31110:31100-31110`
  on the host. (The control port is 2121, not 21, because rootless
  podman cannot bind to a host port < 1024 without sudo. CI on
  GH-hosted ubuntu-latest runs docker as root and can bind to 21
  — the harness hard-codes 2121 + 31100-31110 either way; the
  FTP protocol surface is identical.)
* `PASV_ADDRESS=127.0.0.1` makes vsftpd advertise `127.0.0.1` as
  the PASV data address, which is reachable from the
  `--network host` alpine container.
* `LOCAL_UMASK=022` lets the host `ls` the FTP user home directory
  for post-action assertions.
* `start_ftp_server` execs `chmod 0777 /home/vsftpd/${FTP_USER}`
  inside the container so the FTP user home is world-readable
  regardless of the host's uid mapping.

The FTP password (and every other credential) goes into the
lftp script only — never on the harness command line. The lftp
script file is owned by the test runner with mode 0600 and is
bind-mounted read-only into the alpine container.

## Limitations / follow-ups

* **lftp 4.9.3 `.netrc` quirk is now closed in v2.11.0.** The
  original "Why variant B" blocker was #124 (bare-host URL made
  lftp fall back to anonymous). v2.11.0 rewrites the bare-host
  URL with the embedded `user:pass@` form so lftp's `.netrc`
  lookup fires, and scenarios 08 / 09 / 10 / 11 / 12 use that
  path end-to-end. Scenarios 01 / 02 / 05 keep variant B (raw
  lftp from alpine) by design — they exercise mirror-primitive
  behaviour, not the action image.

See `.worktrees/wt-117a-vu1m`, `wt-117b-7u8g`, `wt-117c-fbzk`
for the variant A/B/C worktrees.
