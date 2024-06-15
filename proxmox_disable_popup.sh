#!/bin/bash
# Removes the "You do not have a valid subscription for this server" popup message while logging in
# https://johnscs.com/remove-proxmox51-subscription-notice/

# Manual steps:
# 1. Change to working directory
#    cd /usr/share/javascript/proxmox-widget-toolkit
# 2. Make a backup
#    cp proxmoxlib.js proxmoxlib.js.bak
# 3. Edit the file “proxmoxlib.js”
#    nano proxmoxlib.js
# 4. Locate the following code (Use ctrl+w in nano and search for “function(orig_cmd)”
#    checked_command: function(orig_cmd) {
# 5. Add “orig_cmd();” and “return;” just after it
#    checked_command: function(orig_cmd) {
#        orig_cmd();
#        return;
# 6. Restart the Proxmox web service (also be sure to clear your browser cache, depending on the browser you may need to open a new tab or restart the browser)
#    systemctl restart pveproxy.service

sed -Ezi.bak "s/(function\(orig_cmd\) \{)/\1\n\torig_cmd\(\);\n\treturn;/g" /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js && systemctl restart pveproxy.service
