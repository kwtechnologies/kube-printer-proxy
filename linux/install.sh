#!/usr/bin/env bash
# Install the bundle this script sits in. Run as root from an extracted bundle.
# Idempotent: safe to re-run, and to run on an older release for rollback.
#
# Layout:
#   $PREFIX/releases/<tag>/   one full copy of each bundle (kept for rollback)
#   $PREFIX/current           symlink to the active release
#   $PREFIX/current/VERSION   the installed version (contract for the updater)
#   $SYSTEMD_DIR/*.service    units copied from the bundle
#   $PREFIX/units.list        units this script installed; ones a later bundle
#                             no longer ships are disabled and removed
#
# Test overrides: PREFIX, SYSTEMD_DIR, SKIP_SYSTEMCTL=1.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
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
  chmod 755 "$dest.tmp"
  rm -rf "$dest"
  mv "$dest.tmp" "$dest"
fi
# mktemp-made dirs are 0700; DynamicUser services must be able to traverse.
chmod 755 "$dest"

ln -sfn "$dest" "$PREFIX/current.tmp"
mv -T "$PREFIX/current.tmp" "$PREFIX/current"

units=()
for f in "$dest"/*.service "$dest"/*.timer; do
  [ -e "$f" ] || continue
  units+=("$(basename "$f")")
done

have_systemctl() { [ "${SKIP_SYSTEMCTL:-}" != 1 ] && command -v systemctl >/dev/null; }

# Drop units an earlier bundle installed that this one no longer ships.
if [ -f "$PREFIX/units.list" ]; then
  while read -r old; do
    [ -n "$old" ] || continue
    case " ${units[*]} " in *" $old "*) continue ;; esac
    # Services are disabled but not stopped: the updater runs this script from
    # inside printer-proxy-update.service, and stopping a dropped updater would
    # kill it mid-install. A dropped service keeps running until next boot.
    if have_systemctl; then
      case $old in
        *.service) systemctl disable "$old" || true ;;
        *) systemctl disable --now "$old" || true ;;
      esac
    fi
    rm -f "$SYSTEMD_DIR/$old"
  done <"$PREFIX/units.list"
fi

for u in "${units[@]}"; do install -m 644 "$dest/$u" "$SYSTEMD_DIR/"; done
printf '%s\n' "${units[@]}" >"$PREFIX/units.list"

if have_systemctl; then
  systemctl daemon-reload
  systemctl enable "${units[@]}"
  # The proxy gates success (updater polls /health); cloudflared only warns.
  systemctl restart printer-proxy.service
  systemctl restart cloudflared-tunnel.service || echo "install.sh: cloudflared restart failed" >&2
  # Restart (not start) timers so a changed schedule applies; oneshots are left alone.
  for u in "${units[@]}"; do
    case $u in *.timer) systemctl restart "$u" ;; esac
  done
else
  echo "install.sh: systemctl skipped" >&2
fi

echo "installed printer-proxy $tag"
