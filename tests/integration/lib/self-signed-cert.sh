#!/bin/sh
# tests/integration/lib/self-signed-cert.sh — FTPS test helpers.
#
# Sourced by the FTPS scenarios (03 explicit, 04 implicit, and 30
# TLS max version) AFTER tests/integration/lib/common.sh. Plain-FTP
# scenarios do NOT source this file, so common.sh carries no FTPS
# helpers.
#
# Public API:
#
#   generate_self_signed_cert
#     Generate (or reuse) a 1-day RSA-2048 self-signed certificate
#     at $FTP_INTEGRATION_CERT_DIR/server.pem (default
#     /tmp/ftpint-certs) and print the absolute path on stdout.
#     Subject: /CN=localhost. Format: combined PEM (key + cert
#     concatenated) — this is what vsftpd's rsa_cert_file expects
#     when rsa_private_key_file points at the same file. Mode
#     0600. Idempotent: if the cached file already exists AND is
#     still valid for >= 24h (`openssl x509 -checkend 86400`),
#     it is reused. Otherwise the cert is regenerated. The
#     checkend is defensive: a -days 1 cert is invalid 24h after
#     generation, so a persistent /tmp (self-hosted runners, local
#     dev boxes) can hand the next scenario run a stale cert
#     that fails the TLS handshake at runtime even though the
#     scenarios disable cert / hostname verification.
#
#   start_ftps_server FTP_USER FTP_PASS DATA_DIR CERT_FILE MODE
#     Boot a pre-baked vsftpd image with SSL/TLS enabled. MODE is
#     either "explicit" (AUTH TLS upgrade on the control channel)
#     or "implicit" (TLS from byte 0 — the ftps:// protocol shape).
#     For "explicit" the host port is $FTP_CONTROL_PORT (2121, the
#     same value all other scenarios use); for "implicit" the host
#     port is 2122 (unprivileged, no privileged-port workaround
#     needed on rootless runtimes).
#
#     Why a pre-baked image (vs the original inline `apk add`):
#     the original start_ftps_server booted a bare alpine image with
#     `-c 'apk add --no-cache vsftpd openssl && ...'` on every scenario run.
#     The `apk add` step downloads the alpine package index from the
#     network, which made scenarios 03 / 04 flaky in CI (#135):
#       * apk index download took 1-15s and occasionally exceeded
#         wait_for_port's 20s deadline.
#       * on a transient network blip, apk failed outright; the
#         container died and was garbage-collected by --rm, which
#         surfaced as "No such container" in the harness.
#     The pre-baked image (tests/integration/Dockerfile.test-server,
#     built by `make build-test-server-image`) eliminates the
#     per-run network dependency: vsftpd is already installed,
#     /var/log/vsftpd is pre-created, and
#     /etc/pam.d/vsftpd_virtual is written. The scenario only does
#     the user-specific work (adduser, the overlay vsftpd.conf,
#     the alpine-vsftpd TLS variable rename, exec vsftpd). Note:
#     the openssl CLI used to generate the per-run self-signed
#     cert lives on the HOST (see generate_self_signed_cert), not
#     in the server image.
#
#     Why alpine-based instead of docker.io/fauria/vsftpd
#     (the image the plain-FTP scenarios use): fauria's
#     /usr/sbin/run-vsftpd.sh wrapper has docker-in-docker quirks
#     in CI (ubuntu-latest + GitHub Actions) that surface as vsftpd
#     dying a few seconds after the container is created. Podman
#     rootless (local dev) does not reproduce the issue, so the
#     failure was not caught until CI ran the FTPS scenarios. A
#     plain alpine base avoids the wrapper entirely and runs
#     identically on both podman local and docker CI. Closes #120.
#
#     Sets the FTP_CONTAINER_NAME / FTP_DATA_DIR globals so the
#     existing stop_ftp_server helper (from common.sh, installed
#     as the EXIT trap by scenario_setup) cleans the container up.

# ------------------------------------------------------------------------------
# Cert cache directory. /tmp is fine on every GitHub-hosted runner
# and the local dev boxes we test on; the orchestrator does not
# mount /tmp read-only. FTP_INTEGRATION_CERT_DIR is overridable
# for the rare CI that does mount /tmp :ro (e.g. some container-in-
# container setups).
#
# Pre-baked FTPS test server image. Built by `make
# build-test-server-image` from tests/integration/Dockerfile.test-
# server; CI / the Makefile pass the matching tag. The image has
# vsftpd pre-installed and /var/log/vsftpd and /etc/pam.d/
# vsftpd_virtual pre-created so the per-scenario `docker run` does
# not need network access to an apk index. (/home/vsftpd is not in the
# image: it is the per-scenario bind mount.)
# Overridable for developers who build the image under a different
# tag; the default matches the suffix the Makefile and the CI
# workflow use (`-ci-integration`).
# ------------------------------------------------------------------------------
: "${FTP_INTEGRATION_CERT_DIR:=/tmp/ftpint-certs}"
export FTP_INTEGRATION_CERT_DIR
# FTP_TEST_SERVER_IMAGE is the image start_ftps_server boots. The
# orchestrator (tests/integration/run-integration-tests.sh) and the
# Makefile pass it as TEST_SERVER_IMAGE; we re-default from
# TEST_SERVER_IMAGE when FTP_TEST_SERVER_IMAGE itself is unset so
# the env var convention is consistent across plain-FTP and FTPS
# scenarios. Falls back to the canonical ci-integration tag for
# callers that set neither.
: "${FTP_TEST_SERVER_IMAGE:=${TEST_SERVER_IMAGE:-ftp-deployment-action-test-server:ci-integration}}"
export FTP_TEST_SERVER_IMAGE

# Implicit-FTPS host port (the port the container's vsftpd binds
# under --network host). 2122 is unprivileged on the host (no
# `ip_unprivileged_port_start=0` workaround needed on rootless
# podman / docker-rootless setups). Explicit FTPS uses
# $FTP_CONTROL_PORT (2121) from common.sh; implicit FTPS uses
# this value. Exported so scenario 04 can build the
# INPUT_SERVER=ftps://...:<port> URL from the same source of
# truth instead of duplicating the literal here.
FTP_IMPLICIT_PORT=${FTP_IMPLICIT_PORT:-2122}
export FTP_IMPLICIT_PORT

# ------------------------------------------------------------------------------
# generate_self_signed_cert
#   Print the absolute path to the cached self-signed cert PEM on
#   stdout. Generates it on first call; reuses it on subsequent
#   calls (when the cached cert is still valid for >= 24h). Mode
#   0600 on the directory and the file.
#
#   Cached-cert validity check: the cert is generated with
#   `openssl req -days 1`, so a cached cert from a previous run
#   can become stale on a runner with persistent /tmp (self-
#   hosted runners, local dev boxes). We re-issue when the cached
#   cert is missing OR when `openssl x509 -checkend 86400` says
#   it expires within 24h. The scenarios disable cert / hostname
#   verification (INPUT_SSL_VERIFY_CERTIFICATE=false,
#   INPUT_SSL_CHECK_HOSTNAME=false), so a stale cert is silent
#   in CI today; the checkend is defensive against production
#   users hitting the same path. See the docstring above for the
#   full reasoning behind the 1-day lifetime.
# ------------------------------------------------------------------------------
generate_self_signed_cert() {
  _gssc_dir=${FTP_INTEGRATION_CERT_DIR}
  _gssc_pem=${_gssc_dir}/server.pem

  mkdir -p "${_gssc_dir}"
  chmod 0700 "${_gssc_dir}"

  # If a cached cert exists and is valid for at least 24 more
  # hours, reuse it. `-checkend 86400` exits 0 when the cert is
  # still valid for >= 86400 seconds, 1 otherwise. We treat a
  # checkend failure (corrupt / wrong-format PEM) the same as a
  # missing cert and regenerate.
  if [ -f "${_gssc_pem}" ] \
      && openssl x509 -checkend 86400 -in "${_gssc_pem}" \
            -noout >/dev/null 2>&1; then
    chmod 0600 "${_gssc_pem}"
    printf '%s\n' "${_gssc_pem}"
    return 0
  fi

  _gssc_tmp=$(mktemp -d -t gssc.XXXXXX) \
    || { printf 'FAIL: mktemp failed\n' >&2; return 1; }
  chmod 0700 "${_gssc_tmp}"

  # -nodes: no passphrase on the private key (vsftpd cannot
  # type one interactively; a passphrase-protected key would
  # brick the boot).
  if ! openssl req -x509 -newkey rsa:2048 -days 1 -nodes \
      -keyout "${_gssc_tmp}/key.pem" \
      -out    "${_gssc_tmp}/cert.pem" \
      -subj "/CN=localhost" >/dev/null 2>&1; then
    rm -rf "${_gssc_tmp}"
    printf 'FAIL: openssl req failed\n' >&2
    return 1
  fi

  # vsftpd reads rsa_cert_file for the cert AND rsa_private_key_file
  # for the matching key; pointing both at the same file requires
  # the key+cert to be concatenated in PEM order.
  cat "${_gssc_tmp}/key.pem" "${_gssc_tmp}/cert.pem" > "${_gssc_pem}"
  rm -rf "${_gssc_tmp}"
  chmod 0600 "${_gssc_pem}"

  printf '%s\n' "${_gssc_pem}"
}

# ------------------------------------------------------------------------------
# _write_ftps_vsftpd_conf OUT_FILE LISTEN_PORT PASV_MIN PASV_MAX IMPLICIT_BOOL
#   Write a vsftpd.conf overlay that enables SSL on the cached cert,
#   pins the listen port to LISTEN_PORT (start_ftps_server passes the
#   host port: FTP_CONTROL_PORT, 2121, for explicit FTPS and
#   FTP_IMPLICIT_PORT, 2122, for implicit FTPS), and configures the PASV range the action's
#   mirror data channel will need.
#
#   This file is bind-mounted read-only (`:ro`) at /etc/vsftpd.conf
#   inside the test-server image (tests/integration/Dockerfile.
#   test-server) by start_ftps_server, whose startup command copies
#   it to /tmp/vsftpd.conf, renames two TLS directives with sed and
#   runs vsftpd on the copy. Nothing appends to the mounted file.
#
#   `force_local_data_ssl=NO` only means vsftpd does not REQUIRE TLS
#   on the data channel; it does not make the data channel
#   plaintext. The action's build_ftp_settings (lib.sh) sets
#   `ftp:ssl-allow` but never `ftp:ssl-protect-data`, whose lftp
#   4.9.3 default is yes, so after AUTH TLS lftp sends PROT P and
#   the data channel is encrypted (README: "then PROT P for data").
#   `force_local_logins_ssl=YES` does require TLS for the login on
#   the control channel. For implicit FTPS the control channel is
#   TLS from byte 0 anyway.
#
#   Private to this file. Called only by start_ftps_server.
# ------------------------------------------------------------------------------
_write_ftps_vsftpd_conf() {
  _wfvc_out=$1
  _wfvc_port=$2
  _wfvc_pmin=$3
  _wfvc_pmax=$4
  _wfvc_implicit=${5:-no}

  {
    # Base user config (originally modelled on fauria's default
    # vsftpd.conf, which these scenarios used before the alpine
    # test-server image). Authentication is the pam_unix service
    # vsftpd_virtual, backed by a real user that start_ftps_server
    # creates; no db_load / virtual-user database is involved.
    printf 'background=NO\n'
    printf 'anonymous_enable=NO\n'
    printf 'local_enable=YES\n'
    printf 'guest_enable=YES\n'
    printf 'virtual_use_local_privs=YES\n'
    printf 'write_enable=YES\n'
    printf 'pam_service_name=vsftpd_virtual\n'
    printf 'user_sub_token=$USER\n'
    printf 'local_root=/home/vsftpd/$USER\n'
    printf 'chroot_local_user=YES\n'
    printf 'allow_writeable_chroot=YES\n'
    printf 'hide_ids=YES\n'
    printf 'xferlog_enable=YES\n'
    printf 'xferlog_file=/var/log/vsftpd/vsftpd.log\n'
    printf 'port_enable=YES\n'
    printf 'connect_from_port_20=YES\n'
    printf 'ftp_data_port=20\n'
    printf 'seccomp_sandbox=NO\n'

    # Listen port + PASV range — the action's data channel uses
    # the PASV range. The container runs with --network host, so
    # listen_port is the host port itself; the `-p` mappings on
    # start_ftps_server's `docker run` are ignored.
    printf 'listen=YES\n'
    printf 'listen_port=%s\n' "${_wfvc_port}"
    printf 'pasv_min_port=%s\n' "${_wfvc_pmin}"
    printf 'pasv_max_port=%s\n' "${_wfvc_pmax}"

    # SSL configuration. The listener-side port stays the same;
    # the only difference between explicit and implicit FTPS is
    # whether the server demands TLS on the initial bytes
    # (implicit_ssl=YES) or waits for the client to issue AUTH
    # TLS (default for ssl_enable=YES).
    if [ "${_wfvc_implicit}" = "yes" ]; then
      printf 'implicit_ssl=YES\n'
    fi
    printf 'ssl_enable=YES\n'
    # Explicitly disable TLS 1.0 and 1.1 so the server does not offer
    # them, and allow 1.2. TLS 1.3 is not switched off here (see the
    # note above debug_ssl below). start_ftps_server renames the two
    # version gates ssl_tlsv1_1 / ssl_tlsv1_2 to the names the
    # test-server image's vsftpd uses (ssl_tlsv11 / ssl_tlsv12).
    printf 'ssl_tlsv1=NO\n'
    printf 'ssl_tlsv1_1=NO\n'
    printf 'ssl_tlsv1_2=YES\n'
    printf 'ssl_sslv2=NO\n'
    printf 'ssl_sslv3=NO\n'
    printf 'rsa_cert_file=/etc/vsftpd/vsftpd.pem\n'
    printf 'rsa_private_key_file=/etc/vsftpd/vsftpd.pem\n'
    # No ssl_dh_file is set, so vsftpd falls back to its built-in DH
    # params. That fallback was a 1024-bit group on the fauria/vsftpd
    # server these scenarios originally used, and lftp's OpenSSL 3.x
    # rejects it as "dh key too small" under the default security
    # level. The restriction below dates from that server and is
    # kept as is.
    # Workaround: force ECDHE-only key exchange via ssl_ciphers so
    # the DH key size never enters the handshake. DHE-RSA ciphers
    # are excluded; the RSA key exchange path (no DH params) is
    # left intact for clients that can't do ECDHE.
    printf 'ssl_ciphers=HIGH:MEDIUM:!DHE:!DH\n'
    printf 'force_local_logins_ssl=YES\n'
    printf 'force_local_data_ssl=NO\n'
    # TLS 1.3 stays enabled (the vsftpd default), so the scenarios
    # exercise what a TLS 1.3 server does to lftp (#361). debug_ssl
    # logs "SSL version: TLSvX.Y" for every connection; scenario 30
    # reads it to check which version the action negotiated.
    printf 'debug_ssl=YES\n'
    printf 'vsftpd_log_file=/var/log/vsftpd/vsftpd.log\n'
  } > "${_wfvc_out}"
}

# ------------------------------------------------------------------------------
# start_ftps_server FTP_USER FTP_PASS DATA_DIR CERT_FILE MODE
#   Boot the pre-baked FTPS test server image (built from
#   tests/integration/Dockerfile.test-server) with SSL/TLS enabled
#   via the bind-mounted vsftpd.conf overlay. MODE = "explicit"
#   (AUTH TLS upgrade) or "implicit" (TLS from byte 0). The host
#   port differs by mode:
#
#     MODE="explicit"  ->  host port ${FTP_CONTROL_PORT} (2121)
#     MODE="implicit"  ->  host port 2122
#
#   Both are unprivileged on the host (no special sysctl needed
#   on rootless podman / docker-rootless setups).
#
#   The pre-baked image (closes #135): tests/integration/Dockerfile.
#   test-server installs vsftpd, pre-creates /var/log/vsftpd
#   (vsftpd's xferlog target), and writes /etc/pam.d/
#   vsftpd_virtual (delegating to pam_unix / /etc/shadow). The
#   previous inline-`apk add` shape ran a network-dependent
#   package install on every scenario start, which made the 20s
#   wait_for_port race flaky in CI. The pre-baked image eliminates
#   that race: `docker run` of an already-pulled image takes <1s
#   and never races the apk index.
#
#   Why alpine-based (vs fauria/vsftpd): fauria's
#   /usr/sbin/run-vsftpd.sh wrapper has docker-in-docker quirks
#   in CI (ubuntu-latest) where vsftpd dies within seconds of
#   `docker run -d`. Podman rootless (local dev) does not
#   reproduce the issue, so the failure only surfaced when the FTPS
#   scenarios actually ran in CI (#120, PR #130). A plain alpine
#   base avoids the wrapper entirely and runs identically on podman
#   local and docker CI. The pre-baked Dockerfile keeps us off the
#   fauria wrapper for the same reason. The base is digest-pinned to
#   the same tag and digest as the action Dockerfile's FROM line (the
#   base image's Alpine release); they are bumped in lockstep (see the
#   comment above FROM in Dockerfile.test-server).
#
#   Why --network host: with it, vsftpd inside the container binds
#   directly on the host ports we want to expose (2121 / 2122),
#   which are unprivileged on every runtime. Without it, vsftpd
#   would need to listen on port 21 inside the container, requiring
#   `ip_unprivileged_port_start=0` on rootless. The `-p` mappings
#   below are documentation-only (ignored under --network host)
#   and kept for symmetry with the rest of the harness.
#
#   Why LISTEN_PORT is the host port (not the in-container port):
#   because --network host makes the container share the host's
#   network namespace, the in-container listen port IS the host
#   port. Passing the container port (21) would force vsftpd to
#   bind port 21 on the host, which rootless runtimes cannot do.
#   _write_ftps_vsftpd_conf is parameterised by LISTEN_PORT and
#   writes it verbatim into `listen_port=`, so this caller-side
#   choice works without touching the helper.
#
#   Authentication: local_enable=YES with a real alpine user
#   created at startup via adduser + chpasswd. The vsftpd overlay
#   still names the PAM service vsftpd_virtual; the pre-baked
#   image ships /etc/pam.d/vsftpd_virtual (delegating to pam_unix
#   / local /etc/shadow). This is the simplest auth path that
#   works on a stock alpine image — virtual users (fauria's
#   approach) require db_load, /etc/vsftpd/virtual_users.db, and
#   pam_userdb.so, which alpine's vsftpd package does not ship.
#
#   Side effects:
#     * Binds $FTP_PASV_MIN_PORT..$FTP_PASV_MAX_PORT on both sides
#       (the action's mirror data channel needs this range).
#     * Bind-mounts $DATA_DIR at /home/vsftpd (the chrooted
#       FTP user home) — same convention as start_ftp_server in
#       common.sh.
#     * Bind-mounts $CERT_FILE at /etc/vsftpd/vsftpd.pem
#       (read-only).
#     * Bind-mounts the overlay vsftpd.conf written by
#       _write_ftps_vsftpd_conf at /etc/vsftpd.conf (read-only);
#       the container's startup command copies it to
#       /tmp/vsftpd.conf and runs vsftpd on the copy.
#     * Sets FTP_CONTAINER_NAME and FTP_DATA_DIR globals so the
#       existing stop_ftp_server (common.sh, installed as the
#       EXIT trap by scenario_setup) cleans up.
#
#   Fails loudly (log_fail) if the container does not accept
#   connections within 20 seconds.
# ------------------------------------------------------------------------------
start_ftps_server() {
  _sfs_user=$1
  _sfs_pass=$2
  _sfs_data_dir=$3
  _sfs_cert=$4
  _sfs_mode=${5:-explicit}

  case "${_sfs_mode}" in
    explicit)
      _sfs_host_port=${FTP_CONTROL_PORT}
      _sfs_container_port=21
      _sfs_implicit_flag=no
      ;;
    implicit)
      _sfs_host_port=${FTP_IMPLICIT_PORT}
      _sfs_container_port=${FTP_IMPLICIT_PORT}
      _sfs_implicit_flag=yes
      ;;
    *)
      log_fail "start_ftps_server: mode must be explicit or implicit (got: ${_sfs_mode})"
      ;;
  esac

  # v2.11.11 (#166): defensively validate the port globals before
  # passing them to `${RUNTIME} run`. The variables are double-quoted
  # in every use site, so this is NOT a security fix (POSIX sh does
  # not word-split / glob-expand double-quoted parameter expansions
  # and the container's /bin/sh never sees them); it is a strict
  # improvement that surfaces a loud `log_fail` if a future refactor
  # introduces shell metacharacters in the defaults (e.g. via a
  # config file), instead of letting the next scenario fail with a
  # confusing "bind: invalid port" / "no port :// in URL" error.
  # Same case-pattern shape as lib.sh::validate_int, but calls
  # log_fail (the harness convention) instead of exit 2.
  case "${FTP_IMPLICIT_PORT}" in ''|*[!0-9]*) log_fail "FTP_IMPLICIT_PORT is not numeric: ${FTP_IMPLICIT_PORT}" ;; esac
  case "${FTP_PASV_MIN_PORT}"  in ''|*[!0-9]*) log_fail "FTP_PASV_MIN_PORT is not numeric: ${FTP_PASV_MIN_PORT}"   ;; esac
  case "${FTP_PASV_MAX_PORT}"  in ''|*[!0-9]*) log_fail "FTP_PASV_MAX_PORT is not numeric: ${FTP_PASV_MAX_PORT}"   ;; esac
  case "${FTP_CONTROL_PORT}"   in ''|*[!0-9]*) log_fail "FTP_CONTROL_PORT is not numeric: ${FTP_CONTROL_PORT}"   ;; esac

  # Pre-create the FTP user home so the bind mount has the
  # directory vsftpd will chown to the FTP user at startup.
  mkdir -p "${_sfs_data_dir}/${_sfs_user}"
  chmod -R 0777 "${_sfs_data_dir}"

  # Write the overlay vsftpd.conf. mktemp puts it in $TMPDIR
  # (default /tmp); we keep it until the scenario ends because
  # the bind-mount reads from this path. The file is ~700 bytes
  # and the OS sweeps /tmp on reboot.
  _sfs_conf=$(mktemp -t vsftpdconf.XXXXXX) \
    || log_fail "mktemp vsftpd.conf failed"
  _write_ftps_vsftpd_conf "${_sfs_conf}" \
    "${_sfs_host_port}" \
    "${FTP_PASV_MIN_PORT}" "${FTP_PASV_MAX_PORT}" \
    "${_sfs_implicit_flag}"

  _sfs_name=$(unique_container_name "ftpsvr")

  # Boot the pre-baked FTPS test server image detached. The -c
  # payload only does the per-scenario work that depends on the
  # scenario's FTP_USER/FTP_PASS: fixes the alpine-vsftpd TLS
  # variable naming (see below), creates the FTP user, fixes the
  # chown of the user home, and exec's vsftpd (so vsftpd is PID 1
  # and inherits the container's signal handling). Quoting is the
  # standard single-quoted-literal / double-quoted-interpolation
  # mix so ${_sfs_user} and ${_sfs_pass} are expanded by the OUTER
  # shell (the harness) and not by the container's /bin/sh.
  #
  # _write_ftps_vsftpd_conf writes the TLS version gates as
  # ssl_tlsv1_1 / ssl_tlsv1_2. The vsftpd build in the test-server
  # image (the version pinned in Dockerfile.test-server) expects
  # ssl_tlsv11 / ssl_tlsv12 instead, and would reject the underscore
  # names as unrecognised config variables. So this payload copies
  # the read-only bind-mounted conf to a writable path and
  # sed-rewrites those two lines in the copy. (History: the helper
  # used the underscore names because they were written for the
  # fauria/vsftpd image these scenarios originally used.)
  #
  # Why the image is pre-baked (closes #135): the previous version
  # of this payload started with `apk add --no-cache vsftpd`,
  # which downloaded the alpine package index from the network on
  # every scenario run. That step occasionally took >20s in CI and
  # even failed outright on transient network blips, surfacing as
  # flaky scenario failures. tests/integration/Dockerfile.test-server
  # moves the apk install + the /var/log/vsftpd and /etc/pam.d/
  # vsftpd_virtual prep into the image so this payload is purely
  # per-scenario work (no network).
  #
  # Why no `--rm`: when the FTPS container died during boot (the
  # root cause of the #135 flake), `--rm` garbage-collected it
  # before `docker logs` could read the boot trace, surfacing as
  # "No such container" in the harness and making the failure
  # impossible to diagnose. The EXIT trap in scenario_setup
  # installs stop_ftp_server, which already runs `rm -f` on
  # ${FTP_CONTAINER_NAME} (via docker/podman rm -f), so removing
  # `--rm` here buys us post-mortem diagnostics at no cleanup
  # cost.
  # --init: as PID 1, vsftpd also reaps orphaned processes it never
  # forked and segfaults on them (#138); a real init reaps them instead.
  if ! ${RUNTIME} run -d --init \
      --name "${_sfs_name}" \
      --network host \
      -p "${_sfs_host_port}:${_sfs_container_port}" \
      -p "${FTP_PASV_MIN_PORT}-${FTP_PASV_MAX_PORT}:${FTP_PASV_MIN_PORT}-${FTP_PASV_MAX_PORT}" \
      -v "${_sfs_data_dir}:/home/vsftpd" \
      -v "${_sfs_cert}:/etc/vsftpd/vsftpd.pem:ro" \
      -v "${_sfs_conf}:/etc/vsftpd.conf:ro" \
      --entrypoint '/bin/sh' \
      "${FTP_TEST_SERVER_IMAGE}" \
      -c '
          set -eu
          cp /etc/vsftpd.conf /tmp/vsftpd.conf
          sed -i "s/^ssl_tlsv1_1=/ssl_tlsv11=/; s/^ssl_tlsv1_2=/ssl_tlsv12=/" /tmp/vsftpd.conf
          if ! adduser -D -h /home/vsftpd '"${_sfs_user}"' 2>"/tmp/adduser.err"; then
            case "$(cat /tmp/adduser.err)" in
              *"already exists"*) : ;;
              *) printf "FAIL: adduser failed: %s\n" "$(cat /tmp/adduser.err)" >&2; exit 1 ;;
            esac
          fi
          rm -f /tmp/adduser.err
          echo '"${_sfs_user}"':'"${_sfs_pass}"' | chpasswd
          chmod 0777 /home/vsftpd/'"${_sfs_user}"'
          exec vsftpd /tmp/vsftpd.conf
      ' >/dev/null; then
    rm -f "${_sfs_conf}"
    log_fail "failed to start ftps server container"
  fi

  FTP_CONTAINER_NAME="${_sfs_name}"
  export FTP_CONTAINER_NAME
  FTP_DATA_DIR="${_sfs_data_dir}"
  export FTP_DATA_DIR
  FTP_SERVER_PORT="${_sfs_host_port}"
  export FTP_SERVER_PORT
  # Overlay vsftpd.conf bind-mounted into the container. Exported so
  # the scenario-level EXIT trap can rm -f it on success paths
  # (the container rm is handled by stop_ftp_server; the overlay
  # conf is per-scenario helper state). Mirrors the FTP_CONTAINER_NAME
  # / FTP_DATA_DIR pattern above.
  FTP_VSFTPD_CONF="${_sfs_conf}"
  export FTP_VSFTPD_CONF

  if ! wait_for_listen "${FTP_CONTAINER_NAME}" "${_sfs_host_port}" 20; then
    ${RUNTIME} logs "${FTP_CONTAINER_NAME}" >&2 || true
    log_fail "vsftpd was not listening on port ${_sfs_host_port} within 20s"
  fi

  # vsftpd chowns the chroot directory to the FTP user. On
  # rootless container runtimes that map the container uid to a
  # high host uid, the host-side directory ends up owned by a
  # uid the test runner does NOT own, so `ls` from the host
  # fails with EACCES. chmod 0777 inside the container (which
  # runs as root) makes the dir world-readable regardless of
  # the host-side uid mapping. Same fix as start_ftp_server in
  # common.sh.
  ${RUNTIME} exec "${FTP_CONTAINER_NAME}" \
      chmod 0777 "/home/vsftpd/${_sfs_user}" >/dev/null 2>&1 || true

  log_info "ftps server up (container=${FTP_CONTAINER_NAME}, user=${_sfs_user}, data=${_sfs_data_dir}, host_port=${_sfs_host_port}, mode=${_sfs_mode})"
}
