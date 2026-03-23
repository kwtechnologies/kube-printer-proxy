#!/usr/bin/env bash
# printer-proxy installer for macOS
# Interactive, menu-driven — uses launchd for persistent services

# When piped from curl (stdin is not a TTY), re-download the script to a
# temp file and re-execute it so that interactive read prompts work.
if [ ! -t 0 ]; then
  SELF_URL="https://github.com/kwtechnologies/kube-printer-proxy/releases/latest/download/install.sh"
  tmp="/tmp/printer-proxy-install-$$.sh"
  curl -fsSL -o "$tmp" "$SELF_URL"
  exec sudo bash "$tmp" "$@" </dev/tty
fi

set -euo pipefail

INSTALL_DIR="/usr/local/printer-proxy"
PROXY_LABEL="com.kwtech.printer-proxy"
CF_LABEL="com.kwtech.cloudflared-tunnel"
PROXY_PLIST="$HOME/Library/LaunchAgents/${PROXY_LABEL}.plist"
CF_PLIST="$HOME/Library/LaunchAgents/${CF_LABEL}.plist"
GH_REPO="kwtechnologies/kube-printer-proxy"

# --------------- colours ---------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${GREEN}$*${NC}"; }
warn()  { echo -e "${YELLOW}$*${NC}"; }
err()   { echo -e "${RED}$*${NC}"; }
cyan()  { echo -e "${CYAN}$*${NC}"; }

# --------------- require sudo ---------------
require_sudo() {
  if [ "$EUID" -ne 0 ]; then
    warn "This script needs elevated privileges to write to ${INSTALL_DIR}."
    exec sudo bash "$0" "$@"
  fi
}

# --------------- helpers ---------------
detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64)  echo "amd64" ;;
    arm64)   echo "arm64" ;;
    aarch64) echo "arm64" ;;
    *)       err "Unsupported architecture: $arch"; exit 1 ;;
  esac
}

get_latest_tag() {
  curl -fsSL "https://api.github.com/repos/${GH_REPO}/releases/latest" \
    | grep '"tag_name"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/'
}

download() {
  local url="$1" dest="$2"
  echo "  Downloading: $url"
  curl -fSL --progress-bar -o "$dest" "$url"
}

stop_service() {
  local label="$1" plist="$2"
  if launchctl list "$label" &>/dev/null; then
    warn "  Stopping $label..."
    launchctl unload "$plist" 2>/dev/null || true
  fi
}

# --------------- install ---------------
do_install() {
  echo ""
  info "--- Step 1/5: Gather configuration ---"

  read -rp "Enter your Cloudflare Tunnel token: " TUNNEL_TOKEN
  if [ -z "$TUNNEL_TOKEN" ]; then
    err "Tunnel token is required. Aborting."; return
  fi

  read -rp "Enter the API key for the print proxy: " API_KEY
  if [ -z "$API_KEY" ]; then
    err "API key is required. Aborting."; return
  fi

  echo ""
  info "--- Step 2/5: Create install directory ---"
  mkdir -p "$INSTALL_DIR"
  echo "  Directory: $INSTALL_DIR"

  echo ""
  info "--- Step 3/5: Download binaries ---"

  local arch
  arch="$(detect_arch)"
  local tag
  tag="$(get_latest_tag)"

  # printer-proxy binary
  local proxy_url="https://github.com/${GH_REPO}/releases/download/${tag}/printer-proxy-darwin-${arch}"
  download "$proxy_url" "${INSTALL_DIR}/printer-proxy"
  chmod +x "${INSTALL_DIR}/printer-proxy"

  # cloudflared
  local cf_arch
  if [ "$arch" = "arm64" ]; then cf_arch="arm64"; else cf_arch="amd64"; fi
  local cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-${cf_arch}.tgz"
  local cf_tmp="/tmp/cloudflared.tgz"
  download "$cf_url" "$cf_tmp"
  tar -xzf "$cf_tmp" -C "${INSTALL_DIR}" cloudflared
  chmod +x "${INSTALL_DIR}/cloudflared"
  rm -f "$cf_tmp"

  echo ""
  info "--- Step 4/5: Create configuration ---"
  cat > "${INSTALL_DIR}/.env" <<EOF
API_KEY=${API_KEY}
PORT=9191
EOF
  echo "  Created ${INSTALL_DIR}/.env"

  echo ""
  info "--- Step 5/5: Install launchd services ---"

  # Ensure LaunchAgents dir exists
  mkdir -p "$HOME/Library/LaunchAgents"

  # Stop existing services
  stop_service "$PROXY_LABEL" "$PROXY_PLIST"
  stop_service "$CF_LABEL" "$CF_PLIST"

  # printer-proxy plist
  cat > "$PROXY_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PROXY_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${INSTALL_DIR}/printer-proxy</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>API_KEY</key>
    <string>${API_KEY}</string>
    <key>PORT</key>
    <string>9191</string>
  </dict>
  <key>WorkingDirectory</key>
  <string>${INSTALL_DIR}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${INSTALL_DIR}/proxy.log</string>
  <key>StandardErrorPath</key>
  <string>${INSTALL_DIR}/proxy.log</string>
</dict>
</plist>
PLIST
  launchctl load "$PROXY_PLIST"

  # cloudflared plist
  cat > "$CF_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${CF_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${INSTALL_DIR}/cloudflared</string>
    <string>tunnel</string>
    <string>run</string>
    <string>--token</string>
    <string>${TUNNEL_TOKEN}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${INSTALL_DIR}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${INSTALL_DIR}/cloudflared.log</string>
  <key>StandardErrorPath</key>
  <string>${INSTALL_DIR}/cloudflared.log</string>
</dict>
</plist>
PLIST
  launchctl load "$CF_PLIST"

  # Health check
  echo ""
  warn "Waiting for services to start..."
  sleep 3
  if curl -sf http://localhost:9191/health >/dev/null 2>&1; then
    info "Health check passed!"
  else
    warn "Health check failed — the service may still be starting. Check ${INSTALL_DIR}/proxy.log"
  fi

  echo ""
  info "Installation complete!"
  echo "  Install directory : $INSTALL_DIR"
  echo "  Proxy service     : $PROXY_LABEL"
  echo "  Tunnel service    : $CF_LABEL"
  echo "  Logs              : ${INSTALL_DIR}/proxy.log / cloudflared.log"
}

# --------------- update ---------------
do_update() {
  echo ""
  info "--- Updating printer-proxy ---"

  if [ ! -f "${INSTALL_DIR}/printer-proxy" ]; then
    err "Installation not found at ${INSTALL_DIR}. Please install first."; return
  fi

  local arch
  arch="$(detect_arch)"
  local tag
  tag="$(get_latest_tag)"

  stop_service "$PROXY_LABEL" "$PROXY_PLIST"
  sleep 2

  local proxy_url="https://github.com/${GH_REPO}/releases/download/${tag}/printer-proxy-darwin-${arch}"
  download "$proxy_url" "${INSTALL_DIR}/printer-proxy"
  chmod +x "${INSTALL_DIR}/printer-proxy"

  launchctl load "$PROXY_PLIST"

  echo ""
  info "Update complete! Service restarted."
}

# --------------- uninstall ---------------
do_uninstall() {
  echo ""
  read -rp "This will remove all services and files. Type YES to confirm: " confirm
  if [ "$confirm" != "YES" ]; then
    warn "Aborted."; return
  fi

  stop_service "$PROXY_LABEL" "$PROXY_PLIST"
  stop_service "$CF_LABEL" "$CF_PLIST"
  rm -f "$PROXY_PLIST" "$CF_PLIST"

  if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    info "Removed $INSTALL_DIR"
  fi

  info "Uninstall complete."
}

# --------------- main menu ---------------
require_sudo "$@"

echo ""
cyan "===================================="
cyan "  Printer Proxy Installer (macOS)"
cyan "===================================="
echo ""
echo "  1) Install (fresh)"
echo "  2) Update (download latest binary)"
echo "  3) Uninstall (remove everything)"
echo ""
read -rp "Choose an option (1/2/3): " choice

case "$choice" in
  1) do_install ;;
  2) do_update ;;
  3) do_uninstall ;;
  *) err "Invalid choice." ;;
esac

echo ""
echo "Done. Press Enter to exit..."
read -r
