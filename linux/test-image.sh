#!/usr/bin/env bash
# Verify build-image.sh (needs Docker; the boot test needs an arm64 host, e.g.
# an Apple Silicon Mac, plus internet for Cloudflare's apt repo).
#
#   linux/test-image.sh                    build an image from a dummy env, check
#                                          it, then boot its rootfs and run first boot
#   linux/test-image.sh --check <img> <env>  only check a built image (any site)
#
# IMAGE=<armbian .img.xz> uses a local Armbian image instead of the cached
# download; KEEP=1 leaves the test container running for debugging.
#
# Check: mounts the image read-only and asserts the env file, units, scripts and
# wizard skip are present with the right owners and modes.
# Boot: runs the image's root filesystem as a container with systemd as PID 1.
# The release API and bundle (linux/package.sh) are served locally; the server
# starts only after first boot has failed once, so a mid-way retry is tested.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

# -- inside the check container: /img/<name>, /in/site.env
if [ "${1:-}" = --check-in-container ]; then
  apt-get -qq update >/dev/null && apt-get -qq install -y fdisk >/dev/null
  start=$(sfdisk -J "/img/$2" | grep -o '"start": *[0-9]*' | head -n1 | grep -o '[0-9]*$')
  m=/mnt/root
  mkdir -p "$m"
  mount -o loop,ro,offset=$((start * 512)) "/img/$2" "$m"
  trap 'umount "$m"' EXIT
  # is <path> <owner:group> <octal mode>
  is() { [ "$(stat -c '%U:%G %a' "$m$1")" = "$2 $3" ] || fail "$1 is $(stat -c '%U:%G %a' "$m$1" 2>&1), want $2 $3"; }
  is /etc/printer-proxy root:root 755
  is /etc/printer-proxy/env root:root 600
  cmp -s "$m/etc/printer-proxy/env" /in/site.env || fail "env file differs from the site env"
  pass env-file
  is /usr/local/lib/printer-proxy/firstboot.sh root:root 755
  is /usr/local/lib/printer-proxy/update.sh root:root 755
  bash -n "$m/usr/local/lib/printer-proxy/firstboot.sh" && bash -n "$m/usr/local/lib/printer-proxy/update.sh"
  pass scripts
  is /etc/systemd/system/printer-proxy-firstboot.service root:root 644
  [ "$(readlink "$m/etc/systemd/system/multi-user.target.wants/printer-proxy-firstboot.service")" = \
    /etc/systemd/system/printer-proxy-firstboot.service ] || fail "first-boot unit not enabled"
  pass firstboot-unit
  is /etc/ssh/sshd_config.d/10-printer-proxy.conf root:root 644
  grep -qx 'PermitRootLogin no' "$m/etc/ssh/sshd_config.d/10-printer-proxy.conf" || fail "sshd drop-in"
  pass sshd-dropin
  [ ! -e "$m/root/.not_logged_in_yet" ] || fail "/root/.not_logged_in_yet still there"
  ! grep -rqs -- --autologin "$m/etc/systemd/system" || fail "root autologin override still there"
  pass wizard-skipped
  is /etc/shadow root:shadow 640
  grep -q '^root:!' "$m/etc/shadow" || fail "root password not locked"
  pass root-locked
  exit 0
fi

# check <img> <env>
check() {
  local img dir
  img=$(basename "$1"); dir=$(cd "$(dirname "$1")" && pwd -P)
  docker run --rm --privileged -v "$here:/linux:ro" -v "$dir:/img:ro" \
    -v "$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2"):/in/site.env:ro" \
    debian:bookworm /linux/test-image.sh --check-in-container "$img"
}

if [ "${1:-}" = --check ]; then
  check "${2:?usage: test-image.sh --check <img> <env>}" "${3:?usage: test-image.sh --check <img> <env>}"
  exit 0
fi

t=$(mktemp -d)
ctr=printer-proxy-image-test
rootfs=printer-proxy-image-test:rootfs
cleanup() {
  [ -z "${KEEP:-}" ] || { echo "KEEP: container $ctr and $t left behind"; return; }
  docker rm -f "$ctr" >/dev/null 2>&1 || true
  docker rmi "$rootfs" >/dev/null 2>&1 || true
  rm -rf "$t"
}
trap cleanup EXIT

echo "== build an image from a dummy env (dummy values only)"
# No release has the bundle in these tests; the release check is tested below.
export ALLOW_NO_RELEASE=1
# A throwaway key: build-image.sh checks it with ssh-keygen.
ssh-keygen -q -t ed25519 -N '' -C test@example -f "$t/key"
# Quote and space in the Wi-Fi values exercise the netplan YAML quoting.
cat >"$t/test.env" <<EOF
TUNNEL_TOKEN=dummy-tunnel-token
API_KEY=dummy-api-key
WIFI_SSID=Kube's Wi-Fi
WIFI_PASSWORD=dummy pass'word#1
WIFI_COUNTRY=HK
CHANNEL=stable
SSH_AUTHORIZED_KEYS=$(cat "$t/key.pub")
DEVICE_HOSTNAME=printer-proxy-test
EOF
OUT=$t/test.img "$here/build-image.sh" "$t/test.env" ${IMAGE:+"$IMAGE"}

echo "== env files systemd or firstboot.sh would misread are rejected"
# rejects <name> <awk program applied to the good env> (awk: BSD sed lacks \r, \n)
rejects() {
  awk "$2" "$t/test.env" >"$t/bad.env"
  if "$here/build-image.sh" "$t/bad.env" /nonexistent >/dev/null 2>&1; then fail "env-rejects-$1"; fi
}
# shellcheck disable=SC2016 # awk programs, not shell
{
  rejects crlf '{ print $0 "\r" }'
  rejects quoted '/^API_KEY=/ { $0 = "API_KEY=\"dummy\"" } 1'
  rejects missing-key '!/^TUNNEL_TOKEN=/'
  rejects bad-channel '/^CHANNEL=/ { $0 = "CHANNEL=beta" } 1'
  rejects duplicate '1; END { print "API_KEY=dummy2" }'
  rejects no-final-newline '{ printf "%s%s", sep, $0; sep = "\n" }'
  rejects mangled-key '/^SSH_AUTHORIZED_KEYS=/ { $0 = substr($0, 1, 60) } 1'
  rejects short-wifi-password '/^WIFI_PASSWORD=/ { $0 = "WIFI_PASSWORD=short" } 1'
  rejects ssid-without-password '/^WIFI_PASSWORD=/ { $0 = "WIFI_PASSWORD=" } 1'
  rejects long-ssid '/^WIFI_SSID=/ { $0 = "WIFI_SSID=123456789012345678901234567890123" } 1'
  rejects bad-country '/^WIFI_COUNTRY=/ { $0 = "WIFI_COUNTRY=hk" } 1'
}
pass env-validation

echo "== refuses when the channel's release has no bundle"
# builds <name> <release JSON>: exit status of build-image.sh up to the image step
builds() {
  mkdir -p "$t/api/releases"
  printf '%s\n' "$2" >"$t/api/releases/latest"
  ALLOW_NO_RELEASE='' REPO_API=file://$t/api "$here/build-image.sh" "$t/test.env" /nonexistent >"$t/out" 2>&1 || true
  grep -q "$1" "$t/out" || { sed 's/^/    | /' "$t/out"; fail "release-check: want '$1'"; }
}
builds 'has no printer-proxy-linux-arm64.tar.gz' '{"tag_name":"v0.2.4","assets":[{"name":"printer-proxy.exe"}]}'
builds 'no such image' '{"tag_name":"v0.3.0","assets":[{"name":"printer-proxy-linux-arm64.tar.gz"}]}'
pass release-check

echo "== refuses a wrong image"
if EXPECTED_CODENAME=trixie OUT=$t/wrong.img "$here/build-image.sh" "$t/test.env" ${IMAGE:+"$IMAGE"} >"$t/out" 2>&1 ||
  ! grep -q 'not Debian trixie' "$t/out" || compgen -G "$t/wrong.img*" >/dev/null; then
  sed 's/^/    | /' "$t/out"; fail wrong-image
fi
pass wrong-image

echo "== check the image"
check "$t/test.img" "$t/test.env"

echo "== boot the image's rootfs with systemd, run first boot"
tag=v0.0.0-imagetest
"$here/package.sh" "$tag" "$t/www/dl/$tag" >/dev/null
mkdir -p "$t/www/api/releases"
printf '{"tag_name":"%s","prerelease":false}\n' "$tag" >"$t/www/api/releases/latest"

# Test-only units: point the updater at the local server, leave the container's
# network to Docker (netplan generate still runs), skip hardware services.
o=$t/overlay/etc/systemd/system
mkdir -p "$o/printer-proxy-firstboot.service.d"
cat >"$o/printer-proxy-firstboot.service.d/test.conf" <<'EOF'
[Service]
Environment=SKIP_NETPLAN_APPLY=1 REPO_API=http://127.0.0.1:8000/api DOWNLOAD_BASE=http://127.0.0.1:8000/dl
RestartSec=5
EOF
cat >"$o/test-release-server.service" <<'EOF'
[Service]
ExecStart=/usr/bin/python3 -m http.server -d /srv/www -b 127.0.0.1 8000
EOF
for u in systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service \
  armbian-resize-filesystem.service armbian-ramlog.service armbian-zram-config.service; do
  ln -s /dev/null "$o/$u"
done

docker run --rm --privileged -v "$t:/t:ro" debian:bookworm bash -c '
  set -e; apt-get -qq update >/dev/null && apt-get -qq install -y fdisk >/dev/null
  start=$(sfdisk -J /t/test.img | grep -o "\"start\": *[0-9]*" | head -n1 | grep -o "[0-9]*$")
  mkdir /m && mount -o loop,ro,offset=$((start * 512)) /t/test.img /m
  tar -C /m -c . && umount /m' | docker import - "$rootfs" >/dev/null
docker create --name "$ctr" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v "$t/www:/srv/www:ro" "$rootfs" /sbin/init >/dev/null
docker cp "$t/overlay/." "$ctr:/" >/dev/null
docker start "$ctr" >/dev/null

x() { docker exec "$ctr" "$@"; }
journal() { x journalctl -o cat -u printer-proxy-firstboot; }
wait_for() { # <seconds> <what> <command...>
  local s=$1 what=$2; shift 2
  for _ in $(seq "$s"); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done
  journal | tail -n 40 | sed 's/^/    | /'
  fail "$what"
}

wait_for 600 "first boot fails at the bundle step (no release server yet)" \
  sh -c "docker exec $ctr journalctl -u printer-proxy-firstboot | grep -q 'no usable release tag'"
pass firstboot-failed-midway
x systemctl start test-release-server
wait_for 300 "first boot retries and completes" x test -f /var/lib/printer-proxy/firstboot.done
journal | sed 's/^/    | /' | tail -n 15
pass firstboot-done

[ "$(x hostname)" = printer-proxy-test ] || fail hostname
x readlink /etc/localtime | grep -q 'Asia/Hong_Kong$' || fail timezone
# 03:00 HKT is 19:00 UTC.
x systemctl show -P NextElapseUSecRealtime printer-proxy-update.timer | grep -q ' 03:00:00 HKT$' || fail timer-in-hkt
pass hostname-timezone

[ "$(x stat -c '%U %a' /home/kube/.ssh/authorized_keys)" = "kube 600" ] || fail authorized-keys-mode
[ "$(x cat /home/kube/.ssh/authorized_keys)" = "$(cat "$t/key.pub")" ] || fail authorized-keys
x sudo -l -U kube | grep -q 'NOPASSWD: ALL' || fail sudo
[ "$(x passwd -S root | cut -d' ' -f2)" = L ] && [ "$(x passwd -S kube | cut -d' ' -f2)" = L ] || fail passwords-locked
sshd=$(x sshd -T)
for kv in "permitrootlogin no" "passwordauthentication no" "kbdinteractiveauthentication no" "pubkeyauthentication yes"; do
  grep -qx "$kv" <<<"$sshd" || fail "sshd: $kv"
done
pass user-ssh

[ "$(x stat -c '%a' /etc/netplan/20-printer-proxy.yaml)" = 600 ] || fail netplan-mode
x grep -q 'RouteMetric=100' /run/systemd/network/10-netplan-all-eth-interfaces.network || fail eth-metric
x grep -q 'RequiredForOnline=no' /run/systemd/network/10-netplan-all-eth-interfaces.network || fail eth-optional
x grep -q 'RouteMetric=600' /run/systemd/network/10-netplan-wlan0.network || fail wifi-metric
x grep -q "ssid=\"Kube's Wi-Fi\"" /run/netplan/wpa-wlan0.conf || fail wifi-ssid
x grep -q 'country=HK' /run/netplan/wpa-wlan0.conf || fail wifi-country
x test -e /run/systemd/system/netplan-wpa-wlan0.service || fail wpa-unit
pass network-config

x dpkg -s cloudflared | grep -q '^Status: install ok installed' || fail cloudflared
origins=$(x apt-config dump Unattended-Upgrade::Origins-Pattern | grep -c '^Unattended-Upgrade::Origins-Pattern:: ')
[ "$origins" = 2 ] || fail "unattended origins: $origins, want 2"
# Boot-time apt timers may hold the lock for a while.
for _ in $(seq 60); do
  uu=$(x unattended-upgrade --dry-run -d 2>&1 || true)
  [[ $uu == *"Lock file is already taken"* ]] || break
  sleep 5
done
grep -qE 'Allowed origins are: origin=Debian,codename=[a-z]+-security,label=Debian-Security, origin=cloudflared,codename=any$' \
  <<<"$uu" || fail unattended-origins
[ "$(x apt-config dump APT::Periodic::Unattended-Upgrade)" = 'APT::Periodic::Unattended-Upgrade "1";' ] || fail periodic
pass apt-cloudflared-unattended

[ "$(x cat /opt/printer-proxy/current/VERSION)" = "$tag" ] || fail installed-version
x curl -fsS http://127.0.0.1:9191/health | grep -q "\"$tag\"" || fail health
x systemctl is-enabled printer-proxy-update.timer >/dev/null || fail update-timer
pass bundle-installed

echo "== Wi-Fi values netplan rejects: first boot goes on Ethernet-only"
x sed -i 's/^WIFI_PASSWORD=.*/WIFI_PASSWORD=short/' /etc/printer-proxy/env
rc=0
rerun=$(x env SKIP_NETPLAN_APPLY=1 REPO_API=http://127.0.0.1:8000/api DOWNLOAD_BASE=http://127.0.0.1:8000/dl \
  /usr/local/lib/printer-proxy/firstboot.sh 2>&1) || rc=$?
if [ $rc = 0 ] && [[ $rerun == *"continuing Ethernet-only"* ]] && ! x grep -q wifis /etc/netplan/20-printer-proxy.yaml &&
  x test ! -e /run/systemd/network/10-netplan-wlan0.network; then pass wifi-fallback; else
  printf '%s\n' "$rerun" | tail -n 20 | sed 's/^/    | /'
  fail wifi-fallback
fi

docker restart "$ctr" >/dev/null
wait_for 60 "first boot skipped after reboot" \
  sh -c "docker exec $ctr systemctl show -p ConditionResult printer-proxy-firstboot | grep -qx ConditionResult=no"
pass runs-once

echo "all image tests passed"
