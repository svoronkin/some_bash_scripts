#!/bin/bash

# Set the maximum allowed disk space usage percentage
MAX=90

# Set the email address to receive alerts
EMAIL=user@example.com

# Set the partition to monitor (change accordingly, e.g., /dev/sda1)
PARTITION=/dev/sda1

# Get the current disk usage percentage and related information
USAGE_INFO=$(df -h "$PARTITION" | awk 'NR==2 {print $5, $1, $2, $3, $4}' | tr '\n' ' ')
USAGE=$(echo "$USAGE_INFO" | awk '{print int($1)}')  # Remove the percentage sign

if [ "$USAGE" -gt "$MAX" ]; then
  # Send an email alert with detailed disk usage information
  echo -e "Warning: Disk space usage on $PARTITION is $USAGE%.\n\nDisk Usage Information:\n$USAGE_INFO" | \
    mail -s "Disk Space Alert on $HOSTNAME" "$EMAIL"
fi