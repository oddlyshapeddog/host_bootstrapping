#!/bin/sh

CONTAINER_ID="100"
WAIT_TIME=5         # Adjust the wait time between checks (in seconds)
MAX_RETRIES=24      # Adjust the maximum number of retries
USER=user
PUBKEYS_DIR=/vm_bootstrapping/pubkeys
ESSENTIAL_PACKAGES="sudo nano curl git wget zip unzip build-essential rsync openssh-client screen"

MP0_VALUE=/vm_bootstrapping,mp=/vm_bootstrapping
MP1_VALUE=/hive,mp=/hive
MP2_VALUE=/mnt/system2_data/ai_data,mp=/ai_data

check_mp() {
  # params
  MP_ID="$1"
  MP_VALUE="$2"
  echo "Expecting mp$MP_ID to be $MP_VALUE..."

  # get config
  PCT_CONFIG=$(sudo pct config "$CONTAINER_ID")
  MP_RESULT=$(echo "$PCT_CONFIG" | grep -E "^mp$MP_ID:" | cut -d ' ' -f 2-)
  if [ "$MP_RESULT" = "$MP_VALUE" ]; then
    echo "Mount point $MP_ID looks ok"
  else
    echo "Error: Mount point $MP_ID has a different value than expected"
    echo "Expected value: $MP_VALUE"
    echo "Actual value:   $MP_RESULT"

    # prompt for consent
    echo "Override? y/N"
    read OVERRIDE_VALUE

    # normalize
    OVERRIDE_VALUE=$(echo "$OVERRIDE_VALUE" | tr '[:upper:]' '[:lower:]')
    if [ "$OVERRIDE_VALUE" = "y" ]; then
      echo "Setting mount point $MP_ID to $MP_VALUE"
      $(set_mp $MP_ID $MP_VALUE)
    else
      exit 1
    fi
  fi
}

set_mp() {
  # params
  MP_ID="$1"
  MP_VALUE="$2"

  CMD="sudo pct set $CONTAINER_ID -mp$MP_ID $MP_VALUE"
  eval "$CMD"
}

show_title() {
  # params
  TITLE=$(echo "$1" | tr '[:lower:]' '[:upper:]')

  echo " "
  echo "================================"
  echo "  $TITLE"
  echo "================================"
  echo " "
}

if [ -n "$1" ]; then
  CONTAINER_ID="$1"
else
  echo "Enter the container ID (e.g. 101):"
  read -r CONTAINER_ID
fi
echo "Preparing container $CONTAINER_ID..."

# get container properties
PCT_CONFIG=$(sudo pct config "$CONTAINER_ID")

# add default mount points if not already added
show_title "Mount point checks"
echo "Ensuring default mount points are set..."
if [ -n "$PCT_CONFIG" ]; then
  check_mp 0 "$MP0_VALUE"
  check_mp 1 "$MP1_VALUE"
  check_mp 2 "$MP2_VALUE"
else
  echo "Erro: Failed to retrieve container configuration for $CONTAINER_ID."
  exit 1
fi

# Start the container if not started
show_title "Container startup checks"
echo "Starting the container..."
STATUS=$(sudo pct status "$CONTAINER_ID" 2>/dev/null | awk '{print $2}')
if [ "$STATUS" = "running" ]; then
  echo "Container $CONTAINER_ID is already running."
else
  # Start the container
  sudo pct start "$CONTAINER_ID"
fi

# Wait for the container to boot and check network connectivity
echo "Waiting for network connectivity..."
SUCCESS=0
retries=0
while [ $retries -lt $MAX_RETRIES ]; do
  # Check if the container is running and has an IP address
  if [ "$(sudo pct status "$CONTAINER_ID" | awk '{print $2}')" = "running" ] &&
     [ -n "$(sudo pct exec "$CONTAINER_ID" -- ip -4 -o addr show | awk '{print $4}')" ]; then
    echo "Container $CONTAINER_ID has booted and is connected to the network."
    SUCCESS=1
    break
  fi

  # Wait before checking again
  sleep $WAIT_TIME
  retries=$((retries + 1))
done
if [ "$SUCCESS" = "0" ]; then
  echo "Timed out while waiting for the container to acquire an IP address"
  exit 1
fi

# check container connectivity
show_title "Connectivity tests"
echo "Retrieving container IP..."
CONTAINER_IP=$(sudo pct exec "$CONTAINER_ID" -- ip -4 addr show scope global | awk '/inet / {print $2}' | awk -F '/' '{print $1}')
if [ -n "$CONTAINER_IP" ]; then
  echo "Container IP: $CONTAINER_IP"
  echo " "
  echo "Manual setup steps:"
  echo "  1. Go to your router settings: http://192.168.1.1"
  echo "  2. Create a permanent DHCP lease for this IP"
  echo "  3. Create a hostname for this container"
  echo " "
  echo "Continue? [Y/n]"
  read KEY
else
  echo "Error: The container has no local IP."
  exit 1
fi

# install deps
show_title "Essential packages"
sudo pct exec "$CONTAINER_ID" -- apt update -y
if [ $? -eq 0 ]; then
  echo "apt cache updated successfully."
  sudo pct exec "$CONTAINER_ID" -- apt install -y $ESSENTIAL_PACKAGES
else
  echo "Error: Unable to update the apt cache"
  exit 1
fi

# provision pubkeys
show_title "Users & access"
echo "Checking for a non-root user account..."
RESULT=$(sudo pct exec "$CONTAINER_ID" -- id $USER)
if [ $? -eq 0 ]; then
  echo "User '$USER' found."
else
  echo "User '$USER' does not exist. Creating..."

  sudo pct exec "$CONTAINER_ID" -- useradd -G sudo $USER
fi

echo "Enabling passwordless SSH..."
RESULT=$(sudo pct exec "$CONTAINER_ID" --  grep -q "^%sudo\s*ALL=(ALL:ALL)\s*NOPASSWD:" "/etc/sudoers")
if [ $? -eq 0 ]; then
  echo "Passwordless sudo is already enabled for the sudo group."  echo "Passwordless sudo is already enabled for the sudo group."
else
  sudo pct exec "$CONTAINER_ID" -- bash -c "echo '%sudo ALL=(ALL:ALL) NOPASSWD:ALL' | sudo tee -a /etc/sudoers >/dev/null"
fi

echo "Checking authorized public keys..."
AUTHORIZED_KEYS_FILE="/home/$USER/.ssh/authorized_keys"
sudo pct exec "$CONTAINER_ID" -- mkdir -p "/home/$USER/.ssh"
sudo pct exec "$CONTAINER_ID" -- touch "$AUTHORIZED_KEYS_FILE"
for PUBKEY_FILE in "$PUBKEYS_DIR"/*; do
  # Read the content of the public key file
  PUBKEY=$(cat "$PUBKEY_FILE")

  # Check if the public key is present in the authorized_keys file
  sudo pct exec "$CONTAINER_ID" -- grep -q "$PUBKEY" "$AUTHORIZED_KEYS_FILE"
  if [ $? -eq 0 ]; then
    echo "Public key $PUBKEY_FILE found in authorized_keys"
  else
    echo "Public key in $PUBKEY_FILE is missing from authorized_keys. Adding..."
    sudo pct exec "$CONTAINER_ID" -- bash -c "echo '$PUBKEY' >> '$AUTHORIZED_KEYS_FILE'"
  fi
done

echo "Fixing home directory permissions"
sudo pct exec "$CONTAINER_ID" -- chown -R $USER /home/$USER
sudo pct exec "$CONTAINER_ID" -- chgrp -R $USER /home/$USER
sudo pct exec "$CONTAINER_ID" -- chmod 700 /home/$USER
sudo pct exec "$CONTAINER_ID" -- chmod 700 /home/$USER/.ssh
sudo pct exec "$CONTAINER_ID" -- bash -c "chmod 600 /home/$USER/.ssh/*"
echo "Permissions fixed for user $USER"
