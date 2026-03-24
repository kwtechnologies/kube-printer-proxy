#!/usr/bin/env bash
set -euo pipefail
REPO="kwtechnologies/kube-printer-proxy"
ARCH="$(uname -m)"
case "$ARCH" in arm64|aarch64) BIN="printer-proxy-setup-macos-arm64" ;; *) BIN="printer-proxy-setup-macos-x64" ;; esac
TMP="/tmp/${BIN}"
echo "Downloading installer..."
curl -fsSL "https://github.com/${REPO}/releases/latest/download/${BIN}" -o "$TMP"
chmod +x "$TMP"
if [ "$(id -u)" -ne 0 ]; then exec sudo "$TMP"; else exec "$TMP"; fi
