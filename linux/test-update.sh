#!/usr/bin/env bash
# Fixture test for update.sh (and install.sh underneath it).
# Usage: linux/test-update.sh   (needs Docker; re-runs itself in debian:bookworm)
#
# Serves fixture releases, a fake GitHub API and a fake /health from a local
# python http.server. systemctl is a stub: "restart printer-proxy.service"
# runs the current release's fixture binary, which prints its /health body.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
if [ "${1:-}" != --in-container ]; then
  exec docker run --rm -v "$here:/linux:ro" debian:bookworm /linux/test-update.sh --in-container
fi

apt-get -qq update >/dev/null && apt-get -qq install -y curl python3 >/dev/null

t=$(mktemp -d)
www=$t/www
asset=printer-proxy-linux-arm64.tar.gz
export PREFIX=$t/opt SYSTEMD_DIR=$t/systemd ENV_FILE=$t/env
export REPO_API=http://127.0.0.1:8000/api DOWNLOAD_BASE=http://127.0.0.1:8000/dl
export HEALTH_URL=http://127.0.0.1:8000/health HEALTH_TIMEOUT=3

mkdir -p "$t/bin" "$www/api/releases"
cat >"$t/bin/systemctl" <<EOF
#!/bin/sh
echo "systemctl \$*" >>"$t/systemctl.log"
if [ "\$1 \$2" = "restart printer-proxy.service" ]; then "$PREFIX/current/printer-proxy" >"$www/health"; fi
EOF
chmod +x "$t/bin/systemctl"
export PATH=$t/bin:$PATH

python3 -m http.server -d "$www" -b 127.0.0.1 8000 >/dev/null 2>&1 &
trap 'kill $!' EXIT
until curl -fs http://127.0.0.1:8000/ >/dev/null; do sleep 0.2; done

# bundle <tag> [version its /health reports] [--no-updater]
bundle() {
  local d=$t/build/$1
  mkdir -p "$d" "$www/dl/$1"
  cp "$here"/install.sh "$here"/update.sh "$here"/*.service "$here"/*.timer "$d/"
  if [ "${3:-}" = --no-updater ]; then rm "$d"/printer-proxy-update.*; fi
  echo "$1" >"$d/VERSION"
  printf '#!/bin/sh\necho '\''{"status":"ok","version":"%s"}'\''\n' "${2:-$1}" >"$d/printer-proxy"
  chmod 755 "$d" "$d/printer-proxy"
  tar -C "$d" -czf "$www/dl/$1/$asset" .
  (cd "$www/dl/$1" && sha256sum "$asset" >"$asset.sha256")
}

# releases <latest stable> <newest incl. pre-releases>
# GET /api/releases?per_page=1 redirects to /api/releases/ and serves index.html.
releases() {
  printf '{"url":"x","tag_name":"%s","prerelease":false}' "$1" >"$www/api/releases/latest"
  printf '[\n  {\n    "tag_name": "%s"\n  },\n  {\n    "tag_name": "%s"\n  }\n]\n' "$2" "$1" >"$www/api/releases/index.html"
}

channel() { echo "CHANNEL=$1" >"$ENV_FILE"; }
installed() { cat "$PREFIX/current/VERSION"; }
health() { curl -fsS "$HEALTH_URL"; }
kept() { (cd "$PREFIX/releases" && echo *); }
snapshot() { find "$PREFIX" "$SYSTEMD_DIR" -printf '%p %s %T@ %l\n' | sort; }
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }
# update [script]: run the updater, keep exit code in $rc and output in $out
update() {
  rc=0
  out=$("${1:-$PREFIX/current/update.sh}" 2>&1) || rc=$?
  printf '%s\n' "$out" | sed 's/^/    | /'
}

echo "== first boot: nothing installed, installs target"
channel stable; bundle v1; releases v1 v1
update "$here/update.sh"
if [ $rc = 0 ] && [ "$(installed)" = v1 ] && health | grep -q "\"v1\""; then pass first-boot; else fail first-boot; fi
if [ -f "$SYSTEMD_DIR/printer-proxy-update.timer" ] && grep -q printer-proxy-update.service "$PREFIX/units.list"; then pass units-installed; else fail units-installed; fi

echo "== (a) up to date: no-op"
before=$(snapshot); : >"$t/systemctl.log"
update
if [ $rc = 0 ] && [ "$(snapshot)" = "$before" ] && [ ! -s "$t/systemctl.log" ] && [[ $out == *"up to date"* ]]; then pass a-noop; else fail a-noop; fi

echo "== (b) new release installs"
bundle v2; releases v2 v2
update
if [ $rc = 0 ] && [ "$(installed)" = v2 ] && health | grep -q "\"v2\"" && [ "$(kept)" = "v1 v2" ]; then pass b-installed; else fail b-installed; fi

echo "== (c) bad sha256: abort, nothing changed"
bundle v3; releases v3 v3
echo "0000000000000000000000000000000000000000000000000000000000000000  $asset" >"$www/dl/v3/$asset.sha256"
before=$(snapshot); : >"$t/systemctl.log"
update
if [ $rc != 0 ] && [[ $out == *"sha256 mismatch"* ]] && [ "$(snapshot)" = "$before" ] && [ ! -s "$t/systemctl.log" ]; then pass c-aborted; else fail c-aborted; fi

echo "== (d) health never reports new version: roll back"
bundle v4 v2; releases v4 v4
update
if [ $rc != 0 ] && [[ $out == *"rolling back to v2"* ]] && [ "$(installed)" = v2 ] && health | grep -q "\"v2\""; then pass d-rolled-back; else fail d-rolled-back; fi

echo "== (e) stable ignores pre-release, pre picks it"
bundle v5-rc1; releases v2 v5-rc1
update
if [ $rc = 0 ] && [ "$(installed)" = v2 ] && [[ $out == *"up to date"* ]]; then pass e-stable-ignores; else fail e-stable-ignores; fi
channel pre
update
if [ $rc = 0 ] && [ "$(installed)" = v5-rc1 ] && health | grep -q "\"v5-rc1\""; then pass e-pre-installs; else fail e-pre-installs; fi
if [ "$(kept)" = "v2 v5-rc1" ]; then pass e-pruned; else fail e-pruned; fi

echo "== dropped updater units: service disabled without --now, timer stopped"
bundle v6-rc1 v6-rc1 --no-updater; releases v2 v6-rc1
: >"$t/systemctl.log"
update
if [ $rc = 0 ] && [ "$(installed)" = v6-rc1 ] && [ ! -e "$SYSTEMD_DIR/printer-proxy-update.service" ] &&
  grep -qx "systemctl disable printer-proxy-update.service" "$t/systemctl.log" &&
  grep -qx "systemctl disable --now printer-proxy-update.timer" "$t/systemctl.log"; then pass drop-units; else fail drop-units; fi

echo "all update tests passed"
