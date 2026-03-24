import { homedir, platform, tmpdir, arch } from "os";
import { join } from "path";

export const GH_REPO = "kwtechnologies/kube-printer-proxy";
export const CF_DOMAIN = "kwtech.dev";
export const CF_API_BASE = "https://api.cloudflare.com/client/v4";

export const isWindows = platform() === "win32";
export const isMac = platform() === "darwin";

export const INSTALL_DIR = isWindows
  ? "C:\\printer-proxy"
  : "/usr/local/printer-proxy";

export const SERVICE_PROXY_NAME = isWindows
  ? "PrinterProxy"
  : "com.kwtech.printer-proxy";
export const SERVICE_CF_NAME = isWindows
  ? "CloudflaredTunnel"
  : "com.kwtech.cloudflared-tunnel";

export function getProxyPlistPath(): string {
  return join(homedir(), "Library", "LaunchAgents", `${SERVICE_PROXY_NAME}.plist`);
}

export function getCfPlistPath(): string {
  return join(homedir(), "Library", "LaunchAgents", `${SERVICE_CF_NAME}.plist`);
}

export function getTmpDir(): string {
  return tmpdir();
}

export function detectArch(): "amd64" | "arm64" {
  const a = arch();
  if (a === "arm64") return "arm64";
  if (a === "x64" || a === "x86_64") return "amd64";
  throw new Error(`Unsupported architecture: ${a}`);
}
