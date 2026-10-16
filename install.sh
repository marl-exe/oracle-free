#!/usr/bin/env bash
# One-time installation. Deliberately DOES NOT start or enable the service.
set -Eeuo pipefail
umask 077

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root: sudo bash install.sh" >&2; exit 1; }
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEST=/opt/oracle-free
STATE=/var/lib/oracle-free
CONF_DIR=/etc/oracle-free
UNIT=/etc/systemd/system/oracle-free.service

for file in oracle-free.sh oracle-free.service config.example; do
  [[ -f "$REPO_DIR/$file" ]] || { echo "Missing $file" >&2; exit 1; }
done
bash -n "$REPO_DIR/oracle-free.sh" || exit 1

if [[ -e "$UNIT" ]]; then
  echo "Existing oracle-free.service detected. Installation refused to protect it." >&2
  exit 1
fi

if ! id oracle-free >/dev/null 2>&1; then
  useradd --system --user-group --home-dir "$STATE" --shell /usr/sbin/nologin oracle-free
fi

install -d -o oracle-free -g oracle-free -m 700 "$STATE" "$STATE/.oci" "$STATE/.ssh"
install -d -o root -g root -m 755 "$DEST"
install -d -o root -g oracle-free -m 750 "$CONF_DIR"

# Only install config on a first install; never overwrite user-specific settings.
if [[ ! -e "$CONF_DIR/config" ]]; then
  install -o root -g oracle-free -m 640 "$REPO_DIR/config.example" "$CONF_DIR/config"
  echo "Created $CONF_DIR/config (must be configured before starting)."
else
  echo "Preserving existing $CONF_DIR/config."
fi

# Use a system OCI CLI only when visible to the service account. Otherwise,
# install the official Python OCI CLI into a dedicated, root-owned venv.
OCI_PATH=/opt/oracle-free/venv/bin:/usr/local/bin:/usr/bin:/bin
if ! runuser -u oracle-free -- env PATH="$OCI_PATH" oci --version >/dev/null 2>&1; then
  command -v apt-get >/dev/null 2>&1 || {
    echo "Automatic OCI CLI installation needs apt-get (Ubuntu/Debian)." >&2
    exit 1
  }
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv ca-certificates
  python3 -m venv "$DEST/venv"
  "$DEST/venv/bin/python" -m pip install --disable-pip-version-check --upgrade pip oci-cli
  runuser -u oracle-free -- env PATH="$OCI_PATH" oci --version
fi

install -o root -g root -m 644 "$REPO_DIR/oracle-free.sh" "$DEST/oracle-free.sh"
install -o root -g root -m 644 "$REPO_DIR/oracle-free.service" "$UNIT"
printf '%s\n' 'managed by marl-exe/oracle-free' > "$DEST/.managed-by-oracle-free"
chmod 644 "$DEST/.managed-by-oracle-free"
systemctl daemon-reload
systemd-analyze verify "$UNIT"

echo
echo "Installed successfully; service remains DISABLED and STOPPED."
echo "1. Edit $CONF_DIR/config and put your OWN OCI CLI credentials in $STATE/.oci/."
echo "2. Install your SSH PUBLIC key in $STATE/.ssh/oracle-free-key.pub."
echo "3. Test read-only authentication as oracle-free; see README.md."
echo "4. Only when ready to submit REAL launch requests, run:"
echo "   systemctl enable --now oracle-free.service"
