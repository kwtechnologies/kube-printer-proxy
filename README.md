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
        │
        ▼
  Zebra Printer (HTTP :9100)
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

### 2. Create a Cloudflare Tunnel

1. Go to [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/) → Networks → Tunnels
2. Create a new tunnel and copy the **tunnel token**
3. Add a **Public Hostname** route:
   - Subdomain: e.g. `print`
   - Domain: your domain
   - Service: `http://localhost:9191`

### 3. Tag a release

```bash
git tag v1.0.0
git push origin v1.0.0
```

GitHub Actions will build binaries for Windows (amd64), macOS (amd64 + arm64) and create a release with installer packages for both platforms.

### 4. Configure the API

In the Portal, navigate to **Print Proxy** in the sidebar and enter:
- **Proxy URL**: The Cloudflare Tunnel HTTPS URL (e.g. `https://print.example.com`)
- **API Key**: The shared secret you chose

---

## Quick Install (One-Liner)

Give the client one of these commands. The interactive installer will prompt for the Cloudflare Tunnel Token and API Key.

### macOS / Linux

```bash
curl -fsSL https://github.com/kwtechnologies/kube-printer-proxy/releases/latest/download/install.sh | sudo bash
```

### Windows (PowerShell — run as Administrator)

```powershell
irm https://github.com/kwtechnologies/kube-printer-proxy/releases/latest/download/install.ps1 | iex
```

> The Windows script will auto-elevate to administrator if not already elevated.

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

### Option B: Download zip

1. Download `printer-proxy-installer-windows.zip` from the latest [GitHub Release](../../releases/latest)
2. Extract the zip
3. **Double-click `install.bat`**

### Interactive installer

Both options launch the same interactive installer:

1. Choose option **1) Install**
2. Paste the **Cloudflare Tunnel Token** when prompted
3. Paste the **API Key** when prompted
4. Wait for the health check to pass

The installer will:
- Download `printer-proxy.exe`, `nssm.exe`, and `cloudflared.exe`
- Install both as Windows Services that auto-start on boot
- Create log files at `C:\printer-proxy\proxy.log` and `C:\printer-proxy\cloudflared.log`

### Updating

Run the installer again (either method) and choose option **2) Update**.

### Uninstalling

Run the installer again and choose option **3) Uninstall**, then type `YES` to confirm.

---

## Client Setup (macOS)

### Prerequisites

- macOS 12 or later
- Internet connection

### Option A: One-liner (recommended)

Open Terminal and paste:

```bash
curl -fsSL https://github.com/kwtechnologies/kube-printer-proxy/releases/latest/download/install.sh | sudo bash
```

### Option B: Download zip

1. Download `printer-proxy-installer-macos.zip` from the latest [GitHub Release](../../releases/latest)
2. Extract the zip
3. Run `sudo bash install.sh` in Terminal

### Interactive installer

Both options launch the same interactive installer:

1. Choose option **1) Install**
2. Paste the **Cloudflare Tunnel Token** when prompted
3. Paste the **API Key** when prompted
4. Wait for the health check to pass

The installer will:
- Download `printer-proxy` (correct architecture auto-detected) and `cloudflared`
- Install both as launchd services that auto-start on login
- Create log files at `/usr/local/printer-proxy/proxy.log` and `/usr/local/printer-proxy/cloudflared.log`

### Updating

Run `sudo bash install.sh` (or the one-liner) and choose option **2) Update**.

### Uninstalling

Run the installer and choose option **3) Uninstall**, then type `YES` to confirm.

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `API_KEY` | *(required)* | Shared secret for `X-API-Key` header |
| `PORT` | `9191` | Listen port |
