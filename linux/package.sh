#!/usr/bin/env bash
# Build the release bundle exactly as CI does.
# Usage: linux/package.sh <tag> [outdir]   (default outdir: dist)
set -euo pipefail

tag=${1:?usage: package.sh <tag> [outdir]}
out=${2:-dist}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

mkdir -p "$out"
out=$(cd "$out" && pwd)

CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -C "$root" -trimpath \
  -ldflags "-s -w -X main.version=$tag" -o "$stage/printer-proxy"

# Device-side files only: build-image.sh, test-*.sh, *.example stay in the repo.
for f in "$root"/linux/*.service "$root"/linux/*.timer "$root"/linux/*.sh; do
  [ -e "$f" ] || continue
  case $(basename "$f") in build-image.sh | package.sh | test-*) continue ;; esac
  cp "$f" "$stage/"
done
echo "$tag" >"$stage/VERSION"
chmod 755 "$stage"

if tar --version | grep -q GNU; then own=(--owner=0 --group=0); else own=(--uid 0 --gid 0 --no-xattrs); fi
export COPYFILE_DISABLE=1
tar -C "$stage" -czf "$out/printer-proxy-linux-arm64.tar.gz" "${own[@]}" .
(cd "$out" && { sha256sum printer-proxy-linux-arm64.tar.gz 2>/dev/null || shasum -a 256 printer-proxy-linux-arm64.tar.gz; } >printer-proxy-linux-arm64.tar.gz.sha256)
