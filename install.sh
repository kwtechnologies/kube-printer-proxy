#!/usr/bin/env bash
# printer-proxy installer for macOS
# Interactive, menu-driven — uses launchd for persistent services
# Supports automatic Cloudflare Tunnel creation via API

# --------------- argument parsing (before pipe detection) ---------------
ARG_TUNNEL_NAME=""
ARG_CF_TOKEN=""
ARG_API_KEY=""
_ORIG_ARGS=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tunnel-name) ARG_TUNNEL_NAME="$2"; shift 2 ;;
    --cf-token)    ARG_CF_TOKEN="$2"; shift 2 ;;
    --api-key)     ARG_API_KEY="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# When piped from curl (stdin is not a TTY), re-download the script to a
# temp file and re-execute it so that interactive read prompts work.
if [ ! -t 0 ]; then
  SELF_URL="https://github.com/kwtechnologies/kube-printer-proxy/releases/latest/download/install.sh"
  tmp="/tmp/printer-proxy-install-$$.sh"
  curl -fsSL -o "$tmp" "$SELF_URL"
  exec sudo bash "$tmp" "${_ORIG_ARGS[@]}" </dev/tty
fi

set -euo pipefail

INSTALL_DIR="/usr/local/printer-proxy"
PROXY_LABEL="com.kwtech.printer-proxy"
CF_LABEL="com.kwtech.cloudflared-tunnel"
PROXY_PLIST="$HOME/Library/LaunchAgents/${PROXY_LABEL}.plist"
CF_PLIST="$HOME/Library/LaunchAgents/${CF_LABEL}.plist"
GH_REPO="kwtechnologies/kube-printer-proxy"
CF_DOMAIN="kwtech.dev"
CF_API_BASE="https://api.cloudflare.com/client/v4"

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
    exec sudo bash "$0" "${_ORIG_ARGS[@]}"
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

generate_api_key() {
  openssl rand -hex 16
}

# --------------- Cloudflare API helpers ---------------
json_val() {
  python3 -c "import sys,json; d=json.load(sys.stdin); print($1)" 2>/dev/null
}

cf_get() {
  curl -sS -H "Authorization: Bearer ${CF_TOKEN}" "${CF_API_BASE}$1"
}

cf_post() {
  curl -sS -X POST -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json" -d "$2" "${CF_API_BASE}$1"
}

cf_put() {
  curl -sS -X PUT -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json" -d "$2" "${CF_API_BASE}$1"
}

# setup_tunnel: create/reuse a Cloudflare Tunnel and configure DNS.
# Sets TUNNEL_TOKEN and PROXY_URL on success.
setup_tunnel() {
  local tunnel_name="$1"
  local subdomain="print-proxy-${tunnel_name}"
  local hostname="${subdomain}.${CF_DOMAIN}"

  echo ""
  info "  Verifying Cloudflare API token and fetching account..."
  local accounts
  accounts="$(cf_get "/accounts?per_page=1")"
  local cf_success
  cf_success="$(echo "$accounts" | json_val "d.get('success', False)")"
  if [ "$cf_success" != "True" ]; then
    err "  API token is invalid or lacks permissions."
    local cf_errors
    cf_errors="$(echo "$accounts" | json_val "d.get('errors', [])")"
    err "  Errors: $cf_errors"
    return 1
  fi
  local account_id
  account_id="$(echo "$accounts" | json_val "d['result'][0]['id']")"
  if [ -z "$account_id" ]; then
    err "  Could not determine account ID. Aborting."; return 1
  fi
  info "  Token verified. Account: $account_id"

  echo ""
  info "  Fetching zone ID for ${CF_DOMAIN}..."
  local zones
  zones="$(cf_get "/zones?name=${CF_DOMAIN}&per_page=1")"
  local zone_id
  zone_id="$(echo "$zones" | json_val "d['result'][0]['id']")"
  if [ -z "$zone_id" ]; then
    err "  Could not find zone ${CF_DOMAIN}. Aborting."; return 1
  fi
  echo "  Zone: $zone_id"

  echo ""
  info "  Checking for existing tunnel '${tunnel_name}'..."
  local existing
  existing="$(cf_get "/accounts/${account_id}/cfd_tunnel?name=${tunnel_name}&is_deleted=false")"
  local tunnel_id
  tunnel_id="$(echo "$existing" | json_val "d['result'][0]['id'] if d['result'] else ''" 2>/dev/null || echo "")"

  if [ -n "$tunnel_id" ]; then
    warn "  Found existing tunnel: $tunnel_id — reusing it."
  else
    info "  Creating new tunnel '${tunnel_name}'..."
    local create_resp
    create_resp="$(cf_post "/accounts/${account_id}/cfd_tunnel" \
      "{\"name\":\"${tunnel_name}\",\"config_src\":\"cloudflare\",\"tunnel_secret\":\"$(openssl rand -base64 32)\"}")"
    tunnel_id="$(echo "$create_resp" | json_val "d['result']['id']")"
    if [ -z "$tunnel_id" ]; then
      err "  Failed to create tunnel. Response:"; echo "$create_resp"; return 1
    fi
    info "  Created tunnel: $tunnel_id"
  fi

  echo ""
  info "  Configuring ingress rules (${hostname} -> http://localhost:9191)..."
  local config_resp
  config_resp="$(cf_put "/accounts/${account_id}/cfd_tunnel/${tunnel_id}/configurations" \
    "{\"config\":{\"ingress\":[{\"hostname\":\"${hostname}\",\"service\":\"http://localhost:9191\"},{\"service\":\"http_status:404\"}]}}")"
  local config_ok
  config_ok="$(echo "$config_resp" | json_val "d.get('success', False)")"
  if [ "$config_ok" != "True" ]; then
    err "  Failed to configure ingress. Response:"; echo "$config_resp"; return 1
  fi
  info "  Ingress configured."

  echo ""
  info "  Creating DNS CNAME record (${hostname} -> ${tunnel_id}.cfargotunnel.com)..."
  # Check if record already exists
  local dns_check
  dns_check="$(cf_get "/zones/${zone_id}/dns_records?name=${hostname}&type=CNAME")"
  local existing_dns_id
  existing_dns_id="$(echo "$dns_check" | json_val "d['result'][0]['id'] if d['result'] else ''" 2>/dev/null || echo "")"

  if [ -n "$existing_dns_id" ]; then
    warn "  DNS record already exists — updating it."
    cf_put "/zones/${zone_id}/dns_records/${existing_dns_id}" \
      "{\"type\":\"CNAME\",\"name\":\"${hostname}\",\"content\":\"${tunnel_id}.cfargotunnel.com\",\"proxied\":true}" >/dev/null
  else
    cf_post "/zones/${zone_id}/dns_records" \
      "{\"type\":\"CNAME\",\"name\":\"${hostname}\",\"content\":\"${tunnel_id}.cfargotunnel.com\",\"proxied\":true}" >/dev/null
  fi
  info "  DNS record set."

  echo ""
  info "  Retrieving tunnel token..."
  local token_resp
  token_resp="$(cf_get "/accounts/${account_id}/cfd_tunnel/${tunnel_id}/token")"
  TUNNEL_TOKEN="$(echo "$token_resp" | json_val "d['result']")"
  if [ -z "$TUNNEL_TOKEN" ]; then
    err "  Failed to get tunnel token. Response:"; echo "$token_resp"; return 1
  fi
  PROXY_URL="https://${hostname}"
  info "  Tunnel setup complete!"
}

# --------------- install ---------------
do_install() {
  echo ""
  info "--- Step 1/6: Tunnel setup ---"
  echo ""

  local tunnel_setup_mode=""
  if [ -n "$ARG_CF_TOKEN" ] && [ -n "$ARG_TUNNEL_NAME" ]; then
    tunnel_setup_mode="auto"
  else
    echo "  How would you like to configure the Cloudflare Tunnel?"
    echo ""
    echo "    a) I have a tunnel token already"
    echo "    b) Create a new tunnel automatically (requires Cloudflare API token)"
    echo ""
    read -rp "  Choose (a/b): " tunnel_setup_mode
  fi

  TUNNEL_TOKEN=""
  PROXY_URL=""
  API_KEY=""

  case "$tunnel_setup_mode" in
    a)
      read -rp "Enter your Cloudflare Tunnel token: " TUNNEL_TOKEN
      if [ -z "$TUNNEL_TOKEN" ]; then
        err "Tunnel token is required. Aborting."; return
      fi
      read -rp "Enter the API key for the print proxy: " API_KEY
      if [ -z "$API_KEY" ]; then
        err "API key is required. Aborting."; return
      fi
      ;;
    b|auto)
      CF_TOKEN="${ARG_CF_TOKEN}"
      if [ -z "$CF_TOKEN" ]; then
        read -rp "Enter your Cloudflare API token: " CF_TOKEN
        if [ -z "$CF_TOKEN" ]; then
          err "Cloudflare API token is required. Aborting."; return
        fi
      fi

      local tunnel_name="${ARG_TUNNEL_NAME}"
      if [ -z "$tunnel_name" ]; then
        read -rp "Enter a tunnel name (e.g. alvin-office): " tunnel_name
        if [ -z "$tunnel_name" ]; then
          err "Tunnel name is required. Aborting."; return
        fi
      fi

      if ! setup_tunnel "$tunnel_name"; then
        err "Tunnel setup failed. Aborting."; return
      fi

      API_KEY="${ARG_API_KEY}"
      if [ -z "$API_KEY" ]; then
        API_KEY="$(generate_api_key)"
        info "  Generated API key: ${API_KEY}"
      fi
      ;;
    *)
      err "Invalid choice. Aborting."; return
      ;;
  esac

  echo ""
  info "--- Step 2/6: Create install directory ---"
  mkdir -p "$INSTALL_DIR"
  echo "  Directory: $INSTALL_DIR"

  echo ""
  info "--- Step 3/6: Download binaries ---"

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
  info "--- Step 4/6: Create configuration ---"
  cat > "${INSTALL_DIR}/.env" <<EOF
API_KEY=${API_KEY}
PORT=9191
EOF
  echo "  Created ${INSTALL_DIR}/.env"

  echo ""
  info "--- Step 5/6: Install launchd services ---"

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
  info "--- Step 6/6: Verify ---"
  warn "Waiting for services to start..."
  sleep 3
  if curl -sf http://localhost:9191/health >/dev/null 2>&1; then
    info "Health check passed!"
  else
    warn "Health check failed — the service may still be starting. Check ${INSTALL_DIR}/proxy.log"
  fi

  echo ""
  cyan "===================================="
  cyan "  Installation Complete!"
  cyan "===================================="
  echo ""
  echo "  Install directory : $INSTALL_DIR"
  echo "  Proxy service     : $PROXY_LABEL"
  echo "  Tunnel service    : $CF_LABEL"
  echo "  Logs              : ${INSTALL_DIR}/proxy.log / cloudflared.log"

  if [ -n "$PROXY_URL" ]; then
    echo ""
    cyan "===================================="
    cyan "  Enter these in Portal > Print Proxy"
    cyan "===================================="
    echo ""
    echo "  Proxy URL : $PROXY_URL"
    echo "  API Key   : $API_KEY"
  fi
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
