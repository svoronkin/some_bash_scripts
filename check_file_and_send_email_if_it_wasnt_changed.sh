#!/bin/bash
# Needed installed and configured postfix and mailutils
# Set the variables
TO_ADDRESS="EMAIL"
FILE_PATH="/path/to/file"
SUBJECT="File Modified Alert"
HOST=$HOSTNAME
BODY="The file ${FILE_PATH} at ${HOST} was modified more than 2 hours ago."

# Check if the file was modified more than 2 hours ago
if [ $(find "${FILE_PATH}" -type f -mmin +120) ]
then
  # Send the email using Postfix
  echo "${BODY}" | mail -s "${SUBJECT}" "${TO_ADDRESS}"
fi
