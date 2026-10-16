#!/usr/bin/env bash
# Install the bundle this script sits in. Run as root from an extracted bundle.
# Idempotent: safe to re-run, and to run on an older release for rollback.
#
# Layout:
#   $PREFIX/releases/<tag>/   one full copy of each bundle (kept for rollback)
#   $PREFIX/current           symlink to the active release
#   $SYSTEMD_DIR/*.service    units copied from the bundle
#
# Test overrides: PREFIX, SYSTEMD_DIR, SKIP_SYSTEMCTL=1.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFIX=${PREFIX:-/opt/printer-proxy}
SYSTEMD_DIR=${SYSTEMD_DIR:-/etc/systemd/system}

[ -f "$here/VERSION" ] || { echo "install.sh: no VERSION file in $here" >&2; exit 1; }
[ -x "$here/printer-proxy" ] || { echo "install.sh: no printer-proxy binary in $here" >&2; exit 1; }
tag=$(tr -d '[:space:]' <"$here/VERSION")
case $tag in "" | */* | .*) echo "install.sh: bad version '$tag'" >&2; exit 1 ;; esac

dest=$PREFIX/releases/$tag
mkdir -p "$PREFIX/releases" "$SYSTEMD_DIR"

# Stage then rename, so a half-copied release is never visible.
if [ "$here" != "$dest" ]; then
  rm -rf "$dest.tmp"
  cp -a "$here" "$dest.tmp"
  rm -rf "$dest"
  mv "$dest.tmp" "$dest"
fi

ln -sfn "$dest" "$PREFIX/current.tmp"
mv -T "$PREFIX/current.tmp" "$PREFIX/current"

units=()
for f in "$dest"/*.service "$dest"/*.timer; do
  [ -e "$f" ] || continue
  install -m 644 "$f" "$SYSTEMD_DIR/"
  units+=("$(basename "$f")")
done

if [ "${SKIP_SYSTEMCTL:-}" != 1 ] && command -v systemctl >/dev/null; then
  systemctl daemon-reload
  systemctl enable "${units[@]}"
  # Only the long-running services are restarted; timers/oneshots (updater) are not.
  systemctl restart printer-proxy.service cloudflared-tunnel.service
  for u in "${units[@]}"; do
    case $u in *.timer) systemctl start "$u" ;; esac
  done
else
  echo "install.sh: systemctl skipped" >&2
fi

echo "installed printer-proxy $tag"
