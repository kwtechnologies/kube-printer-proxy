# Printer Proxy

A minimal Go HTTP server that relays ZPL print jobs from HTTPS web apps to local network Zebra printers, solving the browser mixed-content restriction.

## Architecture

```
Portal / Handheld (HTTPS)
        │
        ▼
  Cloudflare Tunnel (HTTPS → localhost)
        │
        ▼
  printer-proxy (:9191)
        │  raw TCP :9100
        ▼
  Zebra Printer
```

## API

| Endpoint      | Method | Auth          | Description                |
|---------------|--------|---------------|----------------------------|
| `/print`      | POST   | `X-API-Key`   | Forward ZPL to a printer   |
| `/health`     | GET    | none          | Health check               |

### POST /print

```json
{
  "ip": "192.168.1.100",
  "zpl": "^XA^FO50,50^A0N,40,40^FDHello^FS^XZ"
}
```

Headers: `Content-Type: application/json`, `X-API-Key: <your-key>`

Returns `200 {"status":"ok"}` on success. Target IP must be a private/LAN address (SSRF protection).

---

## Developer Setup

### 1. Build locally (optional)

```bash
cd packages/printer-proxy
go build -o printer-proxy
```

### 2. Create a Cloudflare API token (one-time)

Go to [Cloudflare Dashboard → API Tokens](https://dash.cloudflare.com/profile/api-tokens) and create a token with:

| Scope   | Resource          | Permission |
|---------|-------------------|------------|
| Account | Cloudflare Tunnel | Edit       |
| Zone    | DNS               | Edit       |

Save this token securely — it will be used by the installer to create tunnels automatically.

### 3. Tag a release

```bash
git tag v1.0.0
git push origin v1.0.0
```

GitHub Actions will build binaries for Windows (amd64), macOS (amd64 + arm64) and create a release with installer packages for both platforms.

### 4. Configure the Portal

After running the installer on a client machine (see below), it will output a **Proxy URL** and **API Key**. Enter these in the Portal under **Print Proxy** in the sidebar.

---

## Quick Install (Recommended)

The interactive installer handles everything: Cloudflare Tunnel creation, DNS setup, binary downloads, and service installation. All you need is the Cloudflare API token from step 2 above.

### macOS

```bash
curl -fsSL https://github.com/kwtechnologies/kube-printer-proxy/releases/latest/download/setup.sh | bash
```

### Windows (PowerShell)

```powershell
irm https://github.com/kwtechnologies/kube-printer-proxy/releases/latest/download/setup.ps1 | iex
```

The installer will guide you through:
1. Choosing **Install**, **Update**, or **Uninstall**
2. Creating (or reusing) a Cloudflare Tunnel
3. Configuring DNS and ingress automatically
4. Downloading and installing all services
5. Displaying the **Proxy URL** and **API Key** to enter in Portal

### What you'll need during install

- **Cloudflare API token** -- from step 2
- **Tunnel name** -- e.g. `alvin-office` (creates `print-proxy-alvin-office.kwtech.dev`)

### Installed components

**macOS:**
- Binary + config: `/usr/local/printer-proxy/`
- Services: `com.kwtech.printer-proxy`, `com.kwtech.cloudflared-tunnel` (launchd)
- Logs: `/usr/local/printer-proxy/proxy.log` and `cloudflared.log`

**Windows:**
- Binary + config: `C:\printer-proxy\`
- Services: `PrinterProxy`, `CloudflaredTunnel` (Windows Services via NSSM)
- Logs: `C:\printer-proxy\proxy.log` and `cloudflared.log`

---

## Legacy Install Scripts

The original bash/PowerShell installer scripts are still available as a backup:

**macOS:** `curl -fsSL .../install.sh | bash`
**Windows:** `irm .../install.ps1 | iex`

These support CLI arguments for non-interactive use (`--tunnel-name`, `--cf-token`, `--api-key`).
See previous versions of this README for full documentation.

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `API_KEY` | *(required)* | Shared secret for `X-API-Key` header |
| `PORT` | `9191` | Listen port |
