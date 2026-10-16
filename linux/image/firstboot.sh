#!/usr/bin/env bash
# First boot of a provisioned Armbian image (printer-proxy-firstboot.service).
# Baked by build-image.sh into /usr/local/lib/printer-proxy/ with update.sh.
#
# Every step is idempotent: a failed run is retried by the unit, and the next
# attempt redoes everything. $DONE is written only after the last step, so
# the unit's ConditionPathExists stops it running again.
#
# Test overrides: SKIP_NETPLAN_APPLY=1, plus update.sh's REPO_API,
# DOWNLOAD_BASE, HEALTH_URL, HEALTH_TIMEOUT (inherited from the environment).
set -euo pipefail

ENV_FILE=/etc/printer-proxy/env
DONE=/var/lib/printer-proxy/firstboot.done
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

log() { echo "firstboot: $*"; }
# Literal value of the last KEY= line (EnvironmentFile format, no quoting).
get() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -n1; }
# YAML single-quoted scalar: only ' needs escaping (as '').
yq() { printf "'%s'" "${1//\'/\'\'}"; }

[ -f "$ENV_FILE" ] || { echo "firstboot: $ENV_FILE missing" >&2; exit 1; }

log "hostname, timezone"
host=$(get DEVICE_HOSTNAME); host=${host:-printer-proxy}
# Rewritten in place, not replaced (hostnamectl, sed -i): the test container
# bind-mounts both files.
echo "$host" >/etc/hostname
hostname "$host"
hosts=$(grep -v '^127\.0\.1\.1[[:space:]]' /etc/hosts || true)
printf '%s\n127.0.1.1 %s\n' "$hosts" "$host" >/etc/hosts
# Not timedatectl: it needs D-Bus, which may not be up yet. PID 1 watches
# /etc/localtime and reschedules calendar timers itself.
ln -sfn /usr/share/zoneinfo/Asia/Hong_Kong /etc/localtime
echo Asia/Hong_Kong >/etc/timezone

log "user kube, ssh, root lock"
id kube >/dev/null 2>&1 || useradd -m -s /bin/bash kube
usermod -L kube # key-only: no usable password
install -d -m 700 -o kube -g kube /home/kube/.ssh
get SSH_AUTHORIZED_KEYS >/home/kube/.ssh/authorized_keys
chown kube:kube /home/kube/.ssh/authorized_keys
chmod 600 /home/kube/.ssh/authorized_keys
echo 'kube ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/90-kube.tmp
chmod 440 /etc/sudoers.d/90-kube.tmp
visudo -cqf /etc/sudoers.d/90-kube.tmp
mv /etc/sudoers.d/90-kube.tmp /etc/sudoers.d/90-kube
passwd -l root >/dev/null
# The sshd drop-in (key-only, no root) is baked into the image; reload in case
# sshd started before this unit.
systemctl try-reload-or-restart ssh.service

log "network"
# Merges with Armbian's 10-dhcp-all-interfaces.yaml (same ethernet id) and
# adds route metrics: Ethernet wins whenever it has a lease, Wi-Fi is fallback.
ssid=$(get WIFI_SSID)
country=$(get WIFI_COUNTRY)
{
  echo "network:"
  echo "  version: 2"
  echo "  renderer: networkd"
  echo "  ethernets:"
  echo "    all-eth-interfaces:"
  echo "      match:"
  echo "        name: \"e*\""
  echo "      dhcp4: true"
  echo "      dhcp6: true"
  echo "      dhcp4-overrides: {route-metric: 100}"
  echo "      dhcp6-overrides: {route-metric: 100}"
  if [ -n "$ssid" ]; then
    echo "  wifis:"
    echo "    wlan0:"
    echo "      optional: true"
    echo "      regulatory-domain: $(yq "${country:-HK}")"
    echo "      dhcp4: true"
    echo "      dhcp6: true"
    echo "      dhcp4-overrides: {route-metric: 600}"
    echo "      dhcp6-overrides: {route-metric: 600}"
    echo "      access-points:"
    echo "        $(yq "$ssid"):"
    echo "          password: $(yq "$(get WIFI_PASSWORD)")"
  fi
} >/etc/netplan/20-printer-proxy.yaml.tmp
chmod 600 /etc/netplan/20-printer-proxy.yaml.tmp
mv /etc/netplan/20-printer-proxy.yaml.tmp /etc/netplan/20-printer-proxy.yaml
netplan generate
if [ "${SKIP_NETPLAN_APPLY:-}" != 1 ]; then netplan apply; fi

log "waiting for internet"
# Also waits out the clock: there is no RTC, so TLS fails until NTP syncs.
deadline=$((SECONDS + 600))
until curl -fsS --max-time 10 -o /dev/null https://pkg.cloudflare.com/cloudflared/dists/any/Release; do
  [ $SECONDS -lt $deadline ] || { echo "firstboot: no internet after 10 minutes" >&2; exit 1; }
  sleep 5
done

log "cloudflared apt repo, unattended-upgrades"
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg.tmp
mv /usr/share/keyrings/cloudflare-main.gpg.tmp /usr/share/keyrings/cloudflare-main.gpg
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
  >/etc/apt/sources.list.d/cloudflared.list
export DEBIAN_FRONTEND=noninteractive
dpkg --configure -a # finish a dpkg run cut off by power loss on an earlier attempt
apt-get update
apt-get install -y cloudflared unattended-upgrades
# Sorts after Armbian's 02-armbian-periodic and Debian's 50unattended-upgrades:
# the later scalar wins, and #clear drops their origin lists (which include
# Armbian's kernel/BSP packages and Debian point releases).
cat >/etc/apt/apt.conf.d/52printer-proxy <<'EOF'
// printer-proxy: daily security updates, Debian security + cloudflared only.
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
        "origin=cloudflared,codename=any";
};
// A cloudflared upgrade only takes effect once the tunnel restarts.
DPkg::Post-Invoke { "systemctl try-restart cloudflared-tunnel.service >/dev/null 2>&1 || true"; };
EOF

log "installing printer-proxy (channel $(get CHANNEL))"
# Not via printer-proxy-update.service: that unit is sandboxed for nightly
# runs. update.sh reads CHANNEL itself and, with nothing installed, installs.
bash "$here/update.sh"

mkdir -p "${DONE%/*}"
touch "$DONE"
log "done"
