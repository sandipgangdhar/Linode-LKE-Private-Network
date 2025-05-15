#!/bin/bash

# Usage: ./05-script-ip-list-initialize.sh <subnet>
# Example: ./05-script-ip-list-initialize.sh 192.168.0.0/16

if [ -z "$1" ]; then
    echo "[ERROR] Usage: ./05-script-ip-list-initialize.sh <subnet>"
    exit 1
fi

SUBNET="$1"
IP_LIST_FILE="/mnt/vlan-ip/vlan-ip-list.txt"

# Check if the file already exists and has data
if [ -f "$IP_LIST_FILE" ] && [ -s "$IP_LIST_FILE" ]; then
    echo "[ERROR] IP list already initialized at $IP_LIST_FILE."
    echo "[INFO] If you want to reinitialize, please delete the file manually and re-run the script."
    exit 1
fi

# Extract the base IP and the prefix
IFS='/' read -r BASE_IP PREFIX <<< "$SUBNET"

# Initialize the file
echo "[INFO] Initializing IP list in $IP_LIST_FILE"
rm -f $IP_LIST_FILE
touch $IP_LIST_FILE

# ✅ **Write the Subnet Range as the First Line**
echo "$SUBNET" > $IP_LIST_FILE

# Generate Reserved IPs
IFS='.' read -r o1 o2 o3 o4 <<< "$BASE_IP"

# First IP
echo "$o1.$o2.$o3.$o4,RESERVED" >> $IP_LIST_FILE
# Second IP
echo "$o1.$o2.$o3.$((o4 + 1)),RESERVED" >> $IP_LIST_FILE

# Calculate the last IP in the subnet correctly
python3 -c "
import ipaddress
net = ipaddress.IPv4Network('$SUBNET')
print(f'{net[-1]},RESERVED')
" >> $IP_LIST_FILE

echo "[INFO] IP list initialization complete."
