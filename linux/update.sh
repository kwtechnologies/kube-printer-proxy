#!/usr/bin/env bash
# Nightly self-update. Run as root (printer-proxy-update.service).
#
#   0. $PREFIX/rollback-to left by an interrupted run: roll back first, exit 1.
#   1. CHANNEL from $ENV_FILE (missing file or key: stable). stable =
#      releases/latest, pre = newest release including pre-releases.
#   2. Same tag as $PREFIX/current/VERSION: exit 0.
#   3. Download the bundle and its .sha256; on mismatch abort, touch nothing.
#   4. Run the bundle's install.sh, then poll /health until it reports the tag.
#   5. Failure: reinstall the previous release via its own install.sh, delete
#      the failed release, exit 1.
#   6. Success: keep current + previous release, prune the rest.
# Nothing installed yet (first boot): install the target.
#
# Test overrides: ENV_FILE, PREFIX, REPO_API, DOWNLOAD_BASE, HEALTH_URL,
# HEALTH_TIMEOUT (seconds), plus install.sh's SYSTEMD_DIR, SKIP_SYSTEMCTL.
set -euo pipefail

ENV_FILE=${ENV_FILE:-/etc/printer-proxy/env}
PREFIX=${PREFIX:-/opt/printer-proxy}
REPO_API=${REPO_API:-https://api.github.com/repos/kwtechnologies/kube-printer-proxy}
DOWNLOAD_BASE=${DOWNLOAD_BASE:-https://github.com/kwtechnologies/kube-printer-proxy/releases/download}
HEALTH_URL=${HEALTH_URL:-http://127.0.0.1:9191/health}
HEALTH_TIMEOUT=${HEALTH_TIMEOUT:-15}
asset=printer-proxy-linux-arm64.tar.gz
marker=$PREFIX/rollback-to
export PREFIX

log() { echo "update.sh: $*"; }
# <3>/<4> = err/warning priority in the journal.
die() { echo "<3>update.sh: $*" >&2; exit 1; }
# Abort transfers that stall (<1 KB/s for a minute), not slow-but-moving ones.
fetch() { curl -fsSL --retry 3 --connect-timeout 10 --speed-limit 1024 --speed-time 60 "$@"; }
# Tags become paths; only accept plain tag characters.
valid_tag() { case $1 in "" | .* | *[!A-Za-z0-9._-]*) return 1 ;; esac; }

wait_health() {
  local want=$1 deadline=$((SECONDS + HEALTH_TIMEOUT)) got
  while [ $SECONDS -lt $deadline ]; do
    got=$(curl -fsS --max-time 2 "$HEALTH_URL" 2>/dev/null |
      grep -o '"version": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/') || true
    [ "$got" = "$want" ] && return 0
    sleep 1
  done
  log "health never reported $want (last: '${got:-none}')"
  return 1
}

# rollback <to> <failed>: reinstall <to>, delete <failed>, exit 1. The marker
# stays until the rollback is healthy, so the next run retries it.
rollback() {
  echo "<3>update.sh: UPDATE FAILED: $2 did not come up healthy, rolling back to $1" >&2
  bash "$PREFIX/releases/$1/install.sh" || die "ROLLBACK FAILED: $1 install.sh exited non-zero"
  wait_health "$1" || die "ROLLBACK UNHEALTHY: $1 does not report itself on $HEALTH_URL"
  rm -rf "$marker" "$PREFIX/releases/$2" "$PREFIX/releases/$2.tmp"
  die "rolled back to $1 after failed update to $2"
}

main() {
  local channel url tag cur="" prev failed
  rm -rf "$PREFIX"/.update.* # work dirs left by a killed run
  if [ -f "$marker" ]; then
    read -r prev failed <"$marker" || true
    if valid_tag "${prev:-}" && valid_tag "${failed:-}" && [ "$prev" != "$failed" ] &&
      [ -f "$PREFIX/releases/$prev/install.sh" ]; then
      log "previous run was interrupted while installing $failed"
      rollback "$prev" "$failed"
    fi
    echo "<4>update.sh: WARNING: ignoring unusable $marker ($(cat "$marker"))" >&2
    rm -f "$marker"
  fi

  channel=$(sed -n 's/^CHANNEL=//p' "$ENV_FILE" 2>/dev/null | tail -n1 | tr -d "[:space:]\"'") || true
  case ${channel:-stable} in
    stable) url=$REPO_API/releases/latest ;;
    pre) url="$REPO_API/releases?per_page=1" ;;
    *) die "unknown CHANNEL '$channel' in $ENV_FILE" ;;
  esac

  # No jq on the device; tag_name is the first such key in either response.
  tag=$(fetch -H 'Accept: application/vnd.github+json' "$url" |
    grep -o '"tag_name": *"[^"]*"' | head -n1 | sed 's/.*"\([^"]*\)"$/\1/') || true
  valid_tag "$tag" || die "no usable release tag from $url (got '$tag')"

  [ -f "$PREFIX/current/VERSION" ] && cur=$(tr -d '[:space:]' <"$PREFIX/current/VERSION")
  if [ "$tag" = "$cur" ]; then
    log "up to date ($cur, channel ${channel:-stable})"
    return 0
  fi
  log "updating ${cur:-<none>} -> $tag (channel ${channel:-stable})"
  if [ -n "$cur" ] && [ ! -f "$PREFIX/releases/$cur/install.sh" ]; then
    echo "<4>update.sh: WARNING: no rollback target, $PREFIX/releases/$cur/install.sh is missing" >&2
    cur=""
  fi

  # Work under $PREFIX, not /tmp: same filesystem as releases/, and /tmp may be
  # a small tmpfs or noexec.
  mkdir -p "$PREFIX"
  work=$(mktemp -d "$PREFIX/.update.XXXXXX") # global: the EXIT trap runs after main's locals are gone
  trap 'rm -rf "$work"' EXIT
  fetch -o "$work/$asset" "$DOWNLOAD_BASE/$tag/$asset" || die "download of $tag failed"
  fetch -o "$work/$asset.sha256" "$DOWNLOAD_BASE/$tag/$asset.sha256" || die "download of $tag checksum failed"
  # Compare hashes only; the filename inside the .sha256 is not trusted.
  local want got
  want=$(cut -d' ' -f1 <"$work/$asset.sha256")
  got=$(sha256sum "$work/$asset" | cut -d' ' -f1)
  if [ -z "$want" ] || [ "$want" != "$got" ]; then die "sha256 mismatch for $tag (want '$want', got '$got'); nothing changed"; fi

  mkdir "$work/bundle"
  tar -xzf "$work/$asset" -C "$work/bundle"
  [ "$(tr -d '[:space:]' <"$work/bundle/VERSION")" = "$tag" ] || die "bundle VERSION does not match $tag; nothing changed"

  # From here until /health confirms, a kill leaves the marker for the next run.
  if [ -n "$cur" ]; then echo "$cur $tag" >"$marker"; fi
  if bash "$work/bundle/install.sh" && wait_health "$tag"; then
    rm -f "$marker"
    log "installed $tag"
    local d
    for d in "$PREFIX"/releases/*; do
      case ${d##*/} in "$tag" | "$cur") ;; *) log "pruning ${d##*/}"; rm -rf "$d" ;; esac
    done
    return 0
  fi

  if [ -z "$cur" ]; then
    die "UPDATE FAILED: $tag is unhealthy and there is no previous release to roll back to"
  fi
  rollback "$cur" "$tag"
}

# main is parsed in full before it runs, so install.sh replacing this file
# (new release dir, pruning) cannot change what the running updater executes.
main "$@"
exit
