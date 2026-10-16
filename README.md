# Printer Proxy

A minimal Go HTTP server that relays ZPL print jobs from HTTPS web apps to local-network Zebra printers, solving the browser mixed-content restriction. Runs as a Linux appliance (Orange Pi Zero 3, linux/arm64). Design: see the issue "Linux appliance on Orange Pi Zero 3" and `docs/adr/`.

## Architecture

```
Portal / Handheld (HTTPS)
        │
        ▼
  Cloudflare Tunnel (cloudflared, token from /etc/printer-proxy/env)
        │
        ▼
  printer-proxy (:9191)
        │  raw TCP :9100
        ▼
  Zebra Printer
```

## API

| Endpoint  | Method | Auth        | Description              |
|-----------|--------|-------------|--------------------------|
| `/print`  | POST   | `X-API-Key` | Forward ZPL to a printer |
| `/health` | GET    | none        | `{"status":"ok","version":"<tag>"}` |

### POST /print

```json
{ "ip": "10.5.20.10", "zpl": "^XA^FO50,50^A0N,40,40^FDHello^FS^XZ" }
```

Headers: `Content-Type: application/json`, `X-API-Key: <key>`. Returns `200 {"status":"ok"}`. Target IP must be a private/LAN address (SSRF protection).

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `API_KEY` | *(required)* | Shared secret for the `X-API-Key` header |
| `PORT` | `9191` | Listen port |

On the device these come from `/etc/printer-proxy/env` (see `linux/site.env.example`).

## Bundle layout

A release is one asset, `printer-proxy-linux-arm64.tar.gz` (plus `.sha256`), extracting flat to:

```
printer-proxy              binary (version baked in with -ldflags)
VERSION                    the release tag
install.sh                 the one install path
printer-proxy.service      DynamicUser, EnvironmentFile=/etc/printer-proxy/env
cloudflared-tunnel.service cloudflared tunnel --no-autoupdate run (TUNNEL_TOKEN from env file)
```

On the device:

```
/opt/printer-proxy/releases/<tag>/   full copy of each installed bundle
/opt/printer-proxy/current           symlink to the active release
/etc/systemd/system/*.service        copied from the active bundle
/etc/printer-proxy/env               site config; provisioned at image build, never by the bundle
```

Keeping every release as a complete directory (with its own `install.sh`) means rollback is just running `install.sh` from the previous release dir: it repoints `current`, refreshes the units and restarts. `install.sh` is idempotent and must run as root from an extracted bundle. `PREFIX`, `SYSTEMD_DIR` and `SKIP_SYSTEMCTL=1` override paths for testing. `cloudflared` itself is installed from Cloudflare's apt repo, not the bundle.

## Development

```bash
go vet ./... && go test ./...
shellcheck linux/*.sh
linux/package.sh v0.0.0-dev dist   # builds the same bundle CI does
```

## Cutting a release

1. Tag a release candidate: `git tag v0.3.0-rc1 && git push origin v0.3.0-rc1`. CI publishes it as a **pre-release**, picked up only by `CHANNEL=pre` devices (the test Pi).
2. Soak on the test Pi. If needed, iterate `-rc2`, ...
3. Tag stable: `git tag v0.3.0 && git push origin v0.3.0`. Prod devices (`CHANNEL=stable`) pick it up on the next nightly update.

## Provisioning a device

_TODO (ticket #4): operator runbook._
