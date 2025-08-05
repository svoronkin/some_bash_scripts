#!/bin/sh
# Script to remove old revisions of snaps
# IMPORTANT: CLOSE ALL SNAPS BEFORE RUNNING THIS SCRIPT

# Enable strict error handling
set -eu

# Define color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Warning message
echo -e "${RED}IMPORTANT: CLOSE ALL SNAP APPS BEFORE RUNNING THIS SCRIPT${NC}"
echo ""

# User confirmation for clearing cache
read -p "This will clear the snapd cache. Do you want to continue? (y/n): " confirm_cache
if [ "$confirm_cache" != "y" ] && [ "$confirm_cache" != "Y" ]; then
    echo -e "${YELLOW}Cache clearing operation cancelled by the user.${NC}"
else
    # Clear the snapd cache
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Clearing Snapd Cache${NC}"
    echo -e "${GREEN}This may take a moment...${NC}"
    sudo rm -rf /var/lib/snapd/cache/*
    echo -e "${GREEN}Cache cleared successfully.${NC}"
fi

# User confirmation for removing old snap revisions
read -p "This will remove old snap revisions. Do you want to continue? (y/n): " confirm_revisions
if [ "$confirm_revisions" != "y" ] && [ "$confirm_revisions" != "Y" ]; then
    echo -e "${YELLOW}Old revisions removal operation cancelled by the user.${NC}"
    exit 0
fi

# Notify the user about the removal process
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Removing Old Snap Revisions${NC}"
echo -e "${GREEN}========================================${NC}"

# Remove old revisions of snaps
snap list --all | awk '/disabled/{print $1, $3}' |
    while read -r snapname revision; do
        echo -e "${YELLOW}Removing $snapname (revision $revision)...${NC}"
        snap remove "$snapname" --revision="$revision"
        sleep 1  # Optional: Add a short delay for better visibility
    done

# Final message
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Process Complete${NC}"
echo -e "${GREEN}Old revisions removed successfully.${NC}"
