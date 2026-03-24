# Future Platform Support: Windows ARM64 & Linux

## Windows ARM64

| Layer | Effort | Detail |
|-------|--------|--------|
| Go proxy binary | Trivial | Add one line to CI: `GOOS=windows GOARCH=arm64 go build ... -o printer-proxy-windows-arm64.exe` |
| Bun installer binary | Not possible yet | Bun doesn't offer a `bun-windows-arm64` compile target. The x64 `.exe` runs via Windows' built-in x86 emulation layer, so it still works -- just not native. |
| Service code (`service-windows.ts`) | Zero changes | NSSM and service commands are architecture-agnostic. |
| Bootstrap (`setup.ps1`) | Minor | Detect `$env:PROCESSOR_ARCHITECTURE` and download the matching proxy binary. |

**Status**: Works today via x86 emulation. Native ARM64 Bun support is pending on Bun's roadmap.

## Linux (x64 / ARM64)

| Layer | Effort | Detail |
|-------|--------|--------|
| Go proxy binary | Trivial | Add to CI: `GOOS=linux GOARCH=amd64` and `GOARCH=arm64`. |
| Bun installer binary | Trivial | Bun already supports `bun-linux-x64` and `bun-linux-arm64` targets. |
| Service code | New file needed | Create `service-linux.ts` (~80 lines) using `systemd` unit files and `systemctl enable/start/stop` instead of launchd or NSSM. |
| Bootstrap (`setup.sh`) | Minor | Detect `uname -s` (Linux vs Darwin) in addition to `uname -m`, download the correct binary name. |
| cloudflared download | Minor | Different URL pattern: `cloudflared-linux-amd64` (plain binary, no `.tgz`). |

**Status**: Main new work is `service-linux.ts` with systemd support. Everything else is build targets and conditionals.

## Summary

| Platform | New code needed | Blocking issues |
|----------|----------------|-----------------|
| Windows ARM64 | ~5 lines (CI + bootstrap detection) | None (x64 emulation works; native Bun pending) |
| Linux x64/arm64 | ~80 lines (`service-linux.ts`) + minor CI/bootstrap updates | None |
