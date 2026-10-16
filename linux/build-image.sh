#!/usr/bin/env bash
# Build a flashable SD image for one site, on the dev Mac (needs Docker).
# Usage: linux/build-image.sh <env-file> [armbian-image.img.xz|.img]
#
# Without an image argument, downloads the pinned Armbian image below into
# $CACHE and checks it against the pinned sha256. A different image needs
# ARMBIAN_SHA256=<its sha256> (and ARMBIAN_URL to download it).
# Output: $OUT (default ./printer-proxy-<env name>.img). It contains the site's
# secrets: never commit it, delete it after flashing.
#
# The Armbian image is one ext4 partition macOS cannot write, so the image work
# runs in a privileged debian:bookworm container (loop mount).
set -euo pipefail

# Armbian 25.5.1, Debian 12 bookworm, minimal, kernel 6.12 (current). Armbian
# no longer lists bookworm for this board (only trixie rolling builds), so this
# comes from the Armbian archive. sha256 is Armbian's .sha, and the image's
# .asc verifies against Armbian's signing key DF00FAF1C577104B50BF1D0093D6889F9F0E78D5.
PINNED_NAME=Armbian_25.5.1_Orangepizero3_bookworm_current_6.12.23_minimal.img.xz
PINNED_SHA256=34f76f8266b56e714644610bb792e8932726330b044f15f21505191b8062cf07
ARMBIAN_URL=${ARMBIAN_URL:-https://fi.mirror.armbian.de/archive/orangepizero3/archive/$PINNED_NAME}
ARMBIAN_SHA256=${ARMBIAN_SHA256:-$PINNED_SHA256}
CACHE=${CACHE:-$HOME/Library/Caches/printer-proxy}

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
die() { echo "build-image.sh: $*" >&2; exit 1; }

# Values reach systemd (EnvironmentFile) and firstboot.sh literally, so reject
# anything either would read differently. Never print values.
check_env() {
  local f=$1 line key n=0 seen=" "
  [ -z "$(tail -c1 "$f")" ] || die "$f: last line has no newline"
  while IFS= read -r line; do
    n=$((n + 1))
    case $line in "" | \#*) continue ;; esac
    case $line in *$'\r'*) die "$f:$n: CR (Windows line ending)" ;; esac
    key=${line%%=*}
    [[ $line == *=* && $key =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "$f:$n: not KEY=value"
    case $seen in *" $key "*) die "$f:$n: duplicate $key" ;; esac
    seen="$seen$key "
    case ${line#*=} in [\"\']* | *\\* | " "* | *" ") die "$f:$n: $key: quotes, backslashes or edge spaces are not allowed" ;; esac
  done <"$f"
  local k
  for k in TUNNEL_TOKEN API_KEY SSH_AUTHORIZED_KEYS; do
    grep -q "^$k=." "$f" || die "$f: $k is required"
  done
  grep -qE '^CHANNEL=(stable|pre)$' "$f" || die "$f: CHANNEL must be stable or pre"
  grep -qE '^SSH_AUTHORIZED_KEYS=(ssh-|ecdsa-|sk-)' "$f" || die "$f: SSH_AUTHORIZED_KEYS is not a public key"
  if grep -q '^WIFI_PASSWORD=.' "$f" && ! grep -q '^WIFI_SSID=.' "$f"; then die "$f: WIFI_PASSWORD without WIFI_SSID"; fi
  if grep -q '^DEVICE_HOSTNAME=.' "$f"; then
    grep -qE '^DEVICE_HOSTNAME=[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' "$f" || die "$f: bad DEVICE_HOSTNAME"
  fi
}

if [ "${1:-}" = --in-container ]; then
  # /in/site.env, /in/image/<name>, /out/<name>.img
  name=$2 outname=$3
  apt-get -qq update >/dev/null && apt-get -qq install -y xz-utils fdisk >/dev/null
  work=/tmp/build.img
  case $name in
    *.xz) xz -dc "/in/image/$name" >"$work" ;;
    *) cp "/in/image/$name" "$work" ;;
  esac
  # Armbian: one ext4 root partition.
  start=$(sfdisk -J "$work" | grep -o '"start": *[0-9]*' | head -n1 | grep -o '[0-9]*$')
  m=/mnt/root
  mkdir -p "$m"
  mount -o loop,offset=$((start * 512)) "$work" "$m"
  trap 'umount "$m"' EXIT
  [ -f "$m/etc/armbian-release" ] || die "not an Armbian root filesystem"

  install -d -m 755 "$m/etc/printer-proxy" "$m/usr/local/lib/printer-proxy"
  install -m 600 /in/site.env "$m/etc/printer-proxy/env"
  install -m 755 /linux/image/firstboot.sh /linux/update.sh "$m/usr/local/lib/printer-proxy/"
  install -m 644 /linux/image/printer-proxy-firstboot.service "$m/etc/systemd/system/"
  ln -sfn /etc/systemd/system/printer-proxy-firstboot.service \
    "$m/etc/systemd/system/multi-user.target.wants/printer-proxy-firstboot.service"
  install -m 644 /linux/image/sshd-printer-proxy.conf "$m/etc/ssh/sshd_config.d/10-printer-proxy.conf"

  # Skip Armbian's first-login wizard: /etc/profile.d/armbian-check-first-login.sh
  # runs armbian-firstlogin only while /root/.not_logged_in_yet exists, and the
  # image autologins root on tty1 and ttyS0 to reach it. firstboot.sh does
  # what we need from the wizard; drop the trigger and the root autologin.
  rm -f "$m/root/.not_logged_in_yet" "$m"/etc/systemd/system/*getty@*.service.d/override.conf

  sync
  umount "$m"
  trap - EXIT
  # Plain copy: mv/cp try to punch holes, which Docker Desktop bind mounts reject.
  cat "$work" >"/out/$outname"
  exit 0
fi

env_file=${1:?usage: build-image.sh <env-file> [armbian-image]}
[ -f "$env_file" ] || die "no such env file: $env_file"
check_env "$env_file"
command -v docker >/dev/null || die "docker not found"

image=${2:-}
if [ -z "$image" ]; then
  mkdir -p "$CACHE"
  image=$CACHE/${ARMBIAN_URL##*/}
  if [ ! -f "$image" ]; then
    echo "downloading ${ARMBIAN_URL##*/}"
    curl -fL --progress-bar --retry 3 -o "$image.part" "$ARMBIAN_URL"
    mv "$image.part" "$image"
  fi
fi
[ -f "$image" ] || die "no such image: $image"
echo "checking sha256 of ${image##*/}"
got=$(shasum -a 256 "$image" | cut -d' ' -f1)
[ "$got" = "$ARMBIAN_SHA256" ] || die "sha256 mismatch for $image (got $got, want $ARMBIAN_SHA256)"

site=$(basename "$env_file"); site=${site%.env}
OUT=${OUT:-printer-proxy-$site.img}
outdir=$(cd "$(dirname "$OUT")" && pwd -P)
img_dir=$(cd "$(dirname "$image")" && pwd -P)
env_abs=$(cd "$(dirname "$env_file")" && pwd -P)/$(basename "$env_file")

docker run --rm --privileged \
  -v "$here:/linux:ro" -v "$env_abs:/in/site.env:ro" -v "$img_dir:/in/image:ro" -v "$outdir:/out" \
  debian:bookworm /linux/build-image.sh --in-container "$(basename "$image")" "$(basename "$OUT")"
chmod 600 "$outdir/$(basename "$OUT")"
echo "wrote $outdir/$(basename "$OUT") (contains secrets: flash it, then delete it)"
