import { execSync } from "child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "fs";
import { join } from "path";

import { downloadFile } from "./download.js";
import { GH_REPO, INSTALL_DIR } from "./config.js";

const SERVICE_NAME = "PrinterProxy";
const CF_SERVICE_NAME = "CloudflaredTunnel";

const NSSM_URL =
  "https://github.com/dkxce/NSSM/releases/download/v2.25/NSSM_v2.25.zip";
const NSSM_URL_FALLBACK = "https://nssm.cc/release/nssm-2.24.zip";
const CF_URL =
  "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe";

function nssm(): string {
  return join(INSTALL_DIR, "nssm.exe");
}

function exec(cmd: string): void {
  execSync(cmd, { stdio: "ignore", windowsHide: true });
}

function execOutput(cmd: string): string {
  return execSync(cmd, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
  }).trim();
}

function findFileRecursive(
  dir: string,
  name: string,
  match?: string,
): string | null {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      const found = findFileRecursive(full, name, match);
      if (found) return found;
    } else if (entry.name === name && (!match || full.includes(match))) {
      return full;
    }
  }
  return null;
}

function parseEnvValue(content: string, key: string): string | null {
  for (const rawLine of content.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;

    const idx = line.indexOf("=");
    if (idx === -1) continue;

    if (line.slice(0, idx).trim() === key) {
      return line.slice(idx + 1).trim();
    }
  }

  return null;
}

function getRegistryValue(serviceName: string, valueName: string): string | null {
  try {
    const out = execOutput(
      `reg query "HKLM\\SYSTEM\\CurrentControlSet\\Services\\${serviceName}\\Parameters" /v ${valueName}`,
    );
    const line = out
      .split(/\r?\n/)
      .map((entry) => entry.trim())
      .find((entry) => entry.startsWith(valueName));

    if (!line) return null;

    const parts = line.split(/\s{2,}/);
    return parts.length >= 3 ? parts.slice(2).join("  ").trim() : null;
  } catch {
    return null;
  }
}

function getExistingApiKey(): string | null {
  const envPath = join(INSTALL_DIR, ".env");
  if (existsSync(envPath)) {
    const apiKey = parseEnvValue(readFileSync(envPath, "utf8"), "API_KEY");
    if (apiKey) return apiKey;
  }

  const envExtra = getRegistryValue(SERVICE_NAME, "AppEnvironmentExtra");
  if (!envExtra) return null;

  const match = envExtra.match(/API_KEY=([^\s]+)/);
  return match?.[1] ?? null;
}

function getExistingTunnelToken(): string | null {
  let params = getRegistryValue(CF_SERVICE_NAME, "AppParameters");
  if (!params && existsSync(nssm())) {
    try {
      params = execOutput(`"${nssm()}" get "${CF_SERVICE_NAME}" AppParameters`);
    } catch {
      params = null;
    }
  }

  if (!params) return null;

  const match = params.match(/--token\s+("?)([^"\s]+)\1/);
  return match?.[2] ?? null;
}

async function getReleaseAssetUrl(name: string): Promise<string> {
  const releaseRes = await fetch(
    `https://api.github.com/repos/${GH_REPO}/releases/latest`,
  );
  const release = (await releaseRes.json()) as {
    assets: { name: string; browser_download_url: string }[];
  };
  const asset = release.assets.find((entry) => entry.name === name);
  if (!asset) throw new Error(`${name} not found in release.`);
  return asset.browser_download_url;
}

async function ensureNssm(onStatus: (msg: string) => void): Promise<void> {
  onStatus("Downloading NSSM...");
  const nssmZip = join(process.env.TEMP || INSTALL_DIR, "nssm.zip");
  try {
    await downloadFile(NSSM_URL, nssmZip);
  } catch {
    await downloadFile(NSSM_URL_FALLBACK, nssmZip);
  }

  const nssmExtractDir = join(process.env.TEMP || INSTALL_DIR, "nssm");
  mkdirSync(nssmExtractDir, { recursive: true });
  exec(
    `powershell -NoProfile -Command "Expand-Archive -Path '${nssmZip}' -DestinationPath '${nssmExtractDir}' -Force"`,
  );
  const nssmExe = findFileRecursive(nssmExtractDir, "nssm.exe", "win64");
  if (!nssmExe) throw new Error("Could not find nssm.exe in archive.");
  copyFileSync(nssmExe, nssm());
}

async function downloadProxyBinary(
  onStatus: (msg: string) => void,
): Promise<void> {
  onStatus("Downloading printer-proxy.exe...");
  await downloadFile(
    await getReleaseAssetUrl("printer-proxy.exe"),
    join(INSTALL_DIR, "printer-proxy.exe"),
  );
}

async function downloadCloudflared(
  onStatus: (msg: string) => void,
): Promise<void> {
  onStatus("Downloading cloudflared.exe...");
  await downloadFile(CF_URL, join(INSTALL_DIR, "cloudflared.exe"));
}

function stopAndRemoveService(name: string): void {
  try {
    exec(`"${nssm()}" stop "${name}"`);
  } catch {}
  try {
    exec(`"${nssm()}" remove "${name}" confirm`);
  } catch {}
}

export async function installServices(
  apiKey: string,
  tunnelToken: string,
  onStatus: (msg: string) => void,
): Promise<void> {
  onStatus("Creating install directory...");
  mkdirSync(INSTALL_DIR, { recursive: true });

  onStatus("Stopping existing Windows services...");
  stopAndRemoveService(SERVICE_NAME);
  stopAndRemoveService(CF_SERVICE_NAME);

  await downloadProxyBinary(onStatus);
  await ensureNssm(onStatus);
  await downloadCloudflared(onStatus);

  onStatus("Writing configuration...");
  writeFileSync(
    join(INSTALL_DIR, ".env"),
    `API_KEY=${apiKey}\r\nPORT=9191\r\n`,
  );

  onStatus("Installing Windows services...");
  const proxyExe = join(INSTALL_DIR, "printer-proxy.exe");
  exec(`"${nssm()}" install ${SERVICE_NAME} "${proxyExe}"`);
  exec(`"${nssm()}" set ${SERVICE_NAME} AppDirectory "${INSTALL_DIR}"`);
  exec(
    `"${nssm()}" set ${SERVICE_NAME} AppEnvironmentExtra "+API_KEY=${apiKey}" "+PORT=9191"`,
  );
  exec(`"${nssm()}" set ${SERVICE_NAME} DisplayName "Printer Proxy"`);
  exec(
    `"${nssm()}" set ${SERVICE_NAME} Description "Local ZPL print relay for Kube"`,
  );
  exec(`"${nssm()}" set ${SERVICE_NAME} Start SERVICE_AUTO_START`);
  exec(
    `"${nssm()}" set ${SERVICE_NAME} AppStdout "${join(INSTALL_DIR, "proxy.log")}"`,
  );
  exec(
    `"${nssm()}" set ${SERVICE_NAME} AppStderr "${join(INSTALL_DIR, "proxy.log")}"`,
  );
  exec(`"${nssm()}" start ${SERVICE_NAME}`);

  const cfExe = join(INSTALL_DIR, "cloudflared.exe");
  exec(
    `"${nssm()}" install ${CF_SERVICE_NAME} "${cfExe}" "tunnel run --token ${tunnelToken}"`,
  );
  exec(`"${nssm()}" set ${CF_SERVICE_NAME} DisplayName "Cloudflared Tunnel"`);
  exec(
    `"${nssm()}" set ${CF_SERVICE_NAME} Description "Cloudflare tunnel for Printer Proxy"`,
  );
  exec(`"${nssm()}" set ${CF_SERVICE_NAME} Start SERVICE_AUTO_START`);
  exec(
    `"${nssm()}" set ${CF_SERVICE_NAME} AppStdout "${join(INSTALL_DIR, "cloudflared.log")}"`,
  );
  exec(
    `"${nssm()}" set ${CF_SERVICE_NAME} AppStderr "${join(INSTALL_DIR, "cloudflared.log")}"`,
  );
  exec(`"${nssm()}" start ${CF_SERVICE_NAME}`);
}

export async function doctorServices(
  onStatus: (msg: string) => void,
): Promise<void> {
  onStatus("Recovering existing credentials...");

  const apiKey = getExistingApiKey();
  if (!apiKey) {
    throw new Error(
      `Could not recover API key from ${join(INSTALL_DIR, ".env")} or the ${SERVICE_NAME} service.`,
    );
  }

  const tunnelToken = getExistingTunnelToken();
  if (!tunnelToken) {
    throw new Error(
      `Could not recover the tunnel token from the ${CF_SERVICE_NAME} service.`,
    );
  }

  onStatus("Reinstalling Windows services with recovered credentials...");
  await installServices(apiKey, tunnelToken, onStatus);
}

export async function updateProxy(
  onStatus: (msg: string) => void,
): Promise<void> {
  if (!existsSync(nssm())) {
    throw new Error(
      `Installation not found at ${INSTALL_DIR}. Please install first.`,
    );
  }

  try {
    exec(`"${nssm()}" stop ${SERVICE_NAME}`);
  } catch {}
  await new Promise((r) => setTimeout(r, 2000));

  await downloadProxyBinary(onStatus);

  exec(`"${nssm()}" start ${SERVICE_NAME}`);
}

export function uninstall(): void {
  stopAndRemoveService(SERVICE_NAME);
  stopAndRemoveService(CF_SERVICE_NAME);
  if (existsSync(INSTALL_DIR)) {
    rmSync(INSTALL_DIR, { recursive: true, force: true });
  }
}
