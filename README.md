# FTP Deployment: GitHub Action

[![CI](https://github.com/airvzxf/ftp-deployment-action/actions/workflows/ci.yml/badge.svg)](https://github.com/airvzxf/ftp-deployment-action/actions/workflows/ci.yml)
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/airvzxf/ftp-deployment-action)](https://github.com/airvzxf/ftp-deployment-action/releases)
[![License: GPL-3.0](https://img.shields.io/github/license/airvzxf/ftp-deployment-action)](https://github.com/airvzxf/ftp-deployment-action/blob/main/LICENSE)

This GitHub action copies the files via FTP from your Git project to your server in a specific path.

## Security and SSL

By default, `ftp_ssl_allow` is set to `true` to ensure your connection is encrypted, and `ssl_verify_certificate` is also set to `true`, so the action refuses to connect to a server with an invalid, expired, or hostname-mismatched certificate. **This is a breaking change from v1.x**: if you connect to a server with a self-signed certificate or a direct IP, the action will now fail with a TLS error. To opt back into the v1.x behaviour, set `ssl_verify_certificate: false` explicitly in your workflow.

> **Note on direct-IP connections**: lftp cannot validate a hostname against an IP-address certificate, so `ssl_verify_certificate: true` requires both a valid certificate and a hostname (not a bare IP) in the `server` input.

## Usage Example

Add this code in `./.github/workflows/your_action.yml`.

More about GitHub "secrets" in this article:
[Creating and storing encrypted secrets][1].

```yaml
name: CI -> Deploy to My website
on:
  push:
    branches: [ main, development ]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # Here is the deployment action
      - name: Upload from public_html via FTP
        uses: airvzxf/ftp-deployment-action@v2
        with:
          server: ${{ secrets.FTP_SERVER }}
          user: ${{ secrets.FTP_USERNAME }}
          password: ${{ secrets.FTP_PASSWORD }}
          local_dir: "./public_html"
```

> **Pin to a major version (recommended)**: `@v2` always points to the
> latest v2.x release. For stricter reproducibility pin to a specific
> tag (`@v2.0.0`) or a full commit SHA. Avoid `@latest` and `@main` —
> they move under you and can introduce regressions.

## Settings

Usually the zero values mean unlimited or infinite. This table is based on the default values on `lftp-4.9.2`.

| Option                 | Description                                                                           | Required | Default | Example                                                                                           |
|------------------------|---------------------------------------------------------------------------------------|----------|---------|---------------------------------------------------------------------------------------------------|
| server                 | FTP Server.                                                                           | Yes      | N/A     | rovisoft.net                                                                                      |
| user                   | FTP Username.                                                                         | Yes      | N/A     | myself@rovisoft.net                                                                               |
| password               | FTP Password.                                                                         | Yes      | N/A     | ExampleOnlyAlphabets                                                                              |
| local_dir              | Local directory.                                                                      | No       | "./"    | "./public_html"                                                                                   |
| remote_dir             | Remote directory.                                                                     | No       | "./"    | "/www/user/home"                                                                                  |
| max_retries            | Number of retries on error. `0` = retry forever; `1` = no retries.                  | No       | 10      | N/A                                                                                               |
| delete                 | Delete all the files inside of the remote directory before the upload process.        | No       | false   | N/A                                                                                               |
| no_symlinks            | Do not create symbolic links.                                                         | No       | true    | N/A                                                                                               |
| mirror_verbose         | Mirror verbosity level.                                                               | No       | 1       | N/A                                                                                               |
| ftp_ssl_allow          | FTP - Allow SSL encryption.                                                           | No       | true    | N/A                                                                                               |
| ssl_verify_certificate | FTP - Verify SSL certificate.                                                         | No       | false   | N/A                                                                                               |
| ssl_check_hostname     | FTP - Check certificate hostname.                                                     | No       | true    | N/A                                                                                               |
| ftp_passive_mode       | FTP - This can be useful if you are behind a firewall or a dumb masquerading router.  | No       | true    | N/A                                                                                               |
| ftp_use_feat           | FTP - FEAT: Determining what extended features the FTP server supports.               | No       | false   | N/A                                                                                               |
| ftp_nop_interval       | FTP - Delay in seconds between NOOP commands when downloading tail of a file.         | No       | 2       | N/A                                                                                               |
| net_max_retries        | NET - Maximum number of operation without success.<br> 0 unlimited.<br> 1 no retries. | No       | 1       | N/A                                                                                               |
| net_persist_retries    | NET - Ignore hard errors.<br> When reply 5xx errors or there is too many users.       | No       | 5       | N/A                                                                                               |
| net_timeout            | NET - Sets the network protocol timeout.                                              | No       | 15s     | N/A                                                                                               |
| dns_max_retries        | DNS - 0 no limit trying to lookup an address otherwise try only this number of times. | No       | 8       | N/A                                                                                               |
| dns_fatal_timeout      | DNS - Time for DNS queries.<br> Set to "never" to disable.                            | No       | 10s     | N/A                                                                                               |
| lftp_settings          | Any other settings that you find in the MAN pages for the LFTP package.               | No       | ""      | "set cache:cache-empty-listings true; set cmd:status-interval 1s; set http:user-agent 'firefox';" |
| exclude                | Comma-separated globs to exclude from the upload. Translated to `set mirror:exclude`.  | No       | ""      | "*.map,node_modules/**,.git/**"                                                                  |
| exclude_delete         | Comma-separated globs to protect from `--delete`. Translated to `set mirror:exclude-file`. | No       | ""      | "*.log,uploads/**"                                                                               |
| debug                  | If "true", print resolved input values to the log.                                    | No       | false   | N/A                                                                                               |
| fail_on_deprecated     | If "true", exit 1 when the pinned ref is end-of-life (v1.x).                         | No       | false   | N/A                                                                                               |
| dry_run                | If "true", compute the mirror plan but do not transfer or delete any file.           | No       | false   | N/A                                                                                               |
| upload_log_on_failure  | If "true" (default), on exit 1 upload the captured lftp log to the workflow run as an artifact (90-day retention). Requires `env: GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}` on the step. | No       | true    | N/A                                                                                               |
| concurrency_lock       | If "true", serialize concurrent deployments to the same FTP server by acquiring a server-side sentinel directory. See "Concurrency / deployment lock" below. | No       | false   | N/A                                                                                               |
| concurrency_lock_path  | Path of the sentinel directory used by `concurrency_lock`. Must be a valid FTP path (no `..`, no shell metacharacters, no leading dash). | No       | .lftp-deployment.lock | N/A                                                                                |
| concurrency_lock_timeout | Maximum seconds to wait for the lock when `concurrency_lock` is "true" and another run is currently holding it. `0` means fail immediately when held. | No | 300  | N/A                                                                                               |
| concurrency_lock_poll_interval | Seconds between lock acquisition attempts.                                                  | No       | 5       | N/A                                                                                               |

More information on the official site for [lftp - Manual pages][2].

### Minimal example (only required inputs)

The example above shows the **minimum** required inputs (`server`, `user`, `password`, `local_dir`).
All other settings use the defaults shown in the table above. For full control see the
extended example below.

### Example with NO DEFAULT settings

```yaml
name: CI -> Deploy to My website
on:
  push:
    branches: [ main, development ]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      # Here is the deployment action
  - name: Upload from public_html via FTP
    uses: airvzxf/ftp-deployment-action@v2
    with:
      server: ${{ secrets.FTP_SERVER }}
      user: ${{ secrets.FTP_USERNAME }}
      password: ${{ secrets.FTP_PASSWORD }}
      local_dir: "./public_html"
      remote_dir: "/www/sub-domain/games/myself"
      delete: "true"
      max_retries: "7"
      no_symlinks: "false"
      ftp_ssl_allow: "false"
      ssl_verify_certificate: "true"
      ssl_check_hostname: "false"
      ftp_use_feat: "true"
      ftp_nop_interval: "9"
      net_max_retries: "0"
      net_persist_retries: "11"
      net_timeout: "13s"
      dns_max_retries: "17"
      dns_fatal_timeout: "never"
      lftp_settings: "set cache:cache-empty-listings true; set cmd:status-interval 1s; set http:user-agent 'firefox';"
      exclude: "*.map,node_modules/**,.git/**"
      exclude_delete: "*.log"
      dry_run: "false"
      upload_log_on_failure: "true"
```

### Pattern exclusions

Two inputs control which files participate in the upload and which
ones are protected from `--delete`. They map directly to lftp's
`mirror:exclude` and `mirror:exclude-file` settings (see the
[lftp manual](https://lftp.yar.ru/lftp-man.html) for the exact glob
syntax — globs are case-sensitive and follow fnmatch, not shell).

| Input | Effect |
|---|---|
| `exclude` | Files matching any pattern are **not uploaded** and **not deleted**. Use this for `node_modules/`, `.git/`, `*.map`, `*.bak`, etc. |
| `exclude_delete` | Files matching any pattern are protected from `--delete` but are still uploaded if they exist locally. Use this for `*.log` (you want fresh logs uploaded, but old ones on the server preserved). |

Both inputs default to empty (no exclusion). The two lists are
independent — a file can be excluded from upload but still be
protected from deletion, or vice versa. The order of precedence
inside the action is:

1. The 11 standard `set <key> <value>;` directives (FTP / NET / DNS).
2. `set mirror:exclude <value>;` if `exclude` is non-empty.
3. `set mirror:exclude-file <value>;` if `exclude_delete` is non-empty.
4. The free-form `lftp_settings` extension (can override any of the above).

Both inputs go through the same sanitization as `lftp_settings`
(reject control chars, backtick, `$`, `!`, more than 3 `;`), so
they're safe to pass user-supplied glob patterns.

## Workflow artifacts (auto-upload on failure)

When the action exits with code `1` (e.g. the FTP server is
unreachable, credentials are wrong, or the retry loop is
exhausted), the captured lftp log file is **automatically uploaded
to the current workflow run as a workflow artifact** named
`ftp-deployment-action-log-<run-attempt>`, with a 90-day
retention. The artifact is attached to the run alongside any
other artifacts your workflow produces; download it from the
GitHub UI to inspect the exact lftp output that triggered the
failure.

To enable the upload, expose `GITHUB_TOKEN` to the step:

```yaml
- uses: airvzxf/ftp-deployment-action@v2
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  with:
    server: ${{ secrets.FTP_SERVER }}
    user: ${{ secrets.FTP_USERNAME }}
    password: ${{ secrets.FTP_PASSWORD }}
    local_dir: "./public_html"
```

The upload is fail-soft. If the token (or any of the
GitHub-Actions env vars) is missing, the action skips the
upload with a notice and still exits `1`. If the upload
request itself fails (network, 4xx, 5xx), a warning is
printed and the action still exits `1`. Set
`upload_log_on_failure: "false"` to disable the upload
entirely. The log file is always captured under
`~/.lftp-logs/` in the container regardless — the runner can
inspect it from a follow-up step if it has access to the
container filesystem.

The artifact name uses `<run-attempt>` (the attempt number
within the workflow run) so that re-running a failed job
produces a separate artifact per attempt instead of
overwriting the previous one.

## Concurrency / deployment lock

Two workflows (or two runs of the same workflow) deploying to
the **same FTP server at the same time** can corrupt each
other: `lftp mirror --reverse` lists both source and target
directories, then races on writes. Concurrent uploads with
`--delete` are especially dangerous — each run can see the
other's freshly-uploaded files and delete them as "no longer
in the source".

### Option A — recommended: GitHub Actions `concurrency:` block

If both deployments run in the **same workflow** (or in two
workflows you control), the simplest fix is GitHub's built-in
serialization. Add a `concurrency:` group to your job:

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    concurrency:
      group: ftp-deploy-${{ github.ref }}
      cancel-in-progress: false
    steps:
      - uses: airvzxf/ftp-deployment-action@v2
        with:
          server: ${{ secrets.FTP_SERVER }}
          user: ${{ secrets.FTP_USERNAME }}
          password: ${{ secrets.FTP_PASSWORD }}
```

- `group: ftp-deploy-${{ github.ref }}` — at most one deploy
  per ref (branch / tag) at a time. Use
  `ftp-deploy-${{ github.workflow }}-${{ github.ref }}` if
  you also want to serialize across distinct workflows that
  deploy to the same server.
- `cancel-in-progress: false` — newer runs wait for the
  in-flight one to finish instead of cancelling it (which
  would leave a half-uploaded server).

This works across runners, regions, and self-hosted hosts, and
requires no code in the action. It is the recommended option
for everyone who can set it.

### Option B — server-side sentinel lock (this action)

If you cannot add a `concurrency:` block (e.g. your deploy is
driven by a tool you don't own, or you deploy from multiple
distinct workflows pointing to the same FTP and don't want
to share a group name), opt in to the server-side lock:

```yaml
- uses: airvzxf/ftp-deployment-action@v2
  with:
    server: ${{ secrets.FTP_SERVER }}
    user: ${{ secrets.FTP_USERNAME }}
    password: ${{ secrets.FTP_PASSWORD }}
    concurrency_lock: "true"
```

**What it does.** Before the mirror, lftp issues
`quote MKD <path>` to create a sentinel directory on the
FTP server. If the server replies `257` (created), the
deployment holds the lock and proceeds. If the server
replies `550` (already exists), another run is in flight;
the action polls up to `concurrency_lock_timeout` seconds
(retrying every `concurrency_lock_poll_interval` seconds)
and then fails with a clear error. After the mirror
completes (or on any exit path — success, error, SIGINT,
5h timeout, signal), the action issues `quote RMD <path>`
to release the lock, both in the same lftp invocation
and via the EXIT trap as a fallback.

**Why MKD/RMD and not a "lock" command.** lftp does not
ship a server-side `lock` primitive — it only has
`file:use-lock` for *local* files. MKD and RMD are RFC 959
basics and are implemented by every FTP server
(vsftpd, proftpd, Pure-FTPd, SFTP-via-FTP-gateways, etc.).
`mkdir` is atomic on virtually every UNIX-like filesystem
(returning `EEXIST` if the dir already exists), so the
race window between two clients is microseconds and the
worst-case outcome is that the lock briefly stays held by
a dead runner — which the `concurrency_lock_timeout`
catches.

**Stale lock risk.** If the holder dies before RMD (runner
OOM, the 5h hard timeout, a `kill -9` from the runner host),
subsequent runs will wait the full `concurrency_lock_timeout`
and then fail. To recover without waiting, log in to the
FTP and remove the sentinel directory manually:

```sh
lftp -u user,pw ftp://example.com -e "rm -rf .lftp-deployment.lock; quit;"
```

A timestamp-sentinel inside the lock directory (so the
action can auto-detect staleness) is on the roadmap for a
future release.

**Customizing the lock path.** If you have several
deployments against the same FTP server (e.g. one for
production, one for staging, each writing to a different
remote directory), give each its own lock path:

```yaml
- uses: airvzxf/ftp-deployment-action@v2
  with:
    concurrency_lock: "true"
    concurrency_lock_path: ".lftp-deployment.lock.prod"
```

**Limitations.**

- The lock is **advisory**: a hostile client that ignores
  the sentinel can still upload concurrently. The lock
  protects against accidental races from CI runs, not
  against malicious actors.
- The lock is **per-server, not per-path**: two deploys to
  the same FTP but different `remote_dir` will serialize.
  This is usually the right call (uploads to the same
  server still share an FTP control connection and the
  server's filesystem cache) but if you need finer
  granularity, give each deploy a different
  `concurrency_lock_path`.
- The lock is **not replicated across FTP servers**: if you
  mirror to two backends via different `server` inputs in
  one step, this input does not coordinate between them.
  For that, use Option A with a shared `concurrency:`
  group.

## How it works

```
+--------------------------+
|   GitHub Actions runner  |
|   invokes the action     |
+------------+-------------+
             |
             v
+--------------------------+
|  entrypoint.sh starts    |
|  (sources /app/lib.sh)   |
|                          |
|  1. Deprecation check    |--- EOL / @latest / @master  -->  ::warning::
|     (emit_deprecation_   |                                (::error:: + exit 1
|      warning, reads       |                                 if fail_on_deprecated)
|      GITHUB_ACTION_REF +  |
|      /app/VERSION)       |
|                          |
|  2. Mask sensitive       |--- ::add-mask:: password / user / server
|     inputs (add_masks)   |
|                          |
|  3. Validate inputs      |--- path traversal? shell metachars?     --> exit 2
|     (validate_int,       |
|      validate_path,      |
|      validate_lftp_      |
|      settings)           |
|                          |
|  4. Build FTP_SETTINGS   |--- one 'set foo bar' per input
|     + MIRROR_COMMAND     |   (build_ftp_settings / build_mirror_command)
|     + normalize paths    |
|                          |
|  5. Write .netrc         |--- 0600, removed by EXIT trap
|     (write_netrc)        |
|                          |
|  5b. Acquire server lock  |--- only if concurrency_lock=true
|      (build_lock_acquire, |   `quote MKD <path>` in a `repeat --until-ok`
|       inline in -e)      |   loop; polls up to concurrency_lock_timeout s
|                          |   then fails with exit 1
|                          |
|  6. lftp -e "..."        |--- +global 5h timeout
|     (run_lftp_once +     |   + exponential backoff with jitter
|      retry loop,         |   + per-attempt net/dns timeouts
|      max_retries=0..N)   |   + releases lock via `quote RMD` + EXIT trap
|                          |     if it was acquired
|                          |
|  7. Upload log artifact  |--- only on FAIL; needs GITHUB_TOKEN; skip-on-missing
|     (upload_log_artifact)|   90-day retention; fail-soft (warning on error)
|                          |
|  8. Result banner        |--- ERROR: UPLOAD FAILED + last lftp exit code
|     (print_failure_      |    FTP UPLOADED FINISHED! on success
|      banner / print_     |    FTP DRY RUN COMPLETED on dry run
|      success_banner)     |
+------------+-------------+
             |
             v
+--------------------------+
|  PASS  -> exit 0         |
|  FAIL  -> exit 1         |
|  INPUT -> exit 2         |
+--------------------------+
```

## NOTES

Main features:

- Copy all the files inside the specific folder from your GitHub repository to the specific folder in your server.
- Option to delete all the files in the specific remote folder before the upload.
- Using Alpine container means small size and faster creation of the container.
- Show messages in the console logs for every executed command.

## Local development

```sh
# Lint (shellcheck + actionlint + hadolint) and run the smoke tests
make lint
make test

# Build a local image with the deprecation warning reading 'dev' as
# the image version (matches the default in the Dockerfile)
make build IMAGE=ftp-deployment-action:local
make release-smoke IMAGE=ftp-deployment-action:local
```

`make build` runs `docker build --build-arg VERSION=dev` and
`make release-smoke` runs the same three checks the release
workflow runs against the just-pushed image:

1. The container starts and `validate_path` rejects a `..`
   path-traversal in `local_dir` with exit 2.
2. The deprecation warning fires for an EOL ref (`v1.3.3`).
3. The `VERSION` build-arg was baked into `/app/VERSION`
   (the warning would say `image version: unknown` otherwise).

These checks catch the kind of regression that broke the v2.3.0
release (Dependabot bumped the alpine base image, the lftp
package pin became unresolvable, the v2.3.0 tag was cut with a
non-buildable image) **before** a tag is pushed.

## Exit codes

| Code | Meaning |
|------|---------|
| `0`  | Upload finished successfully. |
| `1`  | Upload failed after all retries; the last lftp error is printed above. |
| `2`  | Invalid input. This includes: a non-integer numeric option (e.g. `max_retries`); a `local_dir` / `remote_dir` that fails the path-traversal or shell-metacharacter guard; an `lftp_settings` value that contains control characters, a backtick, a dollar sign, or more than three `;`-chained directives. |

When the global 5-hour timeout is reached the lftp process is killed and the
action exits with `1` (the most recent lftp exit code is also printed to the
log for debugging).

## Troubleshooting

| Symptom in the log | Likely cause | Fix |
|---|---|---|
| `530 Login authentication failed` | Wrong `user` / `password`, or the account is locked. | Verify the credentials against the server with an FTP client (e.g. `lftp -u user,pass host`). Make sure the secret in the repo is the one you think it is. |
| `550 Permission denied` on every file | The FTP user can read/write `remote_dir` but cannot enter the parent, or `delete: true` is trying to remove files it does not own. | Try a fresh `remote_dir` you have full control over (e.g. `/www/...`). If you only need upload without `delete`, leave `delete: false`. |
| `Fatal error: certificate verify failed` (TLS) | The server uses a self-signed certificate, the cert is expired, or you are connecting to a bare IP. | `ssl_verify_certificate` is `true` by default since v2.0.0. If you trust the server, set `ssl_verify_certificate: "false"` explicitly. For a bare IP you cannot validate a hostname — use a hostname with a real cert or opt out. |
| `Connection refused` / hangs on connect | Wrong host/port, firewall blocking outbound 21/990, or the FTP server is down. | Verify `server` (`ftp://host:21` or `ftps://host:990`). From the runner, `nc -vz host 21` should succeed. Some shared hosters block the runner's IP range — ask them to allow-list it. |
| `mirror: Access failed: 550 ... No such file or directory` | The remote path does not exist or the FTP user has no permission to create it. | Create the `remote_dir` manually (or set `delete: false` and accept a partial mirror) and confirm the FTP user owns it. |

> **The job is still running for hours**: `lftp` is probably waiting on a
> half-open TCP connection. Since v1.5.0 the action wraps every
> invocation in a hard 5-hour `timeout`; the job will be killed (exit
> `1`) at that point. If you want to fail faster, set `net_timeout` /
> `dns_fatal_timeout` lower than the defaults (`15s` / `10s`).

## Security

For how to report vulnerabilities please see [`SECURITY.md`](./SECURITY.md).

This action runs as the unprivileged `lftp` user inside the container
(Dockerfile `USER lftp`). The `password` input is never passed to
`lftp` on the command line: it is written to `~/.netrc` with mode
`0600` for the duration of the run and removed via an `EXIT` trap
on any exit path (success, error, `set -e` abort, SIGINT). Combined,
these mean the password never appears in `/proc/<pid>/cmdline` or in
the GitHub Actions runner log.

`local_dir` and `remote_dir` are validated against `..` path-traversal
components, leading dashes (which `lftp` would misread as options),
control characters, and shell metacharacters (`;`, `&`, `|`, backtick,
dollar). `lftp_settings` is lightly sanitised: control characters,
backtick, dollar, and more than three `;`-chained directives are
rejected. The action exits with code `2` and a clear error on any
of these. The same sanitization applies to the `exclude` and
`exclude_delete` inputs (v2.6.0+).

When the auto-upload feature is enabled (`upload_log_on_failure`
is `true` and the step exposes `GITHUB_TOKEN`), the token is
sent only to `${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/artifacts`
as an `Authorization: Bearer <token>` header. The token is
never interpolated into the URL, so it cannot leak into the
runner log even if `curl -v` were used. The upload response is
discarded (`> /dev/null`).

## Changelog

See [`CHANGELOG.md`](./CHANGELOG.md) for release notes.

[1]: https://docs.github.com/en/actions/configuring-and-managing-workflows/creating-and-storing-encrypted-secrets

[2]: https://lftp.yar.ru/lftp-man.html
