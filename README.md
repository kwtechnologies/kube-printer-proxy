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

**Ship rule:** every `linux/*.sh`, `*.service` and `*.timer` goes into the bundle, except `build-image.sh`, `package.sh` and `test-*`. Anything else in `linux/` (e.g. `site.env.example`, and `linux/image/`, which `build-image.sh` bakes into the SD image) stays in the repo.

**Shared env file:** both services read the same `/etc/printer-proxy/env` (root:root 0600), so each process can see the other's secrets via its own environment; the services run as separate dynamic users.

Keeping every release as a complete directory (with its own `install.sh`) means rollback is just running `install.sh` from the previous release dir: it repoints `current`, refreshes the units and restarts. `install.sh` is idempotent and must run as root from an extracted bundle. `PREFIX`, `SYSTEMD_DIR` and `SKIP_SYSTEMCTL=1` override paths for testing. `cloudflared` itself is installed from Cloudflare's apt repo, not the bundle.

## Updates

`printer-proxy-update.timer` runs `printer-proxy-update.service` (`/opt/printer-proxy/current/update.sh`) daily at 03:00 device time (Asia/Hong_Kong); `Persistent=true` catches up at boot if the device was off. Both units ship in the bundle and `install.sh` installs them, so a release can change the updater or its schedule.

Each run:

0. If the previous run was killed (power loss, timeout) between installing and the health verdict, `/opt/printer-proxy/rollback-to` is still there. If the half-installed tag is still current and does not come up healthy, it rolls back to the previous release and exits non-zero, before anything else. A marker that no longer matches `current`, or whose tag is healthy after all, is dropped. Once the rollback's `install.sh` succeeds the marker is gone even if the previous release is unhealthy too, so a newer release can still install the next night.
1. Reads `CHANNEL` from `/etc/printer-proxy/env` (default `stable`, also when the file is missing). `stable` takes GitHub `releases/latest`; `pre` takes the newest release, pre-releases included. Switching a device from `pre` back to `stable` is intended to downgrade it to the latest stable on the next run, since the updater installs whatever the channel names, not only newer tags.
2. If that tag equals `/opt/printer-proxy/current/VERSION`, exits 0. With nothing installed yet, it installs the tag.
3. Downloads `printer-proxy-linux-arm64.tar.gz` and `.sha256` into `/opt/printer-proxy/.update.*` (not `/tmp`). On a mismatch it aborts with nothing changed.
4. Runs the new bundle's `install.sh`, then polls `http://127.0.0.1:9191/health` for 15s until `version` is the new tag.
5. Success: keeps the current and previous release dirs, prunes older ones. Failure: runs the previous release's `install.sh`, deletes the failed release dir, logs `UPDATE FAILED` at error priority and exits non-zero (the unit shows as failed). The bad tag is retried the next night until a newer release replaces it.

Watch or trigger it:

```bash
journalctl -u printer-proxy-update            # past runs
systemctl list-timers printer-proxy-update.timer
sudo systemctl start printer-proxy-update     # run now (blocks until done)
```

A bundle that stops shipping a `.service` unit gets it disabled and removed but not stopped (it stops at the next boot): stopping it could kill the updater that is running `install.sh`. Dropped timers are stopped. The same applies after a rollback: a service that only the failed release shipped is disabled but keeps running until the next reboot.

The unit has `TimeoutStartSec=15min` and is sandboxed (`ProtectSystem=strict` with write access only to `/opt/printer-proxy`, `/etc/systemd/system` and `/etc/printer-proxy`), so a bundle's `install.sh` must not write anywhere else.

## Development

```bash
go vet ./... && go test ./...
shellcheck linux/*.sh linux/image/*.sh
linux/package.sh v0.0.0-dev dist   # builds the same bundle CI does
linux/test-update.sh               # updater fixture test, in a debian:bookworm container (needs Docker)
linux/test-image.sh                # SD image build + check + first-boot test (Docker on an arm64 Mac, internet)
```

## Cutting a release

1. Tag a release candidate: `git tag v0.3.0-rc1 && git push origin v0.3.0-rc1`. CI publishes it as a **pre-release**, picked up only by `CHANNEL=pre` devices.
2. Soak it on a `CHANNEL=pre` device, if one exists (see the runbook's Releases step). If needed, iterate `-rc2`, ...
3. Tag stable: `git tag v0.3.0 && git push origin v0.3.0`. Prod devices (`CHANNEL=stable`) pick it up on the next nightly update.

## Provisioning a device

One SD card per device, built on the dev Mac. The card boots straight into the print proxy: no keyboard, SSH or script on site.

### What the image contains

`linux/build-image.sh <env-file> [armbian-image]` takes the Armbian image (default: downloads the pinned one and checks its sha256), and in a privileged `debian:bookworm` container (the image is one ext4 partition macOS can't write) adds:

```
/etc/printer-proxy/env                               the site env file, root:root 0600
/usr/local/lib/printer-proxy/firstboot.sh, update.sh first boot + the updater it runs
/etc/systemd/system/printer-proxy-firstboot.service  enabled oneshot
/etc/ssh/sshd_config.d/10-printer-proxy.conf         key-only, no root login
```

and removes Armbian's first-login wizard trigger: `/root/.not_logged_in_yet` (`/etc/profile.d/armbian-check-first-login.sh` only runs `armbian-firstlogin` while it exists) and the `getty@`/`serial-getty@` root-autologin overrides that exist to reach it. Armbian's own preset mechanism (`PRESET_*` in `.not_logged_in_yet`) is not used: it runs from that root console autologin and its network presets cannot express Ethernet-preferred with Wi-Fi fallback. It also locks root's password in `/etc/shadow` (what `passwd -l` does), so Armbian's public default root password never works.

`build-image.sh` refuses to build when:

- the env file breaks the format, misses a required key, has a key that `ssh-keygen -l` can't read, or Wi-Fi values netplan would reject (SSID 1-32 bytes, password 8-63 printable ASCII, `WIFI_COUNTRY` two capital letters);
- the release the env's `CHANNEL` resolves to (the same GitHub lookup `update.sh` does) has no `printer-proxy-linux-arm64.tar.gz`, because first boot could never finish (`ALLOW_NO_RELEASE=1` overrides, for tests);
- the image's sha256 doesn't match, it isn't `BOARD=orangepizero3`, or it isn't Debian `$EXPECTED_CODENAME` (default `bookworm`).

The image is written as `.part` and renamed only on success.

Output is `./printer-proxy-<env name>.img` (override with `OUT=`). It holds the site's secrets: flash it, then delete it. `*.img` and `*.env` are gitignored.

**Base image:** Armbian 25.5.1, Debian 12 bookworm, minimal, kernel 6.12 (`Armbian_25.5.1_Orangepizero3_bookworm_current_6.12.23_minimal.img.xz`). armbian.com no longer lists bookworm for the Zero 3 (it is a community board now, offering only trixie rolling builds), so it comes from the Armbian archive (`https://fi.mirror.armbian.de/archive/orangepizero3/archive/`). The sha256 pinned in `build-image.sh` is Armbian's `.sha`; the `.asc` signature verifies against Armbian's key `DF00FAF1C577104B50BF1D0093D6889F9F0E78D5`. To use another image, pass it as the second argument with `ARMBIAN_SHA256=<sha256>` (and `EXPECTED_CODENAME=trixie` for a trixie one).

**The kernel and Armbian BSP are frozen** at what the image shipped (kernel 6.12.23 for the pinned image): unattended-upgrades deliberately excludes the Armbian repo, so only a reflash patches them. Plan a periodic reflash (and note bookworm itself has been on Debian LTS since June 2026).

### First boot

`printer-proxy-firstboot.service` runs `firstboot.sh` until it succeeds once, then `/var/lib/printer-proxy/firstboot.done` stops it running again. Every step is idempotent; a failed run (no internet, no release yet) is retried every 2 minutes and on every boot. Progress: `journalctl -u printer-proxy-firstboot`.

1. Hostname (`DEVICE_HOSTNAME`, default `printer-proxy`), timezone `Asia/Hong_Kong`.
2. User `kube` with `SSH_AUTHORIZED_KEYS`, passwordless sudo, no password; root password locked.
3. Network: Armbian minimal uses netplan with systemd-networkd (no NetworkManager) and ships `wpasupplicant`. `/etc/netplan/20-printer-proxy.yaml` gives Ethernet (`e*`) DHCP with route metric 100 and, if `WIFI_SSID` is set, `wlan0` DHCP with metric 600: Ethernet wins whenever it has a lease. Both links are `optional`, so boot doesn't wait on whichever one is absent. If netplan rejects the Wi-Fi values anyway, first boot logs a warning and carries on Ethernet-only. `netplan apply` runs only when the file changed, so retries don't bounce the links.
4. Waits (up to 10 min per attempt) until `https://pkg.cloudflare.com` answers. This also waits out the clock: the board has no RTC, so TLS fails until NTP syncs.
5. Adds Cloudflare's apt repo, installs `cloudflared` and `unattended-upgrades`. `/etc/apt/apt.conf.d/52printer-proxy` replaces Armbian's and Debian's origin lists (Armbian's would upgrade its kernel/BSP packages) with Debian security + cloudflared only, runs daily, and restarts the tunnel only when a dpkg run upgraded cloudflared (its binary is newer than the running process), so upgrades of other packages never drop the tunnel. No dist-upgrades. A failing apt source (Armbian may drop its bookworm suite) only warns; apt waits up to 5 min for the dpkg lock (`armbian-firstrun` reconfigures openssh at the same time).
6. Installs the bundle by running the baked `update.sh` with `CHANNEL` from the env file. **Why baked, not fetched:** `update.sh` with nothing installed already does the first install (download, sha256, `install.sh`, `/health` check), so baking it avoids duplicating release lookup in `firstboot.sh`. It runs directly, not via `printer-proxy-update.service`, whose sandbox is meant for nightly runs. From then on the nightly timer runs the bundle's own `update.sh`.

### Runbook

Dashboard steps are manual. Hostnames below are the Kube office ones.

**One tunnel per device.** Cloudflare spreads a tunnel's traffic across all of its connectors, so a second connector anywhere else (a spare board, the old Windows box) would receive a share of real print jobs and fail them. A new device gets a new tunnel, and the cutover is a change of the URL that kube-api-v2 calls, never a second connector on a live tunnel.

0. **Before you flash: a release with the bundle must exist** for the channel the env file uses. A card flashed without one never finishes first boot, and the tunnel is only started by its last step, so the device is unreachable except over the LAN. Check:

   ```bash
   gh release view -R kwtechnologies/kube-printer-proxy --json tagName,assets -q '.tagName, .assets[].name'   # CHANNEL=stable: latest release
   gh release list -R kwtechnologies/kube-printer-proxy -L 1                                                   # CHANNEL=pre: newest, then view that tag
   ```

   The list must include `printer-proxy-linux-arm64.tar.gz`. `build-image.sh` does the same check and refuses otherwise.
1. **Tunnel.** Zero Trust → Networks → Tunnels → create a Cloudflared tunnel named after the device (e.g. `print-proxy-kube-office-pi`), skip installing a connector, and add a public hostname `print-proxy-kube-office-pi.kwtech.dev` → service HTTP `localhost:9191`. Put its token (the long string after `--token`) in the device's env file as `TUNNEL_TOKEN`, with a fresh `API_KEY` (`openssl rand -hex 32`). The token never leaves the device; kube-api-v2 only ever gets the URL and the `API_KEY`.
2. **SSH rescue.** On the same tunnel add a second public hostname (e.g. `ssh-print-proxy-kube-office-pi.kwtech.dev`) → service `ssh://localhost:22`, and a Zero Trust Access self-hosted application on that hostname allowing only kwtech staff. Then on your machine (with `cloudflared` installed):

   ```
   Host ssh-print-proxy-*.kwtech.dev
     User kube
     IdentityFile ~/.ssh/kwtech
     ProxyCommand cloudflared access ssh --hostname %h
   ```

3. **Alerts.** Cloudflare dashboard → Notifications → add a Tunnel Health alert for the tunnel, emailing the team.
4. **Build, flash, boot, verify at your desk.** The device can be set up anywhere with internet: on its own tunnel it serves no real traffic until step 7.

   ```bash
   # the env file lives in the password manager, never committed
   linux/build-image.sh office.env                                  # -> printer-proxy-office.img (prints the tag first boot will install)
   linux/test-image.sh --check printer-proxy-office.img office.env  # optional: assert what was baked
   ```

   Flash the `.img` with balenaEtcher (validation on), delete the `.img`, insert the card fully, connect Ethernet and power. First boot takes about 5 minutes (filesystem resize, apt). Then run the hardware checklist below. To test printing without a printer, let your laptop on the same LAN play one:

   ```bash
   nc -l 9100                                                       # on the laptop: prints whatever arrives
   curl -s -X POST https://print-proxy-kube-office-pi.kwtech.dev/print -H "X-API-Key: $API_KEY" \
     -H 'Content-Type: application/json' -d '{"ip":"<laptop LAN IP>","zpl":"^XA^FDhello^FS^XZ"}'
   ```

   `{"status":"ok"}` and the ZPL appearing in `nc` prove internet → tunnel → proxy → TCP 9100.
5. **Optionally rehearse the switch** from the real API, with a quiet moment and an ADMIN JWT: save the current `GET /print-proxy-config` (url and apiKey), `PUT /print-proxy-config` with the new URL and key, check `GET /print-jobs/proxy-health` reports the device's version, then `PUT` the saved values back. Scripted, prod points at the device for about a second; any print in that window would go to the device instead.
6. **On site.** Plug the device into Ethernet on the printers' network and power it. Over SSH: set `CHANNEL=stable` and the site's Wi-Fi (or none) as in [Changing a deployed device's config](#changing-a-deployed-devices-config), then check `ip route get <printer IP>` says the Ethernet interface (`end0` on the Zero 3) and `nc -zv <printer IP> 9100` connects.
7. **Cutover.** Portal → Print Proxy: set the URL to `https://print-proxy-kube-office-pi.kwtech.dev` and the API key to the device's `API_KEY`. kube-api-v2 reads the config on every print, so it takes effect at once. Print from the portal and a handheld; `journalctl -u printer-proxy` on the device shows the requests. **Rollback:** put the old URL and key back (keep them in the password manager); the old proxy keeps running on its own tunnel until you retire it.
8. **Retire the old proxy** after about a week without rollback: power it off, then delete its tunnel, Access application and Tunnel Health alert.
9. **Releases.** See [Cutting a release](#cutting-a-release). With one device on `CHANNEL=stable` there is no soak device: a stable tag reaches it the next night, so run `linux/test-update.sh` and `linux/test-image.sh` first. A spare board on its own tunnel with `CHANNEL=pre` brings the soak step back.

### Changing a deployed device's config

The env file is read at runtime, so most changes need no reflash. As `kube` over SSH, edit `/etc/printer-proxy/env` with `sudo` (one `KEY=value` per line, no quotes; `build-image.sh` validates values but an edit here is not checked), then:

| Changed | Apply with |
|---|---|
| `CHANNEL` | nothing; the next nightly update uses it |
| `TUNNEL_TOKEN`, `API_KEY` | `sudo systemctl restart cloudflared-tunnel printer-proxy` |
| `WIFI_SSID`, `WIFI_PASSWORD`, `WIFI_COUNTRY`, `DEVICE_HOSTNAME`, `SSH_AUTHORIZED_KEYS` | `sudo /usr/local/lib/printer-proxy/firstboot.sh` (idempotent: rewrites netplan and applies it only if it changed, re-checks the user and apt setup, then runs the updater once, like a nightly run; tag a stable release before setting `CHANNEL=stable`, or that last step fails harmlessly) |

Change Wi-Fi only while the device is on Ethernet: the old Wi-Fi link drops when netplan applies, and a typo leaves Wi-Fi down (a value netplan rejects makes first boot fall back to Ethernet-only). Reflash instead when the card is suspect, or to bring in a fix to the files first boot writes (the apt hook, sshd drop-in, netplan template): nightly updates replace the bundle, not those.

### Hardware boot checklist (real Zero 3)

Run before deploying, at your desk. SSH in through the Access hostname as `kube`. Until first boot has finished there is no tunnel: use the LAN instead, `ssh kube@<IP from the router's DHCP table>` (the `kube` user exists from the second step of first boot), then `journalctl -u printer-proxy-firstboot`. Root and `kube` have no usable password, so console login is impossible: if SSH doesn't work either, reflashing is the only recovery.

- [ ] HDMI or serial console (ttyS0, 115200) shows a plain login prompt: no Armbian wizard, no root autologin.
- [ ] `systemctl status printer-proxy-firstboot` succeeded; `journalctl -u printer-proxy-firstboot` ends with `firstboot: done`.
- [ ] `curl -s https://<tunnel hostname>/health` returns `{"status":"ok","version":"<tag>"}`; `cat /opt/printer-proxy/current/VERSION` matches.
- [ ] `ssh <ssh hostname>` works as `kube`; `sudo -n true` works; `ssh root@...` and password logins are refused; `sudo passwd -S root` shows `L`.
- [ ] `hostname` and `timedatectl` show the hostname and `Asia/Hong_Kong`; `systemctl list-timers` shows `printer-proxy-update.timer` at 03:00 and the apt timers.
- [ ] `ip link` shows `wlan0` (the netplan file assumes that name), and `ip route` shows default via the Ethernet interface with metric 100 (and via `wlan0` with metric 600 if Wi-Fi is set).
- [ ] With both links up, `ip route get 10.5.20.x` (a printer) says `dev <the Ethernet interface>`, not `wlan0`. The metric is only proven for the default route; this checks the printers' subnet route too.
- [ ] Wi-Fi fallback: unplug Ethernet, `/health` through the tunnel still answers within a minute; plug it back and the default route returns to Ethernet.
- [ ] Bad Wi-Fi: flash a card whose Wi-Fi password is valid-looking but wrong. First boot still completes over Ethernet, and Ethernet keeps working. (Values netplan would reject never get this far: `build-image.sh` refuses them, and first boot falls back to Ethernet-only.)
- [ ] From the Pi, `nc -zv 10.5.20.x 9100` reaches the printers; a test print from the portal comes out.
- [ ] The tunnel token is not in the journal: `sudo journalctl -b | grep -c "$(sudo sed -n 's/^TUNNEL_TOKEN=//p' /etc/printer-proxy/env)"` prints `0`.
- [ ] `df -h /` shows the whole card (Armbian resized the root filesystem).
- [ ] `sudo unattended-upgrade --dry-run -d 2>&1 | grep 'Allowed origins'` lists only Debian-Security and cloudflared.
- [ ] Reboot: everything comes back; first boot is skipped (`systemctl status printer-proxy-firstboot` shows the condition unmet).
- [ ] Retry: on a freshly flashed card, pull power during first boot (e.g. while apt runs), power on again; first boot still completes.
