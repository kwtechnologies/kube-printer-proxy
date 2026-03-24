import { execSync } from "child_process";
import {
  existsSync,
  mkdirSync,
  writeFileSync,
  copyFileSync,
  readdirSync,
  rmSync,
  statSync,
} from "fs";
import { join } from "path";

import { downloadFile, getLatestTag } from "./download.js";
import { INSTALL_DIR, GH_REPO } from "./config.js";

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

function findFileRecursive(dir: string, name: string, match?: string): string | null {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      const found = findFileRecursive(full, name, match);
      if (found) return found;
    } else if (
      entry.name === name &&
      (!match || full.includes(match))
    ) {
      return full;
    }
  }
  return null;
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

  const tag = await getLatestTag(GH_REPO);
  const releaseRes = await fetch(
    `https://api.github.com/repos/${GH_REPO}/releases/latest`,
  );
  const release = (await releaseRes.json()) as {
    assets: { name: string; browser_download_url: string }[];
  };
  const exeAsset = release.assets.find((a) => a.name === "printer-proxy.exe");
  if (!exeAsset) throw new Error("printer-proxy.exe not found in release.");

  onStatus("Downloading printer-proxy.exe...");
  await downloadFile(
    exeAsset.browser_download_url,
    join(INSTALL_DIR, "printer-proxy.exe"),
  );

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

  onStatus("Downloading cloudflared.exe...");
  await downloadFile(CF_URL, join(INSTALL_DIR, "cloudflared.exe"));

  onStatus("Writing configuration...");
  writeFileSync(
    join(INSTALL_DIR, ".env"),
    `API_KEY=${apiKey}\r\nPORT=9191\r\n`,
  );

  onStatus("Installing Windows services...");
  stopAndRemoveService(SERVICE_NAME);
  stopAndRemoveService(CF_SERVICE_NAME);

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

export async function updateProxy(
  onStatus: (msg: string) => void,
): Promise<void> {
  if (!existsSync(nssm())) {
    throw new Error(
      `Installation not found at ${INSTALL_DIR}. Please install first.`,
    );
  }

  const releaseRes = await fetch(
    `https://api.github.com/repos/${GH_REPO}/releases/latest`,
  );
  const release = (await releaseRes.json()) as {
    assets: { name: string; browser_download_url: string }[];
  };
  const exeAsset = release.assets.find((a) => a.name === "printer-proxy.exe");
  if (!exeAsset) throw new Error("printer-proxy.exe not found in release.");

  try { exec(`"${nssm()}" stop ${SERVICE_NAME}`); } catch {}
  await new Promise((r) => setTimeout(r, 2000));

  onStatus("Downloading latest printer-proxy.exe...");
  await downloadFile(
    exeAsset.browser_download_url,
    join(INSTALL_DIR, "printer-proxy.exe"),
  );

  exec(`"${nssm()}" start ${SERVICE_NAME}`);
}

export function uninstall(): void {
  stopAndRemoveService(SERVICE_NAME);
  stopAndRemoveService(CF_SERVICE_NAME);
  if (existsSync(INSTALL_DIR)) {
    rmSync(INSTALL_DIR, { recursive: true, force: true });
  }
}
