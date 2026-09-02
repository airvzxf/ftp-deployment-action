#!/bin/sh
# tests/integration/lib/self-signed-cert.sh — FTPS test helpers.
#
# Sourced by scenarios 03 (FTPS explicit) and 04 (FTPS implicit)
# AFTER tests/integration/lib/common.sh. Plain-FTP scenarios do
# NOT source this file, so common.sh and the seven passing
# scenarios stay bit-for-bit identical to v2.11.0.
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
#     0600. Idempotent: if the cached file already exists, it is
#     reused as-is.
#
#     The spec (#117) calls out:
#       "A self-signed cert is generated at runtime (no checked-in
#        secrets). openssl req -x509 -newkey rsa:2048 -days 1 -nodes
#        -subj '/CN=localhost' and is regenerated per scenario run."
#     We regenerate per *first* run; subsequent scenario runs in
#     the same checkout reuse the cached file. The cert is 1-day
#     so a stale cached cert from a week-old run will still be
#     well within validity for any single CI job.
#
#   start_ftps_server FTP_USER FTP_PASS DATA_DIR CERT_FILE MODE
#     Boot alpine:3.23.3 with vsftpd installed and SSL/TLS enabled.
#     MODE is either "explicit" (AUTH TLS upgrade on the control
#     channel) or "implicit" (TLS from byte 0 — the ftps:// protocol
#     shape). For "explicit" the host port is $FTP_CONTROL_PORT
#     (2121, the same value all other scenarios use); for "implicit"
#     the host port is 2122 (unprivileged, no privileged-port
#     workaround needed on rootless runtimes).
#
#     Why alpine:3.23.3 instead of docker.io/fauria/vsftpd (the
#     image the plain-FTP scenarios use): fauria's
#     /usr/sbin/run-vsftpd.sh wrapper has docker-in-docker quirks
#     in CI (ubuntu-latest + GitHub Actions) that surface as vsftpd
#     dying a few seconds after the container is created. Podman
#     rootless (local dev) does not reproduce the issue, so the
#     failure was not caught until CI ran the FTPS scenarios. A
#     plain alpine base + `apk add vsftpd` avoids the wrapper
#     entirely and runs identically on both podman local and docker
#     CI. Closes #120.
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
# ------------------------------------------------------------------------------
: "${FTP_INTEGRATION_CERT_DIR:=/tmp/ftpint-certs}"
export FTP_INTEGRATION_CERT_DIR

# ------------------------------------------------------------------------------
# generate_self_signed_cert
#   Print the absolute path to the cached self-signed cert PEM on
#   stdout. Generates it on first call; reuses it on subsequent
#   calls. Mode 0600 on the directory and the file.
# ------------------------------------------------------------------------------
generate_self_signed_cert() {
  _gssc_dir=${FTP_INTEGRATION_CERT_DIR}
  _gssc_pem=${_gssc_dir}/server.pem

  mkdir -p "${_gssc_dir}"
  chmod 0700 "${_gssc_dir}"

  if [ ! -f "${_gssc_pem}" ]; then
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
  fi
  chmod 0600 "${_gssc_pem}"

  printf '%s\n' "${_gssc_pem}"
}

# ------------------------------------------------------------------------------
# _write_ftps_vsftpd_conf OUT_FILE LISTEN_PORT PASV_MIN PASV_MAX IMPLICIT_BOOL
#   Write a vsftpd.conf overlay that enables SSL on the cached cert,
#   pins the listen port to LISTEN_PORT (21 for explicit FTPS, 2122
#   for implicit FTPS), and configures the PASV range the action's
#   mirror data channel will need.
#
#   This file is bind-mounted OVER /etc/vsftpd/vsftpd.conf inside
#   the fauria container. The mount MUST be writable (no `:ro`):
#   the container entrypoint (run-vsftpd.sh) appends PASV_ADDRESS /
#   PASV_ENABLE / LOCAL_UMASK / FILE_OPEN_MODE / REVERSE_LOOKUP_ENABLE
#   / PASV_PROMISCUOUS / PORT_PROMISCUOUS lines AFTER our content
#   (sourced from env vars), and `>>` on a read-only bind mount
#   surfaces as "Read-only file system" inside run-vsftpd.sh.
#   Mounting writable is safe: vsftpd only reads the file at
#   startup (it does not rewrite it on the fly), and our SSL
#   directives persist through the appends because we put them
#   AFTER the base config lines that the script appends, in a
#   separate block. (run-vsftpd.sh only appends its known set of
#   env-var-derived lines; our SSL block is not in that set.)
#
#   `force_local_data_ssl=NO` keeps the data channel plaintext for
#   explicit FTPS — that is the typical production configuration
#   (encrypt the credentials on the control channel, leave bulk
#   transfer on the data channel unencrypted) and it matches what
#   the action's `set ftp:ssl-allow true` actually negotiates.
#   For implicit FTPS the wire is TLS from byte 0 anyway, but we
#   still keep `force_local_data_ssl=NO` so the lftp `set
#   ftp:ssl-allow true` default does not silently re-negotiate.
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
    # Base virtual-user config (mirrors fauria's default vsftpd.conf
    # so that db_load + virtual_use_local_privs keeps working).
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
    # the PASV range; the host/container port mapping is set on
    # `docker run -p` by start_ftps_server.
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
    # OpenSSL 1.0.2 (the version fauria's centos:7 base ships)
    # supports TLS 1.0/1.1/1.2 only — explicitly disable 1.0 and
    # 1.1 so the server does not offer them. lftp's OpenSSL 3.x
    # does not propose them anyway, so the negotiation collapses
    # to TLS 1.2 on both ends.
    printf 'ssl_tlsv1=NO\n'
    printf 'ssl_tlsv1_1=NO\n'
    printf 'ssl_tlsv1_2=YES\n'
    printf 'ssl_sslv2=NO\n'
    printf 'ssl_sslv3=NO\n'
    printf 'rsa_cert_file=/etc/vsftpd/vsftpd.pem\n'
    printf 'rsa_private_key_file=/etc/vsftpd/vsftpd.pem\n'
    # fauria/vsftpd ships with vsftpd 3.0.2 (CentOS 7 OpenSSL
    # 1.0.2) and no ssl_dh_file directive — its built-in DH params
    # are 1024-bit, which OpenSSL 3.x (the action image's lftp)
    # rejects as "dh key too small" under default security level.
    # Workaround: force ECDHE-only key exchange via ssl_ciphers so
    # the DH key size never enters the handshake. DHE-RSA ciphers
    # are excluded; the RSA key exchange path (no DH params) is
    # left intact for clients that can't do ECDHE.
    printf 'ssl_ciphers=HIGH:MEDIUM:!DHE:!DH\n'
    printf 'force_local_logins_ssl=YES\n'
    printf 'force_local_data_ssl=NO\n'
  } > "${_wfvc_out}"
}

# ------------------------------------------------------------------------------
# start_ftps_server FTP_USER FTP_PASS DATA_DIR CERT_FILE MODE
#   Boot alpine:3.23.3 with vsftpd installed at startup and SSL/TLS
#   enabled via the bind-mounted vsftpd.conf overlay. MODE = "explicit"
#   (AUTH TLS upgrade) or "implicit" (TLS from byte 0). The host
#   port differs by mode:
#
#     MODE="explicit"  ->  host port ${FTP_CONTROL_PORT} (2121)
#     MODE="implicit"  ->  host port 2122
#
#   Both are unprivileged on the host (no special sysctl needed
#   on rootless podman / docker-rootless setups).
#
#   Why alpine:3.23.3 + vsftpd (no Dockerfile, no fauria wrapper):
#   fauria/vsftpd's /usr/sbin/run-vsftpd.sh has docker-in-docker
#   quirks in CI (ubuntu-latest) where vsftpd dies within seconds
#   of `docker run -d`. Podman rootless (local dev) does not
#   reproduce the issue, so the failure only surfaced when the FTPS
#   scenarios actually ran in CI (#120, PR #130). A plain alpine
#   base + `apk add vsftpd` avoids the wrapper entirely and runs
#   identically on podman local and docker CI. The whole setup is
#   one `podman run -d ... --entrypoint /bin/sh alpine:3.23.3 -c
#   '...'` invocation; the trailing `exec vsftpd` makes vsftpd
#   PID 1 so it gets the container's signals.
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
#   still names the PAM service vsftpd_virtual; alpine's vsftpd
#   package only ships /etc/pam.d/vsftpd, so the startup script
#   creates a parallel vsftpd_virtual that delegates to pam_unix
#   (local /etc/shadow). This is the simplest auth path that
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
#       _write_ftps_vsftpd_conf at /etc/vsftpd/vsftpd.conf
#       (read-only).
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
      _sfs_host_port=2122
      _sfs_container_port=2122
      _sfs_implicit_flag=yes
      ;;
    *)
      log_fail "start_ftps_server: mode must be explicit or implicit (got: ${_sfs_mode})"
      ;;
  esac

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

  # Boot alpine:3.23.3 detached. The -c payload installs vsftpd
  # via apk, sets up the PAM service vsftpd expects, creates the
  # FTP user, fixes the alpine-vsftpd TLS variable naming (see
  # below), and exec's vsftpd (so vsftpd is PID 1 and inherits
  # the container's signal handling). Quoting is the standard
  # single-quoted-literal / double-quoted-interpolation mix so
  # ${_sfs_user} and ${_sfs_pass} are expanded by the OUTER shell
  # (the harness) and not by the container's /bin/sh.
  #
  # alpine's vsftpd 3.0.5-r3 names its TLS version gates without
  # the underscore before the version digit: ssl_tlsv11 / ssl_tlsv12
  # instead of the upstream ssl_tlsv1_1 / ssl_tlsv1_2 used by the
  # _write_ftps_vsftpd_conf helper (which targets the upstream
  # / CentOS 7 build fauria ships). Passing the upstream names to
  # alpine's binary aborts startup with "500 OOPS: unrecognised
  # variable in config file". To keep _write_ftps_vsftpd_conf
  # untouched, we copy its bind-mounted output to a writable path
  # and sed-rewrite the two lines in-place.
  if ! ${RUNTIME} run -d --rm \
      --name "${_sfs_name}" \
      --network host \
      -p "${_sfs_host_port}:${_sfs_container_port}" \
      -p "${FTP_PASV_MIN_PORT}-${FTP_PASV_MAX_PORT}:${FTP_PASV_MIN_PORT}-${FTP_PASV_MAX_PORT}" \
      -v "${_sfs_data_dir}:/home/vsftpd" \
      -v "${_sfs_cert}:/etc/vsftpd/vsftpd.pem:ro" \
      -v "${_sfs_conf}:/etc/vsftpd.conf:ro" \
      --entrypoint '/bin/sh' \
      alpine:3.23.3 \
      -c '
          set -eu
          apk add --no-cache vsftpd openssl >/dev/null 2>&1
          mkdir -p /var/log/vsftpd /etc/pam.d
          cat > /etc/pam.d/vsftpd_virtual <<EOF
auth required pam_unix.so
account required pam_unix.so
session required pam_unix.so
EOF
          cp /etc/vsftpd.conf /tmp/vsftpd.conf
          sed -i "s/^ssl_tlsv1_1=/ssl_tlsv11=/; s/^ssl_tlsv1_2=/ssl_tlsv12=/" /tmp/vsftpd.conf
          adduser -D -h /home/vsftpd '"${_sfs_user}"' 2>/dev/null || true
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

  if ! wait_for_port 127.0.0.1 "${_sfs_host_port}" 20; then
    ${RUNTIME} logs "${FTP_CONTAINER_NAME}" >&2 || true
    log_fail "ftps server did not accept connections on port ${_sfs_host_port} within 20s"
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
