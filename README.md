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

## Quick Install — Automated Tunnel (Recommended)

The installer can create the Cloudflare Tunnel, DNS record, and everything else automatically. All you need is the Cloudflare API token from step 2 above.

### macOS / Linux

```bash
curl -fsSL https://github.com/kwtechnologies/kube-printer-proxy/releases/latest/download/install.sh | bash
```

### Windows (PowerShell)

```powershell
irm https://github.com/kwtechnologies/kube-printer-proxy/releases/latest/download/install.ps1 | iex
```

During install, choose option **(b) Create a new tunnel automatically** and provide:
- **Cloudflare API token** — from step 2
- **Tunnel name** — e.g. `alvin-office` (will create `print-proxy-alvin-office.kwtech.dev`)

The installer will:
1. Create (or reuse) the Cloudflare Tunnel
2. Configure ingress rules (`hostname → http://localhost:9191`)
3. Create a DNS CNAME record (`print-proxy-<name>.kwtech.dev`)
4. Auto-generate a printer proxy API key
5. Download and install `printer-proxy` + `cloudflared` as system services
6. Output the **Proxy URL** and **API Key** to enter in the Portal

### CLI Arguments (non-interactive)

Both scripts accept arguments to skip prompts:

**macOS:**
```bash
curl -fsSL .../install.sh | bash -s -- --tunnel-name alvin-office --cf-token YOUR_TOKEN
```

**Windows:**
```powershell
# Save and run with parameters
irm .../install.ps1 -OutFile install.ps1
.\install.ps1 -TunnelName "alvin-office" -CfToken "YOUR_TOKEN"
```

| Argument (bash) | Argument (PowerShell) | Description |
|------------------|-----------------------|-------------|
| `--tunnel-name`  | `-TunnelName`         | Tunnel name (subdomain: `print-proxy-<name>.kwtech.dev`) |
| `--cf-token`     | `-CfToken`            | Cloudflare API token |
| `--api-key`      | `-ProxyApiKey`        | Printer proxy API key (auto-generated if omitted) |

---

## Quick Install — Manual Token

If you already have a Cloudflare Tunnel token (created manually in the dashboard), choose option **(a) I have a tunnel token already** during install and paste the token + API key when prompted.

---

## Client Setup (macOS)

### Prerequisites

- macOS 12 or later
- Internet connection

### Option A: One-liner (recommended)

```bash
curl -fsSL https://github.com/kwtechnologies/kube-printer-proxy/releases/latest/download/install.sh | bash
```

### Option B: Download zip

1. Download `printer-proxy-installer-macos.zip` from the latest [GitHub Release](../../releases/latest)
2. Extract the zip
3. Run `sudo bash install.sh` in Terminal

### Installed components

- Binary + config: `/usr/local/printer-proxy/`
- Services: `com.kwtech.printer-proxy`, `com.kwtech.cloudflared-tunnel` (launchd)
- Logs: `/usr/local/printer-proxy/proxy.log` and `cloudflared.log`

### Updating

Run the installer and choose **2) Update**.

### Uninstalling

Run the installer and choose **3) Uninstall**, then type `YES` to confirm.

---

## Client Setup (Windows)

### Prerequisites

- Windows 10 or later
- Internet connection

### Option A: One-liner (recommended)

Open PowerShell and paste:

```powershell
irm https://github.com/kwtechnologies/kube-printer-proxy/releases/latest/download/install.ps1 | iex
```

> The script will auto-elevate to administrator if not already elevated.

### Option B: Download zip

1. Download `printer-proxy-installer-windows.zip` from the latest [GitHub Release](../../releases/latest)
2. Extract the zip
3. **Double-click `install.bat`**

### Installed components

- Binary + config: `C:\printer-proxy\`
- Services: `PrinterProxy`, `CloudflaredTunnel` (Windows Services via NSSM)
- Logs: `C:\printer-proxy\proxy.log` and `cloudflared.log`

### Updating

Run the installer and choose **2) Update**.

### Uninstalling

Run the installer and choose **3) Uninstall**, then type `YES` to confirm.

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `API_KEY` | *(required)* | Shared secret for `X-API-Key` header |
| `PORT` | `9191` | Listen port |
