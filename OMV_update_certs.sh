#!/bin/bash

# Tool for update TLS certs at OpenMediaVault
# Usage: sudo ./OMV_update_cert.sh <UUID> cert.pem privkey.pem


. /usr/share/openmediavault/scripts/helper-functions
. /etc/default/openmediavault

if [[ $(id -u) -ne 0 ]]; then
  echo "This script must be executed as root or using sudo."
  exit 99
fi

uuid="${1}"
cert="${2}"
key="${3}"

if ! omv_isuuid "${uuid}"; then
  echo "Invalid uuid"
  exit 1
fi

if [ ! -f "${cert}" ]; then
  echo "Cert not found"
  exit 2
fi

if [ ! -f "${key}" ]; then
  echo "Key not found"
  exit 3
fi

echo "Cert file :: ${cert}"
echo "Key file :: ${key}"

xpath="/config/system/certificates/sslcertificate[uuid='${uuid}']"
echo "xpath :: ${xpath}"
echo

if ! omv_config_exists "${xpath}"; then
  echo "Config for ${uuid} does not exist"
  exit 4
fi

echo "Updating certificate in database ..."
omv_config_update "${xpath}/certificate" "$(cat ${cert})"

echo "Updating private key in database ..."
omv_config_update "${xpath}/privatekey" "$(cat ${key})"

if [ -n "${4}" ]; then
  echo "Updating comment in database ..."
  omv_config_update "${xpath}/comment" "${4}"
fi

echo "Updating certs and nginx..."
omv-salt deploy run certificates nginx

systemctl restart nginx

exit 0
