#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "This script requires root, please run it with sudo"
  exit 1
fi

echo "[1/10] Update & upgrade"
apt update
NEEDRESTART_SUSPEND=1 apt upgrade -y

echo "[2/10] Install packages (Proxmox)"
# open-vm-tools is for VMware; Proxmox benefits from qemu-guest-agent
apt install -y net-tools qemu-guest-agent

# Start it (works even if enable isn't supported in some images)
systemctl start qemu-guest-agent || true

# Enable it if possible; ignore the "no installation config" warning
systemctl enable qemu-guest-agent 2>/dev/null || true

# Confirm status (optional)
systemctl status qemu-guest-agent --no-pager || true

echo "[3/10] Stop rsyslog (optional - keep if you want)"
service rsyslog stop || true

echo "[4/10] Clear logs"
truncate -s0 /var/log/wtmp 2>/dev/null || true
truncate -s0 /var/log/lastlog 2>/dev/null || true
truncate -s0 /var/log/audit/audit.log 2>/dev/null || true

echo "[5/10] Remove persistent udev net rules"
rm -f /etc/udev/rules.d/70-persistent-net.rules || true

echo "[6/10] Cleanup temp directories"
rm -rf /tmp/* /var/tmp/* || true

echo "[7/10] Remove SSH host keys and regenerate on first boot (systemd)"
rm -f /etc/ssh/ssh_host_* || true

cat > /etc/systemd/system/regenerate-ssh-host-keys.service <<'EOF'
[Unit]
Description=Regenerate SSH host keys if missing
Before=ssh.service
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable regenerate-ssh-host-keys.service

echo "[8/10] MOTD"
cat > /etc/motd <<'EOF'
###################################### WARNING!!! ###############################################
          This template is created and maintained by the prepare-template-proxmox.sh script.
                 Please run ./prepare-template-proxmox.sh to perform updates!!
#################################################################################################
EOF

echo "[9/10] Cloud-init & netplan template-safety"

# 9a) Ensure cloud-init is allowed to manage network
rm -f /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg || true

# 9b) Allow cloud-init to set hostname per-VM (templates should NOT preserve hostname)
# If the line exists, replace it; if not, append.
if grep -qE '^preserve_hostname:' /etc/cloud/cloud.cfg; then
  sed -i 's/^preserve_hostname:.*/preserve_hostname: false/' /etc/cloud/cloud.cfg
else
  echo 'preserve_hostname: false' >> /etc/cloud/cloud.cfg
fi

# Clear hostname so clones don't inherit a name
: > /etc/hostname
hostnamectl set-hostname localhost || true

# 9c) Netplan: remove MAC-binding pitfalls / ensure safe permissions
# If you have a known-good netplan file, keep it; but ensure perms are strict.
# Netplan warns/errors if configs are group/world readable.
if ls /etc/netplan/*.yaml >/dev/null 2>&1; then
  chmod 600 /etc/netplan/*.yaml || true
fi

# Optional: If you *really* want DHCP identifier mac and the file exists
if [ -f /etc/netplan/50-cloud-init.yaml ]; then
  # Only add dhcp-identifier when dhcp4: true exists
  if grep -q 'dhcp4: true' /etc/netplan/50-cloud-init.yaml; then
    # Add/replace dhcp-identifier: mac under the interface stanza (best-effort)
    if grep -q 'dhcp-identifier:' /etc/netplan/50-cloud-init.yaml; then
      sed -i 's/^\(\s*\)dhcp-identifier:.*/\1dhcp-identifier: mac/' /etc/netplan/50-cloud-init.yaml
    else
      sed -i '/dhcp4: true/a\ \ \ \ \ \ dhcp-identifier: mac' /etc/netplan/50-cloud-init.yaml
    fi
  fi
fi

# Shorten wait-online so template boots don't hang forever when network is slow/missing
mkdir -p /etc/systemd/system/systemd-networkd-wait-online.service.d
cat > /etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/lib/systemd/systemd-networkd-wait-online --timeout=5 --any
EOF
systemctl daemon-reload

# Clean any runtime lease info (systemd stores these under /run)
rm -rf /run/systemd/netif/leases/* 2>/dev/null || true

# Clean cloud-init cache/logs so clones get fresh instance data
cloud-init clean --logs || true

echo "[10/10] Reset machine-id + apt clean + download script copy (optional)"

# Reset machine-id so clones get unique IDs
truncate -s 0 /etc/machine-id || true
rm -f /var/lib/dbus/machine-id || true
ln -sf /etc/machine-id /var/lib/dbus/machine-id || true

apt clean

wget -q https://raw.githubusercontent.com/Qonnect-IT/Ubuntu-Template-Tools/master/prepare-template-proxmox.sh -O /root/prepare-template.sh || true
chmod +x /root/prepare-template.sh || true

cat /dev/null > /root/.bash_history || true
history -c || true

echo "Done. Powering off."
shutdown -h now
