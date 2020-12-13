#!/bin/sh -e

echo "=== Environment variables ==="
echo "INPUT_SERVER: ${INPUT_SERVER}"
echo "INPUT_USER: ${INPUT_USER}"
echo "INPUT_PASSWORD: ${INPUT_PASSWORD}"
echo "INPUT_LOCAL_DIR: ${INPUT_LOCAL_DIR}"
echo "INPUT_REMOTE_DIR: ${INPUT_REMOTE_DIR}"
echo "INPUT_DELETE: ${INPUT_DELETE}"
echo "INPUT_MAX_RETRIES: ${INPUT_MAX_RETRIES}"
echo "INPUT_NO_SYMLINKS: ${INPUT_NO_SYMLINKS}"
echo "INPUT_FTP_SSL_ALLOW: ${INPUT_FTP_SSL_ALLOW}"
echo "INPUT_FTP_USE_FEAT: ${INPUT_FTP_USE_FEAT}"
echo "INPUT_FTP_NOP_INTERVAL : ${INPUT_FTP_NOP_INTERVAL}"
echo "INPUT_NET_MAX_RETRIES : ${INPUT_NET_MAX_RETRIES}"
echo "INPUT_NET_PERSIST_RETRIES : ${INPUT_NET_PERSIST_RETRIES}"
echo "INPUT_NET_TIMEOUT : ${INPUT_NET_TIMEOUT}"
echo "INPUT_DNS_MAX_RETRIES : ${INPUT_DNS_MAX_RETRIES}"
echo "INPUT_DNS_FATAL_TIMEOUT : ${INPUT_DNS_FATAL_TIMEOUT}"
echo ""
echo "=== Current location ==="
pwd
echo ""
echo "=== List this directory ==="
ls -lha
echo ""

FTP_SETTINGS="set ftp:ssl-allow ${INPUT_FTP_SSL_ALLOW};"
FTP_SETTINGS="${FTP_SETTINGS} set ftp:use-feat ${INPUT_FTP_USE_FEAT};"
FTP_SETTINGS="${FTP_SETTINGS} set ftp:nop-interval ${INPUT_FTP_NOP_INTERVAL};"
FTP_SETTINGS="${FTP_SETTINGS} set net:max-retries ${INPUT_NET_MAX_RETRIES};"
FTP_SETTINGS="${FTP_SETTINGS} set net:persist-retries ${INPUT_NET_PERSIST_RETRIES};"
FTP_SETTINGS="${FTP_SETTINGS} set net:timeout ${INPUT_NET_TIMEOUT};"
FTP_SETTINGS="${FTP_SETTINGS} set dns:max-retries ${INPUT_DNS_MAX_RETRIES};"
FTP_SETTINGS="${FTP_SETTINGS} set dns:fatal-timeout ${INPUT_DNS_FATAL_TIMEOUT};"

MIRROR_COMMAND="mirror --continue --reverse"

if [ -z "${INPUT_MAX_RETRIES}" ]; then
  INPUT_MAX_RETRIES="10"
fi

if [ -z "${INPUT_LOCAL_DIR}" ]; then
  INPUT_LOCAL_DIR="./"
else
  if [ "${INPUT_LOCAL_DIR}" != "./" ]; then
    INPUT_LOCAL_DIR="${INPUT_LOCAL_DIR}/"
  fi
fi

if [ -z "${INPUT_REMOTE_DIR}" ]; then
  INPUT_REMOTE_DIR="./"
else
  if [ "${INPUT_REMOTE_DIR}" != "./" ]; then
    INPUT_REMOTE_DIR="${INPUT_REMOTE_DIR}/"
  fi
fi

if [ "${INPUT_NO_SYMLINKS}" = "true" ]; then
  MIRROR_COMMAND="${MIRROR_COMMAND} --no-symlinks"
fi

if [ "${INPUT_DELETE}" = "true" ]; then
  MIRROR_COMMAND="${MIRROR_COMMAND} --delete"
fi

echo "=== Directories ==="
echo "INPUT_LOCAL_DIR: ${INPUT_LOCAL_DIR}"
echo "INPUT_REMOTE_DIR: ${INPUT_REMOTE_DIR}"
echo ""
echo "=== List local directory | ${INPUT_LOCAL_DIR} ==="
ls -lha "${INPUT_LOCAL_DIR}"
echo ""
echo "=== LFTP ==="
echo "lftp"
echo " FTP_SETTINGS     -> ${FTP_SETTINGS}"
echo " MIRROR_COMMAND   -> ${MIRROR_COMMAND}"
echo " INPUT_LOCAL_DIR  -> ${INPUT_LOCAL_DIR}"
echo " INPUT_REMOTE_DIR -> ${INPUT_REMOTE_DIR}"
echo ""
echo "=== * NOTE * ==="
echo "The upload should be fast depends how many files and what size they have."
echo "If the process take for several minutes, please stop the job and run it again."
echo ""

COUNTER=1
SUCCESS=""

until [ ${COUNTER} -gt ${INPUT_MAX_RETRIES} ]; do
  echo ""
  echo "Try #: ${COUNTER}"
  echo "# ---------------------------------------------"
  lftp \
    --debug \
    -u "${INPUT_USER}","${INPUT_PASSWORD}" \
    "${INPUT_SERVER}" \
    -e "${FTP_SETTINGS} ${MIRROR_COMMAND} ${INPUT_LOCAL_DIR} ${INPUT_REMOTE_DIR}; quit;" &&
    SUCCESS="true"

  if [ -n "${SUCCESS}" ]; then
    break
  fi

  sleep 1m
  COUNTER=$((COUNTER + 1))
done

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
