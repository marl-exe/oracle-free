#!/usr/bin/env bash
# Uninstall managed service and program; retain credentials and state intentionally.
set -Eeuo pipefail
[[ "$(id -u)" -eq 0 ]] || { echo "Run as root: sudo bash uninstall.sh" >&2; exit 1; }

DEST=/opt/oracle-free
UNIT=/etc/systemd/system/oracle-free.service
if [[ ! -f "$DEST/.managed-by-oracle-free" ]]; then
  echo "Managed installation marker not found. Refusing to remove unrelated files." >&2
  exit 1
fi

systemctl disable --now oracle-free.service || true
rm -f -- "$UNIT"
systemctl daemon-reload
rm -rf -- "$DEST"

echo "Removed managed service and program."
echo "Preserved /etc/oracle-free/config and /var/lib/oracle-free/ (keys, logs, state)."
echo "Delete those manually only if you are certain they are no longer needed."
