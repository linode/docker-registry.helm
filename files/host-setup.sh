#!/usr/bin/env sh

set -xeu

CONFIG_FILE="/host/etc/containerd/config.toml"
BACKUP_FILE="/host/etc/containerd/config.toml.backup.$(date +%Y%m%d-%H%M%S)"
CONFIG_PATH="/etc/containerd/certs.d"

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: $CONFIG_FILE not found"
    exit 1
fi

# Create backup
echo "Creating backup: $BACKUP_FILE"
cp "$CONFIG_FILE" "$BACKUP_FILE"

restart_needed=1
if grep -q "config_path.*=.*\"$CONFIG_PATH\"" "$CONFIG_FILE"; then
  restart_needed=0
  echo "config_path is already set correctly in $CONFIG_FILE"
elif grep -q '^\[plugins\."io\.containerd\.grpc\.v1\.cri"\.registry\]' "$CONFIG_FILE"; then
    echo "Registry section found, checking for config_path..."

    # Check if config_path exists but with wrong value
    if grep -q "config_path.*=" "$CONFIG_FILE"; then
        echo "Updating existing config_path..."
        sed -i "s|config_path.*=.*|config_path = \"$CONFIG_PATH\"|" "$CONFIG_FILE"
    else
        echo "Adding config_path to existing registry section..."
        # Add config_path after the registry section line
        sed -i '/^\[plugins\."io\.containerd\.grpc\.v1\.cri"\.registry\]/a\  config_path = "'"$CONFIG_PATH"'"' "$CONFIG_FILE"
    fi
else
    echo "Registry section not found, adding complete section..."
    # Add the entire registry section at the end
    cat >> "$CONFIG_FILE" << EOF

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "$CONFIG_PATH"
EOF
fi

if [ "$restart_needed" -eq 1 ]; then
  echo "Containerd configuration changed, restart may be required."
else
  echo "No changes made to containerd configuration, restart not needed."
fi

echo "Configuration updated successfully!"

# Show the relevant section
echo ""
echo "Current registry configuration:"
grep -A 5 '^\[plugins\."io\.containerd\.grpc\.v1\.cri"\.registry\]' "$CONFIG_FILE" || echo "Section not found in output"

# Verify required environment variables
if [ -z "$NAMESPACE" ]; then
  echo "ERROR: NAMESPACE environment variable is not set or empty"
  exit 1
fi

if [ -z "$SERVICE_NAME" ]; then
  echo "ERROR: SERVICE_NAME environment variable is not set or empty"
  exit 1
fi

if [ -z "$SERVICE_PORT" ]; then
  echo "ERROR: SERVICE_PORT environment variable is not set or empty"
  exit 1
fi

echo "Using NAMESPACE=$NAMESPACE, SERVICE_NAME=$SERVICE_NAME, SERVICE_PORT=$SERVICE_PORT"

# Extract cluster domain from pod resolv.conf
cluster_domain="cluster.local"
if search_line=$(grep -E "^search|^domain" /etc/resolv.conf | head -1); then
  if echo "$search_line" | grep -q "${NAMESPACE}.svc"; then
    cluster_domain=$(echo "$search_line" | grep -o "${NAMESPACE}.svc.[^ ]*" | sed "s/${NAMESPACE}.svc.//")
  fi
fi
echo "Detected cluster domain: ${cluster_domain}"

prefixes="${SERVICE_NAME} ${SERVICE_NAME}.${NAMESPACE} ${SERVICE_NAME}.${NAMESPACE}.svc ${SERVICE_NAME}.${NAMESPACE}.svc.${cluster_domain}${ADDITIONAL_HOSTS:+ ${ADDITIONAL_HOSTS}}"

hosts_entry="127.0.0.1 ${prefixes}"

# Create a new hosts file without the old entries and with the new entry
grep -v "${SERVICE_NAME}" /host/etc/hosts > /tmp/hosts.new
echo "$hosts_entry" >> /tmp/hosts.new

# Replace the hosts file with the new content
cat /tmp/hosts.new > /host/etc/hosts
rm /tmp/hosts.new

echo "Added/Updated hosts entries for registry service: $hosts_entry"

echo "Configuring containerd to allow insecure registries..."

for prefix in $prefixes; do
  cert_dir="/host/${CONFIG_PATH}/${prefix}:${SERVICE_PORT}"
  echo "Creating directory: ${cert_dir}"
  mkdir -p "${cert_dir}"

  echo "Writing hosts.toml for ${prefix}:${SERVICE_PORT}"
  echo "[host.\"http://${prefix}:${SERVICE_PORT}\"]" > "${cert_dir}/hosts.toml"
  echo "capabilities = [\"pull\", \"resolve\"]" >> "${cert_dir}/hosts.toml"
  echo "plain-http = true" >> "${cert_dir}/hosts.toml"
done

sleep infinity
