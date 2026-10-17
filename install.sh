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

if ! getent passwd oracle-free >/dev/null 2>&1; then
  useradd --system --user-group --home-dir "$STATE" --shell /usr/sbin/nologin oracle-free
fi

validate_service_account() {
  local service_home="${1:-$STATE}" login_defs="${2:-/etc/login.defs}"
  local passwd_entry group_entry uid primary_gid home login_shell group_name group_gid account_group_ids uid_range uid_min uid_max primary_group_found
  passwd_entry=$(getent passwd oracle-free) || {
    echo "Cannot resolve the oracle-free service account." >&2
    exit 1
  }
  IFS=: read -r _ _ uid primary_gid _ home login_shell <<< "$passwd_entry"
  [[ "$uid" =~ ^[0-9]+$ && "$uid" -gt 0 ]] || {
    echo "Unsafe oracle-free UID; expected a non-root system account." >&2
    exit 1
  }
  uid_range=$(awk '$1 == "SYS_UID_MIN" { min=$2 } $1 == "SYS_UID_MAX" { max=$2 } END { if (min ~ /^[0-9]+$/ && max ~ /^[0-9]+$/) print min, max }' "$login_defs")
  read -r uid_min uid_max <<< "$uid_range"
  [[ "$uid_min" =~ ^[0-9]+$ && "$uid_max" =~ ^[0-9]+$ ]] && (( uid >= uid_min && uid <= uid_max )) || {
    echo "Unsafe oracle-free UID; it must be within the system UID range in $login_defs." >&2
    exit 1
  }
  group_entry=$(getent group oracle-free) || {
    echo "The oracle-free primary group does not exist." >&2
    exit 1
  }
  IFS=: read -r group_name _ group_gid _ <<< "$group_entry"
  [[ "$group_name" == oracle-free && "$group_gid" =~ ^[0-9]+$ && "$primary_gid" == "$group_gid" ]] || {
    echo "Unsafe oracle-free primary group; expected the oracle-free group." >&2
    exit 1
  }
  [[ "$home" == "$service_home" && "$login_shell" == /usr/sbin/nologin ]] || {
    echo "Unsafe oracle-free home directory or login shell; expected $service_home and /usr/sbin/nologin." >&2
    exit 1
  }
  account_group_ids=$(id -G oracle-free) || {
    echo "Cannot inspect oracle-free supplementary groups." >&2
    exit 1
  }
  [[ -n "$account_group_ids" ]] || {
    echo "Cannot verify oracle-free group membership." >&2
    exit 1
  }
  primary_group_found=0
  for group_gid in $account_group_ids; do
    if [[ "$group_gid" == "$primary_gid" ]]; then
      primary_group_found=1
    else
      echo "Unsafe oracle-free supplementary group membership detected." >&2
      exit 1
    fi
  done
  (( primary_group_found == 1 )) || {
    echo "Cannot verify oracle-free primary group membership." >&2
    exit 1
  }
}

validate_service_account "$STATE" /etc/login.defs

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
