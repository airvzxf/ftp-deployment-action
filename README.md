# FTP Deployment: GitHub Action

[![CI](https://github.com/airvzxf/ftp-deployment-action/actions/workflows/ci.yml/badge.svg)](https://github.com/airvzxf/ftp-deployment-action/actions/workflows/ci.yml)
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/airvzxf/ftp-deployment-action)](https://github.com/airvzxf/ftp-deployment-action/releases)
[![License: AGPL-3.0](https://img.shields.io/github/license/airvzxf/ftp-deployment-action)](https://github.com/airvzxf/ftp-deployment-action/blob/main/LICENSE)

This GitHub action copies the files via FTP from your Git project to your server in a specific path.

## Security and SSL

By default, `ftp_ssl_allow` is set to `true` to ensure your connection is encrypted, and `ssl_verify_certificate` is also set to `true`, so the action refuses to connect to a server with an invalid, expired, or hostname-mismatched certificate. **This is a breaking change from v1.x**: if you connect to a server with a self-signed certificate or a direct IP, the action will now fail with a TLS error. To opt back into the v1.x behaviour, set `ssl_verify_certificate: false` explicitly in your workflow.

> **Note on direct-IP connections**: lftp cannot validate a hostname against an IP-address certificate, so `ssl_verify_certificate: true` requires both a valid certificate and a hostname (not a bare IP) in the `server` input.

### Plain FTP vs FTPS, and the two FTPS modes

The action supports both plain FTP and FTPS, and FTPS has two
distinct flavours. The choice is driven by the URL scheme in the
`server` input **and** the `ftp_ssl_allow` toggle. Picking the
wrong combination is the most common cause of "the action worked
yesterday on a different FTP" reports.

| `server` scheme | `ftp_ssl_allow` | What you get | Default port |
|---|---|---|---|
| `ftp://host` | `true` (default) | **Explicit FTPS** ([RFC 4217](https://datatracker.ietf.org/doc/html/rfc4217)). Plain TCP connect, the server advertises `AUTH`, lftp upgrades the control channel with `AUTH TLS`, then `PROT P` for data. Password is sent inside TLS. This is the default and the most common deployment. | 21 |
| `ftp://host` | `false` | **Plain FTP.** Password and file contents are sent in clear. Only use this on a trusted LAN. | 21 |
| `ftps://host` | `true` (default) | **Implicit FTPS** ([RFC 1738](https://datatracker.ietf.org/doc/html/rfc1738)). TLS from the very first byte — the server's welcome banner is already inside TLS. Most legacy "FTPS" hosting providers (and many Windows-IIS setups) speak this. | 990 |
| `ftps://host` | `false` | **Inconsistent** — lftp will still try to negotiate TLS because the URL scheme is `ftps://`. The action exits with a protocol error. The `ftp_ssl_allow` input is effectively ignored when the scheme is `ftps://`. | 990 |

The two `ssl:verify-certificate` and `ssl:check-hostname` settings
apply to every row above except the plain-FTP one (which has no
TLS handshake to verify). For the `ftps://` rows, lftp also honours
`ftps:initial-prot` (C, S, E, P, or empty) — leave it at the
default `""` unless the server has a known PROT-bug workaround;
the action does not set it.

#### Picking the right `server` value

- **Modern shared hoster with TLS** (most "free" or cheap web
  hosts): `ftp://ftp.example.com` — the action's default gives
  you explicit FTPS on port 21.
- **Legacy FTPS host on port 990** (some cPanel / Plesk setups,
  many IIS deployments, some European hosters): use
  `ftps://ftp.example.com` or `ftps://ftp.example.com:990`.
  Leave `ftp_ssl_allow` at its default.
- **No TLS at all** (in-house FTP, an old NAS): use
  `ftp://host` **and** set `ftp_ssl_allow: "false"`. You must
  also set `ssl_verify_certificate: "false"` (it has no effect
  on a plain FTP connection but the action's `validate_int` will
  still require the value to be parseable).

> **Troubleshooting hand-off**: if the runner reports
> `getpeername: Connection refused` on `ftps://host:990`, the
> server is most likely **not** an implicit-FTPS server (some
> providers run explicit-only on 21, others run implicit on
> 990). Switch the scheme to `ftp://` and the port to `21`,
> keeping `ftp_ssl_allow: "true"`. See the
> [Troubleshooting](#troubleshooting) table below.

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
        uses: airvzxf/ftp-deployment-action@v2.11.13
        with:
          server: ${{ secrets.FTP_SERVER }}
          user: ${{ secrets.FTP_USERNAME }}
          password: ${{ secrets.FTP_PASSWORD }}
          local_dir: "./public_html"
```

> **Pin to a specific tag (recommended)**: The `@v2` floating
> major alias is **stale** — it still points at the v2.0.x-era
> image and the release pipeline does not move it, so following
> it silently skips every fix between v2.1.0 and the present
> (notably v2.11.3 CRITICAL RCE fix, the v2.11.0 HOME/netrc fix,
> the v2.11.6 lock hardening, and the v2.11.7 / v2.11.8
> input-validator batch). Pin to a specific tag (the examples
> below use `@v2.11.13`) or a full commit SHA. Always avoid
> `@latest`, `@main`, and `@master` — they move under you and
> can introduce regressions.
>
> **Verify a tag's signature before pinning to it**:
> `scripts/verify-tag.sh <tag>` checks the tag against the
> in-repo allow-lists and auto-detects whichever backend the
> tag used (`.github/trusted-signers` for SSH-signed tags,
> `.github/trusted-signers.asc` for PGP-signed tags; see
> [SECURITY.md](./SECURITY.md) for the per-tag range). The
> release pipeline's `verify-tag-signature` job runs the same
> check on every push before any image is published.

## Publishing targets (v2.10.0+)

Every tag is published to **two registries by default** (ghcr.io + Docker Hub
when configured); a third (ECR Public) is currently disabled — see below:

| Registry | Image | How to consume |
|---|---|---|
| GitHub Container Registry (default) | `ghcr.io/airvzxf/ftp-deployment-action:v2.11.13` | `uses: airvzxf/ftp-deployment-action@v2.11.13` (the example above) |
| Docker Hub | `docker.io/airvzxf/ftp-deployment-action:v2.11.13` | `uses: docker://docker.io/airvzxf/ftp-deployment-action@v2.11.13` |

Both carry the same OCI image bytes (one `docker buildx build`,
one digest), the same `cosign` keyless signature
(`cosign verify --certificate-identity-regexp ... --certificate-oidc-issuer ...`
against either image ref), and the same CycloneDX SBOM
attestation (attached via `actions/attest`). ghcr.io is always
published; Docker Hub is **conditional on the repo having the
right secrets configured** (see the [Maintainer setup](#maintainer-setup-publishing-to-docker-hub)
section below). If the Docker Hub secrets are missing, the
release pipeline emits a `::notice::` and skips that registry —
the v2.9.0 behaviour (ghcr.io only) is preserved bit-for-bit.

> **Note on ECR Public**: A third registry (`public.ecr.aws/m2z1h0m9/...`)
> was added in v2.10.0 for enterprise visibility. It is **temporarily
> disabled** as of the post-v2.11.1 commits because the AWS IAM
> role's OIDC trust policy is no longer aligned with this repo,
> and the maintainer does not currently have access to the AWS
> account. The `release.yml` ECR Public steps are commented out
> (not deleted) so re-enabling is a one-line change in two places
> when the trust policy is fixed. See the "Re-enable ECR Public"
> section below for the exact diff.

### Maintainer setup: publishing to Docker Hub

This is a **one-time** setup. It is not required to use the
action; it is only required if you are the maintainer pushing
new releases.

**Docker Hub** (publishes to `docker.io/airvzxf/ftp-deployment-action`):

1. Create a Docker Hub Personal Access Token (PAT) at
   <https://hub.docker.com/settings/security> (read + write +
   delete is fine; we only push).
2. Add two repository secrets on
   <https://github.com/airvzxf/ftp-deployment-action/settings/secrets/actions>:
   * `DOCKERHUB_USERNAME` — your Docker Hub username (the namespace
     owner; for this repo, that is `airvzxf`).
   * `DOCKERHUB_TOKEN` — the PAT from step 1.
3. Tag and push the next release. The pipeline will detect both
   secrets and push to docker.io alongside ghcr.io.

**Skipping a registry**: leave its secrets unset. The pipeline
emits a `::notice::` and falls back to the registries that *do*
have secrets configured. The ghcr.io path is unaffected.

### Re-enable ECR Public (when AWS access is restored)

ECR Public publishing is **disabled by default** as of
v2.11.11 (#216). All four ECR Public sites in
`.github/workflows/release.yml` are under `# DISABLED:`
preambles:

1. The ECR Public block inside the
   `Resolve tag, version and enabled registries` step
   (`meta` step in the `build` job) — guarded by
   `if [ -n "${ECR_DISABLED_FORCE:-}" ] && [ -n "${AWS_ROLE_TO_ASSUME}" ]`,
   so the publish path is only taken when both are set.
   When the condition is false, the step emits
   `ecr_enabled=false` and a `::notice::` explaining why the
   publish was skipped.
2. The two ECR Public login steps (`Configure AWS credentials
   (OIDC) for ECR Public` and `Log in to ECR Public`) further
   down in the `build` job — commented out, with a `# DISABLED:`
   preamble referencing the meta-step block above.
3. The cosign-sign ECR branch in the `Sign image with cosign`
   step — wrapped in `if [ "${{ steps.meta.outputs.ecr_enabled }}" = "true" ]`,
   which is dead while `ecr_enabled=false`.
4. The `Attach SBOM attestation to ECR Public image` step at
   the end of the `build` job — commented out, with a
   `v2.11.11 (#216): DISABLED.` preamble.

To re-enable, do **three things** (canonical runbook
tracked in #212):

1. Repair the AWS IAM role's OIDC trust policy documented in
   the next section so this repo can assume it, and set the
   `AWS_ROLE_TO_ASSUME` repository secret to the repaired
   role ARN.
2. Uncomment the three commented-out ECR steps in
   `.github/workflows/release.yml` (the two ECR login steps
   in `build` and the `Attach SBOM attestation to ECR Public
   image` step at the end of `build`). The `if [ ... = "true" ]`
   wrapping on the cosign-sign ECR branch is already in
   place; it becomes live the moment `ecr_enabled` flips to
   `true`.
3. For a one-off test run that bypasses the IAM trust policy
   state (e.g. to validate the OIDC + ECR Public path
   end-to-end before the trust policy is repaired), set the
   `ECR_DISABLED_FORCE` repository variable to any non-empty
   string (e.g. `1`) on
   <https://github.com/airvzxf/ftp-deployment-action/settings/variables/actions>.
   With `ECR_DISABLED_FORCE` non-empty AND `AWS_ROLE_TO_ASSUME`
   set, the meta step takes the publish branch unconditionally
   and emits `ecr_enabled=true` — useful for end-to-end
   testing on a temporary fork. **Remove the variable** once
   the IAM trust policy is confirmed working — leaving it set
   forces every future release to publish to ECR Public
   regardless of the IAM state, which is rarely what you
   want.

The meta step's `ECR_DISABLED_FORCE` opt-in is the only
`release.yml` line you can flip without editing the file.
The three commented-out steps (login ×2 + SBOM attestation)
must be uncommented by hand. After both edits, future
releases will start publishing to ECR Public without further
in-source changes.

#### Reference: ECR Public with OIDC (currently disabled)

The original setup (kept here so re-enabling does not require
re-deriving the IAM policy from scratch):

ECR Public (publishes to
`public.ecr.aws/m2z1h0m9/ftp-deployment-action` — no static AWS
secrets):

1. Create an ECR Public repository in the AWS account you want
   to publish from. The repository name must be `ftp-deployment-action`
   (the URL becomes `public.ecr.aws/<registry-id>/ftp-deployment-action`,
   where `<registry-id>` is the account-specific registry ID AWS
   assigns automatically — e.g. `m2z1h0m9` for this account). AWS
   does **not** let you set a custom registry ID: it is derived from
   your AWS Account ID and is permanent for the account.
2. Create an IAM role with the following trust policy
   (replace `ACCOUNT_ID` with your 12-digit AWS account ID):

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Principal": {
           "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
         },
         "Action": "sts:AssumeRoleWithWebIdentity",
         "Condition": {
           "StringEquals": {
             "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
           },
           "StringLike": {
             "token.actions.githubusercontent.com:sub": "repo:airvzxf/ftp-deployment-action:ref:refs/tags/v*"
           }
         }
       }
     ]
   }
   ```

   The `sub` condition pins the role to *tag pushes only* of this
   repo — pull requests and `workflow_dispatch` runs from forks
   cannot assume it.

3. Attach an inline policy granting the minimum ECR Public perms:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "ecr-public:GetAuthorizationToken"
         ],
         "Resource": "*"
       },
       {
         "Effect": "Allow",
         "Action": [
           "ecr-public:BatchCheckLayerAvailability",
           "ecr-public:PutImage",
           "ecr-public:InitiateLayerUpload",
           "ecr-public:UploadLayerPart",
           "ecr-public:CompleteLayerUpload"
         ],
         "Resource": "arn:aws:ecr-public::ACCOUNT_ID:repository/ftp-deployment-action"
       }
     ]
   }
   ```

4. Add one repository secret:
   `AWS_ROLE_TO_ASSUME` — the role ARN from step 2
   (e.g. `arn:aws:iam::ACCOUNT_ID:role/ftp-deployment-action-publisher`).
5. Tag and push the next release. The pipeline will assume the
   role via OIDC (`aws-actions/configure-aws-credentials@v4`)
   and login with `aws-actions/amazon-ecr-login@v2`. No static
   AWS access keys are stored in the repo.

**Skipping a registry**: leave its secrets unset. The pipeline
emits a `::notice::` and falls back to the registries that *do*
have secrets configured. The ghcr.io path is unaffected.

## Settings

Usually the zero values mean unlimited or infinite. This table is based on the default values on `lftp-4.9.3`.

> **Boolean inputs accept a fixed spelling set.** Every input
> whose default is `true` / `false` (`delete`, `no_symlinks`,
> `ftp_ssl_allow`, `ssl_verify_certificate`,
> `ssl_check_hostname`, `ftp_passive_mode`, `ftp_use_feat`,
> `debug`, `fail_on_deprecated`, `dry_run`,
> `upload_log_on_failure`, `concurrency_lock`) accepts the
> case-sensitive set `true`, `false`, `yes`, `no`, `on`, `off`,
> `0`, and `1`. Anything else — including capitalised variants
> such as `True`, `YES`, or `On` — is rejected with exit code
> `2` before the upload starts.
>
> **Numeric inputs reject leading zeros.** `max_retries`,
> `mirror_verbose`, `ftp_nop_interval`, `net_max_retries`,
> `net_persist_retries`, `net_timeout`, `dns_max_retries`,
> `dns_fatal_timeout`, `concurrency_lock_timeout`, and
> `concurrency_lock_poll_interval` accept a non-negative
> integer without leading zeros. `max_retries: "00"` (and any
> other `0`-prefixed integer) exits `2` rather than being
> silently treated as `0`. v2.11.12 (F2 audit) extended the
> same guard to the two duration inputs (`net_timeout`,
> `dns_fatal_timeout`) so `net_timeout: "00s"` and
> `dns_fatal_timeout: "00"` are also rejected with exit `2`
> — they are silent typos of the `0` retry-forever sentinel,
> not distinct values.

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
| ssl_verify_certificate | FTP - Verify SSL certificate.                                                         | No       | true    | N/A                                                                                               |
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
| exclude                | POSIX ERE pattern passed to `mirror -x`. Matching files are **not uploaded** and **not deleted**. | No       | ""      | `.*\.map\|node_modules/.*\|\.git/.*` |
| exclude_delete         | lftp `PatternSet::Glob` pattern passed to `mirror -X`. Matching files are **not uploaded** and **not deleted**. | No       | ""      | "*.log"                                                                                          |
| debug                  | If "true", print resolved input values to the log.                                    | No       | false   | N/A                                                                                               |
| fail_on_deprecated     | If "true", exit 1 when the pinned ref is end-of-life (v1.x).                         | No       | false   | N/A                                                                                               |
| dry_run                | If "true", compute the mirror plan but do not transfer or delete any file.           | No       | false   | N/A                                                                                               |
| upload_log_on_failure  | **BROKEN** (do not rely on). If "true" (default), the action attempts to POST the log to a non-existent GitHub REST endpoint on exit 1 and always prints `WARNING: failed to upload log artifact`. Set to "false" to silence the warning, then read `outputs.log_file` and upload the log yourself with `actions/upload-artifact` (see "Workflow artifacts" below). | No       | true    | N/A                                                                                               |
| concurrency_lock       | If "true", serialize concurrent deployments to the same FTP server by acquiring a server-side sentinel directory. See "Concurrency / deployment lock" below. | No       | false   | N/A                                                                                               |
| concurrency_lock_path  | Path of the sentinel directory used by `concurrency_lock`. Must be a valid FTP path (no `..`, no shell metacharacters, no leading dash, no `!`, no `"`). | No       | .lftp-deployment.lock | N/A                                                                                |
| concurrency_lock_timeout | Maximum seconds to wait for the lock when `concurrency_lock` is "true" and another run is currently holding it. `0` means fail immediately when held. | No | 300  | N/A                                                                                               |
| concurrency_lock_poll_interval | Seconds between lock acquisition attempts.                                                  | No       | 5       | N/A                                                                                               |

> **How `ftp_ssl_allow` interacts with the `server` URL scheme.**
> The default `ftp_ssl_allow: "true"` only takes effect when the
> `server` input uses the `ftp://` scheme (explicit FTPS, port 21).
> If you point the action at an implicit-FTPS server with
> `ftps://host:990`, lftp speaks TLS regardless of `ftp_ssl_allow`,
> and setting it to `"false"` actually breaks the connection. See
> the "Plain FTP vs FTPS" table in [Security and SSL](#security-and-ssl)
> for the full matrix.

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
    uses: airvzxf/ftp-deployment-action@v2.11.13
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
      exclude: ".*\\.map|node_modules/.*|\\.git/.*"
      exclude_delete: "*.log"
      dry_run: "false"
      upload_log_on_failure: "true"
```

### Pattern exclusions

Two inputs control which files participate in the mirror. `exclude`
is passed to lftp as `mirror -x <regex>` and uses POSIX ERE syntax.
`exclude_delete` is passed as `mirror -X <glob>` and uses lftp's
`PatternSet::Glob` syntax. In lftp 4.9.3, both options apply to
uploads and deletions; there is no separate delete-only exclusion.
See the [lftp manual](https://lftp.yar.ru/lftp-man.html) for the
exact pattern syntax.

| Input | Effect |
|---|---|
| `exclude` | POSIX ERE passed to `mirror -x`. Matching files are **not uploaded** and **not deleted**. Use this for patterns such as `node_modules/.*`, `\.git/.*`, `.*\.map`, or `.*\.bak`. |
| `exclude_delete` | lftp `PatternSet::Glob` pattern passed to `mirror -X`. Matching files are **not uploaded** and **not deleted**. Use this for patterns such as `*.log` or `uploads/**`. |

Both inputs default to empty (no exclusion). The inputs are
independent: both patterns may be supplied, and a file must match the
corresponding `mirror -x` or `mirror -X` pattern to be excluded.

The action builds the mirror command as follows:

1. It adds the standard lftp settings.
2. It appends `-x <regex>` when `exclude` is non-empty.
3. It appends `-X <glob>` when `exclude_delete` is non-empty.
4. It appends the local and remote directories to the mirror command.

Both inputs are validated by the action's `validate_glob_pattern`
validator. It rejects control characters, newlines, a leading dash,
and lftp command-separator characters (`;`, `&`, `|`, and `"`)
while allowing pattern metacharacters such as `!`, backticks, and
`$` where they are valid in the selected regex or glob syntax.

## Workflow artifacts (manual upload on failure)

> **⚠️ BROKEN as of v2.11.10**: the action's documented
> `upload_log_on_failure: "true"` feature uses a non-existent
> GitHub REST endpoint
> (`POST /repos/<owner>/<repo>/actions/runs/<run_id>/artifacts`).
> GitHub's REST API does not expose a create/POST endpoint for
> artifacts — creation flows through the Actions Runtime API
> (`ACTIONS_RUNTIME_TOKEN` + `ACTIONS_RESULTS_URL`), which
> `GITHUB_TOKEN` cannot substitute for. The call always returns
> a non-2xx, the action logs `WARNING: failed to upload log
> artifact`, and the user never sees an artifact in the run.
> This has been silently broken since v2.7.0; a follow-up
> release will switch the upload to the runtime-token API.
> Adding `GITHUB_TOKEN` to the step as the docs previously
> suggested is harmless but pointless.

The supported flow today is to read the `log_file` action
output (declared in `action.yml`; the path inside the
container, written before the failure banner) and pass it to
`actions/upload-artifact` in a follow-up step. **Caveat**:
`outputs.log_file` is an in-container path
(`/home/lftp/.lftp-logs/run-<UTC-timestamp>.log`) — when the
Docker-action step finishes, the container is destroyed and
the path no longer exists on the host runner, so a vanilla
follow-up `actions/upload-artifact` step will fail with
`if-no-files-found: error`. To make the path survive, mount it
to the host:

```yaml
- id: deploy
  uses: airvzxf/ftp-deployment-action@v2.11.13
  with:
    server: ${{ secrets.FTP_SERVER }}
    user: ${{ secrets.FTP_USERNAME }}
    password: ${{ secrets.FTP_PASSWORD }}
    local_dir: "./public_html"

- if: failure()
  uses: actions/upload-artifact@v4
  with:
    name: ftp-deployment-action-log-${{ github.run_attempt }}
    path: /tmp/ftp-deployment-action-logs
    retention-days: 90
```

```yaml
# Job-level volumes mount for the action container (works for both
# container and composite / docker actions in GH-hosted runners).
# The container must be launched with a writable host path mapped
# to its /home/lftp/.lftp-logs directory.
```

**Practical alternative while the upload is being redesigned**
(tracked alongside #296): set `INPUT_DEBUG=true` and read the
captured log from the run's standard log — `print_resolved_config`
prints the configuration on success and lftp's stderr is also
captured. This avoids the cross-container-file dance but loses
the structured-artifact ergonomics.

The log file is always written to
`/home/lftp/.lftp-logs/run-<UTC-timestamp>.log` inside the
container (the `log_file` output), regardless of
`upload_log_on_failure`. Set `upload_log_on_failure: "false"`
to silence the misleading `WARNING: failed to upload log
artifact` notice printed by the broken code path.

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
      - uses: airvzxf/ftp-deployment-action@v2.11.13
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
- uses: airvzxf/ftp-deployment-action@v2.11.13
  with:
    server: ${{ secrets.FTP_SERVER }}
    user: ${{ secrets.FTP_USERNAME }}
    password: ${{ secrets.FTP_PASSWORD }}
    concurrency_lock: "true"
```

**What it does.** Before the mirror, lftp issues the
high-level `mkdir <path>` command to create a sentinel
directory on the FTP server. If the server replies `257`
(created), the deployment holds the lock and proceeds.
If the server replies `550` (already exists), another run
is in flight; the action polls up to
`concurrency_lock_timeout` seconds (retrying every
`concurrency_lock_poll_interval` seconds) and then fails
with a clear error. After the mirror completes (or on
any exit path — success, error, SIGINT, 5h timeout, or
signal), the action issues `quote RMD <path>` to release
the lock, both in the mirror invocation and via the EXIT
trap as a fallback.

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

**Stale lock risk and auto-recovery (v2.9.0).** If the holder
dies before RMD (runner OOM, the 5h hard timeout, a
`kill -9` from the runner host), v2.9.0+ writes a
timestamp-encoded sentinel file at the FTP root before
starting the mirror. The next runner sees the lock held,
`LIST`s the FTP root, parses the sentinel's timestamp, and:

- If the sentinel is **older** than `concurrency_lock_timeout`
  seconds: treats the lock as stale, `DELE`s the sentinel,
  `RMD`s the lock dir, and retries the high-level `mkdir`
  command immediately.
- If the sentinel is **recent** (legitimate holder): polls
  normally up to `concurrency_lock_timeout` and then fails.
- If the lock dir exists but **no sentinel** is present
  (the previous holder died between MKD and the sentinel
  PUT, a microsecond race): also treats as stale and
  takes over.

The sentinel filename encodes the timestamp and the runner
PID, e.g.
`.lftp-deployment.lock.20260707T080000Z.1234.info`. The
file lives at the FTP root as a sibling of the lock dir so
the release path can do `quote RMD` without recursive
delete (FTP RMD on a non-empty dir returns 550).

If you need to force-recover a stuck lock *without* waiting
for the auto-detection (e.g. you want to push a hotfix and
`concurrency_lock_timeout` is set to a high value), log in
to the FTP and remove the sentinel + the lock dir manually:

```sh
lftp -u user,pw ftp://example.com \
  -e "quote DELE .lftp-deployment.lock.<stamp>.<pid>.info; \
      quote RMD .lftp-deployment.lock; quit;"
```

The manual recovery is rarely needed with the default
`concurrency_lock_timeout: 300` (5 minutes): a stale lock
surfaces within a normal workflow run.

**Customizing the lock path.** If you have several
deployments against the same FTP server (e.g. one for
production, one for staging, each writing to a different
remote directory), give each its own lock path:

```yaml
- uses: airvzxf/ftp-deployment-action@v2.11.13
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
|  1. Deprecation check    |--- EOL / @latest / @main    -->  ::warning::
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
|      (acquire_lock_with_  |   high-level `mkdir <path>`; checks for
|       recovery)           |   stale sentinels and polls up to
|                          |   concurrency_lock_timeout s
|                          |   then fails with exit 1
|                          |
|  6. lftp -e "..."        |--- +global 5h timeout
|     (run_lftp_once +     |   + exponential backoff with jitter
|      retry loop,         |   + per-attempt net/dns timeouts
|      max_retries=0..N)   |   + releases lock via `quote RMD` + EXIT trap
|                          |     if it was acquired
|                          |
|  7. Upload log artifact  |--- BROKEN since v2.7.0 (uses a non-existent REST POST
|     (upload_log_artifact)|    endpoint — see "Workflow artifacts (manual upload
|                          |    on failure)" below). The log is still captured at
|                          |    /home/lftp/.lftp-logs/run-<UTC>.log inside the
|                          |    container; a follow-up release will switch the
|                          |    upload to the Actions Runtime API.
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
| `2`  | Invalid input. This includes: a `server` URL that fails the path / metacharacter guard, or that embeds a password in the userinfo (`ftp://user:pass@host` — v2.11.8 #195 closes the credential-source bypass); a `local_dir` / `remote_dir` / `concurrency_lock_path` that fails the path-traversal, shell-metacharacter, or ASCII-space guard; a non-integer numeric option or one with a leading zero (e.g. `max_retries: "00"`); a boolean option outside the canonical set (see the [Settings](#settings) preamble); an `lftp_settings` value that contains control characters, a backtick, a dollar sign, the literal `!` character, an embedded newline, or more than three `;`-chained directives; an `exclude` / `exclude_delete` value rejected by `validate_glob_pattern` (control chars, leading dash, `;`, `&`, `|`, or `"`). |

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
| `getpeername: Connection refused` on `ftps://host:990` | The server is **not** speaking implicit FTPS — it is almost certainly explicit FTPS on port 21. The `ftps://` URL forces TLS from byte 0, which the server rejects. | Switch `server` to `ftp://host:21` and keep `ftp_ssl_allow: "true"`. See the "Plain FTP vs FTPS" table in [Security and SSL](#security-and-ssl). |
| lftp logs `PROT command not understood` then drops the data connection | Some legacy FTPS servers do not support `PROT P` even though they accept `AUTH TLS`. lftp falls back to `PROT C` (clear data channel) by default; if the server closes the data connection instead, the action exits 1. | Add `lftp_settings: "set ftps:initial-prot C;"` to the step, or ask the hoster to enable `PROT P` server-side. |
| `can't create /<some-path>/.netrc: Permission denied` (or `Read-only file system`) on self-hosted runners | The runner is forwarding its host `HOME` into the container. The action tried to write `<HOME>/.netrc`, but the directory is read-only or owned by a different uid than the in-container `lftp` user. | **Fixed in v2.11.0** — `entrypoint.sh` now pins `NETRC=/home/lftp/.netrc` and `export HOME=/home/lftp` regardless of any inherited `HOME`. On older versions, add `env: HOME: /home/lftp` to the step. See [Self-hosted runners](#self-hosted-runners) below for the full picture. |

> **The job is still running for hours**: `lftp` is probably waiting on a
> half-open TCP connection. Since v1.5.0 the action wraps every
> invocation in a hard 5-hour `timeout`; the job will be killed (exit
> `1`) at that point. If you want to fail faster, set `net_timeout` /
> `dns_fatal_timeout` lower than the defaults (`15s` / `10s`).

## Self-hosted runners

The action is a Docker action — it is forwards-compatible with
any Linux runner that ships a recent Docker or Podman (GitHub-hosted
`ubuntu-latest`, self-hosted Linux containers, k8s pods). macOS
and Windows runners are not supported for container actions;
runners that wrap a non-Linux container engine (Apple Colima,
Rancher Desktop) are out of scope because the image we build is
`linux/amd64` Alpine (see `Dockerfile`).

Self-hosted runners forward environment variables from the host
into the container by default. In practice this means `HOME` is
copied from the runner process, which is usually `/github/home`
(the GitHub Actions Runner service) or `/home/runner` (bare-metal).
Since **v2.11.0**, the action ignores the inherited `HOME` and pins
`HOME=/home/lftp` unconditionally — `entrypoint.sh` writes the
credentials to `/home/lftp/.netrc` (the path the `Dockerfile`
guarantees to be writable for the `lftp` user), so the deployment
succeeds even when the host `HOME` is read-only or owned by a
different uid.

On older versions (`v2.10.0` and below) the action wrote the
credentials to `${HOME}/.netrc`, which made the `.netrc` write
fail with `can't create /<HOME>/.netrc: Permission denied` on
self-hosted runners with the default `HOME` forwarding. If you
cannot yet upgrade to v2.11.0, the workaround is to pin `HOME`
explicitly on the step:

```yaml
- uses: airvzxf/ftp-deployment-action@v2.11.13
  env:
    HOME: /home/lftp        # override the runner's HOME
  with:
    server: ftp://example.com
    user: ${{ secrets.FTP_USERNAME }}
    password: ${{ secrets.FTP_PASSWORD }}
    local_dir: .
    remote_dir: /www
```

The `env` block on the action step ships only `HOME` to the
container, leaving every other environment variable forwarded
normally. This is the documented escape hatch for v2.10.0 and
remains valid on v2.11.0+.

See also `SECURITY.md` → "Self-hosted runners" for the security
implications of environment forwarding and how the action's
`.netrc` path pin keeps the password out of argv in every
configuration.

## Security

For how to report vulnerabilities please see [`SECURITY.md`](./SECURITY.md).

This action runs as the unprivileged `lftp` user inside the container
(Dockerfile `USER lftp`). The `password` input is never passed to
`lftp` on the command line: it is written to `~/.netrc` with mode
`0600` for the duration of the run and removed via an `EXIT` trap
on any exit path (success, error, `set -e` abort, SIGINT). Combined,
these mean the password never appears in `/proc/<pid>/cmdline` or in
the GitHub Actions runner log.

`server`, `local_dir`, `remote_dir`, and `concurrency_lock_path`
are all validated against the same deny-list: `..` path-traversal
components, leading dashes (which `lftp` would misread as options),
control characters, newlines, double quotes, shell metacharacters
(`;`, `&`, `|`, backtick, and dollar), `!` (lftp's shell escape),
and (since v2.11.8) ASCII space — a value like `/my data/site/`
used to silently break the lftp `-e` tokeniser, now exits `2`.
The `server` input additionally rejects URL userinfo that
embeds a password (the `ftp://user:pass@host` form, v2.11.8
#195 — lftp 4.9.3 would otherwise authenticate with the embedded
credentials and silently bypass the action's documented
credential source). `lftp_settings` is lightly sanitised:
control characters, newlines, backtick, dollar, and `!` are
rejected, and no more than three semicolon-chained directives
are allowed.

The `exclude` and `exclude_delete` inputs use a separate
`validate_glob_pattern` validator because their values are passed to
the lftp `mirror` command. It rejects control characters, newlines, a
leading dash, and command-separator characters (`;`, `&`, `|`, and
`"`), while allowing valid regex/glob metacharacters such as `!`,
backticks, and `$`. The action exits with code `2` and a clear error
when validation fails.

The `upload_log_on_failure` input is currently a no-op end-to-end:
see "Workflow artifacts (manual upload on failure)" above for the
supported replacement using the `log_file` output and a follow-up
`actions/upload-artifact` step. The action does not store or
forward `GITHUB_TOKEN` anywhere outside the broken POST request
it issues today; that request does not interpolate the token
into the URL, so it does not leak into the runner log even if
`curl -v` were used.

## Changelog

See [`CHANGELOG.md`](./CHANGELOG.md) for release notes.

[1]: https://docs.github.com/en/actions/configuring-and-managing-workflows/creating-and-storing-encrypted-secrets

[2]: https://lftp.yar.ru/lftp-man.html
