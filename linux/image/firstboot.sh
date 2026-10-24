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
systemctl try-reload-or-restart ssh.service || log "ssh reload failed, continuing"

log "network"
# Merges with Armbian's 10-dhcp-all-interfaces.yaml (same ethernet id) and
# adds route metrics: Ethernet wins whenever it has a lease, Wi-Fi is fallback.
# Both optional, so wait-online doesn't stall on whichever link is absent.
netcfg() { # [wifi]
  local ssid
  ssid=$(get WIFI_SSID)
  echo "network:"
  echo "  version: 2"
  echo "  renderer: networkd"
  echo "  ethernets:"
  echo "    all-eth-interfaces:"
  echo "      match:"
  echo "        name: \"e*\""
  echo "      optional: true"
  echo "      dhcp4: true"
  echo "      dhcp6: true"
  echo "      dhcp4-overrides: {route-metric: 100}"
  echo "      dhcp6-overrides: {route-metric: 100}"
  if [ "${1:-}" = wifi ] && [ -n "$ssid" ]; then
    echo "  wifis:"
    echo "    wlan0:"
    echo "      optional: true"
    echo "      regulatory-domain: $(yq "$(get WIFI_COUNTRY | grep . || echo HK)")"
    echo "      dhcp4: true"
    echo "      dhcp6: true"
    echo "      dhcp4-overrides: {route-metric: 600}"
    echo "      dhcp6-overrides: {route-metric: 600}"
    echo "      access-points:"
    echo "        $(yq "$ssid"):"
    echo "          password: $(yq "$(get WIFI_PASSWORD)")"
  fi
}
net=/etc/netplan/20-printer-proxy.yaml
applied=/var/lib/printer-proxy/netplan.applied # last config netplan apply took
put() { netcfg "$@" >"$net.tmp" && chmod 600 "$net.tmp" && mv "$net.tmp" "$net"; }
put wifi
if ! netplan generate; then
  # build-image.sh validates Wi-Fi values; never let them block the install.
  echo "<4>firstboot: netplan rejected the Wi-Fi config, continuing Ethernet-only" >&2
  put
  netplan generate
fi
# Apply only on change: each retry would otherwise bounce the links.
if ! cmp -s "$net" "$applied" && [ "${SKIP_NETPLAN_APPLY:-}" != 1 ]; then
  netplan apply
  mkdir -p "${applied%/*}"
  cp -p "$net" "$applied"
fi

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
# Finish a dpkg run cut off by power loss on an earlier attempt. dpkg has no
# lock wait, and armbian-firstrun may be running dpkg-reconfigure meanwhile.
for _ in $(seq 60); do dpkg --configure -a 2>/dev/null && break; sleep 5; done
# Once more with errors shown (a no-op after success), so a persistent failure
# names its cause here rather than only as apt's refusal below.
dpkg --configure -a || echo "<4>firstboot: dpkg --configure -a keeps failing (error above)" >&2
# A dead source (Armbian dropped bookworm builds for this board) makes update
# exit non-zero; install still fails if the lists it needs are missing.
apt-get -o DPkg::Lock::Timeout=300 update || log "apt-get update had errors, trying the install anyway"
apt-get -o DPkg::Lock::Timeout=300 install -y cloudflared unattended-upgrades
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
// A cloudflared upgrade only takes effect once the tunnel restarts. Restart
// only when the binary is newer than the running process: this hook runs after
// every dpkg call, and restarting each time drops the tunnel on every upgrade.
DPkg::Post-Invoke { "[ /usr/bin/cloudflared -nt /proc/$(systemctl show -p MainPID --value cloudflared-tunnel.service) ] && systemctl try-restart cloudflared-tunnel.service >/dev/null 2>&1 || true"; };
EOF

log "installing printer-proxy (channel $(get CHANNEL))"
# Not via printer-proxy-update.service: that unit is sandboxed for nightly
# runs. update.sh reads CHANNEL itself and, with nothing installed, installs.
bash "$here/update.sh"

mkdir -p "${DONE%/*}"
# SD cards lose power often: everything above must be on disk before the
# marker that stops reruns.
sync
touch "$DONE"
log "done"
