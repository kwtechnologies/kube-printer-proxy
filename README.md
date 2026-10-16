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
update.sh                  the nightly self-updater (see Updates)
printer-proxy-update.service / .timer   runs update.sh daily at 03:00
```

On the device:

```
/opt/printer-proxy/releases/<tag>/   full copy of each installed bundle
/opt/printer-proxy/current           symlink to the active release
/etc/systemd/system/*.service        copied from the active bundle
/etc/printer-proxy/env               site config; provisioned at image build, never by the bundle
```

**Installed version contract:** `cat /opt/printer-proxy/current/VERSION` (works when the service is down, unlike `/health`). `install.sh` also records the units it installed in `/opt/printer-proxy/units.list`, and disables/removes units a later (or rolled-back-to) bundle no longer ships.

**Ship rule:** every `linux/*.sh`, `*.service` and `*.timer` goes into the bundle, except `build-image.sh`, `package.sh` and `test-*`. Anything else in `linux/` (e.g. `site.env.example`) stays in the repo.

**Shared env file:** both services read the same `/etc/printer-proxy/env` (root:root 0600), so each process can see the other's secrets via its own environment; the services run as separate dynamic users.

Keeping every release as a complete directory (with its own `install.sh`) means rollback is just running `install.sh` from the previous release dir: it repoints `current`, refreshes the units and restarts. `install.sh` is idempotent and must run as root from an extracted bundle. `PREFIX`, `SYSTEMD_DIR` and `SKIP_SYSTEMCTL=1` override paths for testing. `cloudflared` itself is installed from Cloudflare's apt repo, not the bundle.

## Updates

`printer-proxy-update.timer` runs `printer-proxy-update.service` (`/opt/printer-proxy/current/update.sh`) daily at 03:00 device time (Asia/Hong_Kong); `Persistent=true` catches up at boot if the device was off. Both units ship in the bundle and `install.sh` installs them, so a release can change the updater or its schedule.

Each run:

1. Reads `CHANNEL` from `/etc/printer-proxy/env` (default `stable`). `stable` takes GitHub `releases/latest`; `pre` takes the newest release, pre-releases included.
2. If that tag equals `/opt/printer-proxy/current/VERSION`, exits 0. With nothing installed yet, it installs the tag.
3. Downloads `printer-proxy-linux-arm64.tar.gz` and `.sha256`. On a mismatch it aborts with nothing changed.
4. Runs the new bundle's `install.sh`, then polls `http://127.0.0.1:9191/health` for 15s until `version` is the new tag.
5. Success: keeps the current and previous release dirs, prunes older ones. Failure: runs the previous release's `install.sh`, logs `UPDATE FAILED` at error priority and exits non-zero (the unit shows as failed). The bad tag is retried the next night until a newer release replaces it.

Watch or trigger it:

```bash
journalctl -u printer-proxy-update            # past runs
systemctl list-timers printer-proxy-update.timer
sudo systemctl start printer-proxy-update     # run now (blocks until done)
```

A bundle that stops shipping a `.service` unit gets it disabled and removed but not stopped (it stops at the next boot): stopping it could kill the updater that is running `install.sh`. Dropped timers are stopped.

## Development

```bash
go vet ./... && go test ./...
shellcheck linux/*.sh
linux/package.sh v0.0.0-dev dist   # builds the same bundle CI does
linux/test-update.sh               # updater fixture test, in a debian:bookworm container (needs Docker)
```

## Cutting a release

1. Tag a release candidate: `git tag v0.3.0-rc1 && git push origin v0.3.0-rc1`. CI publishes it as a **pre-release**, picked up only by `CHANNEL=pre` devices (the test Pi).
2. Soak on the test Pi. If needed, iterate `-rc2`, ...
3. Tag stable: `git tag v0.3.0 && git push origin v0.3.0`. Prod devices (`CHANNEL=stable`) pick it up on the next nightly update.

## Provisioning a device

_TODO (ticket #4): operator runbook._
