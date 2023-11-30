#!/bin/sh -e

# ------------------------------------------------------------------------------
# Display environment variables.
# ------------------------------------------------------------------------------
echo "=== Environment variables ==="
echo "INPUT_SERVER: ${INPUT_SERVER}"
echo "INPUT_USER: ${INPUT_USER}"
echo "INPUT_PASSWORD: ${INPUT_PASSWORD}"
echo "INPUT_LOCAL_DIR: ${INPUT_LOCAL_DIR}"
echo "INPUT_REMOTE_DIR: ${INPUT_REMOTE_DIR}"
echo "INPUT_MAX_RETRIES: ${INPUT_MAX_RETRIES}"
echo "INPUT_DELETE: ${INPUT_DELETE}"
echo "INPUT_NO_SYMLINKS: ${INPUT_NO_SYMLINKS}"
echo "INPUT_MIRROR_VERBOSE: ${INPUT_MIRROR_VERBOSE}"
echo "INPUT_FTP_SSL_ALLOW: ${INPUT_FTP_SSL_ALLOW}"
echo "INPUT_FTP_USE_FEAT: ${INPUT_FTP_USE_FEAT}"
echo "INPUT_FTP_NOP_INTERVAL: ${INPUT_FTP_NOP_INTERVAL}"
echo "INPUT_NET_MAX_RETRIES: ${INPUT_NET_MAX_RETRIES}"
echo "INPUT_NET_PERSIST_RETRIES: ${INPUT_NET_PERSIST_RETRIES}"
echo "INPUT_NET_TIMEOUT: ${INPUT_NET_TIMEOUT}"
echo "INPUT_DNS_MAX_RETRIES: ${INPUT_DNS_MAX_RETRIES}"
echo "INPUT_DNS_FATAL_TIMEOUT: ${INPUT_DNS_FATAL_TIMEOUT}"
echo "INPUT_LFTP_SETTINGS: ${INPUT_LFTP_SETTINGS}"
echo ""
echo "=== Current location ==="
pwd
echo ""

# ------------------------------------------------------------------------------
# Set the LFTP setting.
# ------------------------------------------------------------------------------
FTP_SETTINGS=""

# ftp:ssl-allow
if [ -n "${INPUT_FTP_SSL_ALLOW}" ]; then
  FTP_SETTINGS="${FTP_SETTINGS} set ftp:ssl-allow ${INPUT_FTP_SSL_ALLOW};"
else
  FTP_SETTINGS="${FTP_SETTINGS} set ftp:ssl-allow true;"
fi

# ftp:use-feat
if [ -n "${INPUT_FTP_USE_FEAT}" ]; then
  FTP_SETTINGS="${FTP_SETTINGS} set ftp:use-feat ${INPUT_FTP_USE_FEAT};"
else
  FTP_SETTINGS="${FTP_SETTINGS} set ftp:use-feat true;"
fi

# ftp:nop-interval
if [ -n "${INPUT_FTP_NOP_INTERVAL}" ]; then
  FTP_SETTINGS="${FTP_SETTINGS} set ftp:nop-interval ${INPUT_FTP_NOP_INTERVAL};"
else
  FTP_SETTINGS="${FTP_SETTINGS} set ftp:nop-interval 2;"
fi

# net:max-retries
if [ -n "${INPUT_NET_MAX_RETRIES}" ]; then
  FTP_SETTINGS="${FTP_SETTINGS} set net:max-retries ${INPUT_NET_MAX_RETRIES};"
else
  FTP_SETTINGS="${FTP_SETTINGS} set net:max-retries 1;"
fi

# net:persist-retries
if [ -n "${INPUT_NET_PERSIST_RETRIES}" ]; then
  FTP_SETTINGS="${FTP_SETTINGS} set net:persist-retries ${INPUT_NET_PERSIST_RETRIES};"
else
  FTP_SETTINGS="${FTP_SETTINGS} set net:persist-retries 5;"
fi

# net:timeout
if [ -n "${INPUT_NET_TIMEOUT}" ]; then
  FTP_SETTINGS="${FTP_SETTINGS} set net:timeout ${INPUT_NET_TIMEOUT};"
else
  FTP_SETTINGS="${FTP_SETTINGS} set net:timeout 15s;"
fi

# dns:max-retries
if [ -n "${INPUT_DNS_MAX_RETRIES}" ]; then
  FTP_SETTINGS="${FTP_SETTINGS} set dns:max-retries ${INPUT_DNS_MAX_RETRIES};"
else
  FTP_SETTINGS="${FTP_SETTINGS} set dns:max-retries 8;"
fi

# dns:fatal-timeout
if [ -n "${INPUT_DNS_FATAL_TIMEOUT}" ]; then
  FTP_SETTINGS="${FTP_SETTINGS} set dns:fatal-timeout ${INPUT_DNS_FATAL_TIMEOUT};"
else
  FTP_SETTINGS="${FTP_SETTINGS} set dns:fatal-timeout 10s;"
fi

# Any manual settings
if [ -n "${INPUT_LFTP_SETTINGS}" ]; then
  FTP_SETTINGS="${FTP_SETTINGS} ${INPUT_LFTP_SETTINGS};"
fi

# Remove first space in settings variable
if [ -n "${FTP_SETTINGS}" ]; then
  FTP_SETTINGS="${FTP_SETTINGS#"${FTP_SETTINGS%%[![:space:]]*}"}"
fi

# Max number of retries
if [ -z "${INPUT_MAX_RETRIES}" ]; then
  INPUT_MAX_RETRIES="10"
fi

# Local path to get the directories
if [ -z "${INPUT_LOCAL_DIR}" ]; then
  INPUT_LOCAL_DIR="./"
else
  INPUT_LOCAL_DIR="${INPUT_LOCAL_DIR}/"
fi

# Remote path to put the directories
if [ -z "${INPUT_REMOTE_DIR}" ]; then
  INPUT_REMOTE_DIR="./"
else
  INPUT_REMOTE_DIR="${INPUT_REMOTE_DIR}/"
fi

# Reverse mirror which uploads or updates a directory tree on server
MIRROR_COMMAND="mirror --continue --reverse"

# Mirror verbosity level
if [ -n "${INPUT_MIRROR_VERBOSE}" ]; then
  MIRROR_COMMAND="${MIRROR_COMMAND} --verbose=${INPUT_MIRROR_VERBOSE}"
else
  MIRROR_COMMAND="${MIRROR_COMMAND} --verbose=1"
fi

# Don't create symbolic links
if [ "${INPUT_NO_SYMLINKS}" = "true" ]; then
  MIRROR_COMMAND="${MIRROR_COMMAND} --no-symlinks"
fi

# Delete files not present at the source
if [ "${INPUT_DELETE}" = "true" ]; then
  MIRROR_COMMAND="${MIRROR_COMMAND} --delete"
fi

# ------------------------------------------------------------------------------
# Display LFTP settings.
# ------------------------------------------------------------------------------
echo "=== Directories ==="
echo "INPUT_LOCAL_DIR: ${INPUT_LOCAL_DIR}"
echo "INPUT_REMOTE_DIR: ${INPUT_REMOTE_DIR}"
echo ""
echo "=== List local directory ==="
echo "${INPUT_LOCAL_DIR}"
ls -lha "${INPUT_LOCAL_DIR}"
echo ""
echo "=== LFTP Settings ==="
echo " FTP_SETTINGS      -> ${FTP_SETTINGS}"
echo " MIRROR_COMMAND    -> ${MIRROR_COMMAND}"
echo " INPUT_LOCAL_DIR   -> ${INPUT_LOCAL_DIR}"
echo " INPUT_REMOTE_DIR  -> ${INPUT_REMOTE_DIR}"
echo " INPUT_MAX_RETRIES -> ${INPUT_MAX_RETRIES}"
echo ""
echo "=== * NOTE * ==="
echo "The upload should be fast depends how many files and what size they have."
echo "If the process take for several minutes or hours, please stop the job and run it again."

# ------------------------------------------------------------------------------
# Execute the LFTP actions.
# ------------------------------------------------------------------------------
COUNTER=1
SUCCESS=""

while true; do
  echo ""
  echo "Try #${COUNTER}"
  echo "-------"

  lftp \
    -u "${INPUT_USER}","${INPUT_PASSWORD}" \
    "${INPUT_SERVER}" \
    -e "${FTP_SETTINGS} ${MIRROR_COMMAND} ${INPUT_LOCAL_DIR} ${INPUT_REMOTE_DIR}; quit;" &&
    SUCCESS="true"

  if [ -n "${SUCCESS}" ]; then
    break
  fi

  COUNTER=$((COUNTER + 1))
  if [ ${COUNTER} -gt ${INPUT_MAX_RETRIES} ]; then
    break
  fi

  sleep 1m
done

# ------------------------------------------------------------------------------
# Display the status of the LFTP actions.
# ------------------------------------------------------------------------------
if [ -z "${SUCCESS}" ]; then
  echo ""
  echo "=============================="
  echo "=    ERROR: UPLOAD FAILED    ="
  echo "=============================="
  exit 1
fi

echo ""
echo "=============================="
echo "=   FTP UPLOADED FINISHED!   ="
echo "=============================="
