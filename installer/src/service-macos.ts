import { execSync } from "child_process";
import { existsSync, mkdirSync, writeFileSync, rmSync } from "fs";
import { homedir } from "os";
import { join } from "path";

import { downloadFile, getLatestTag } from "./download.js";
import {
  INSTALL_DIR,
  GH_REPO,
  SERVICE_PROXY_NAME,
  SERVICE_CF_NAME,
  detectArch,
} from "./config.js";

function launchAgentsDir(): string {
  return join(homedir(), "Library", "LaunchAgents");
}
function proxyPlist(): string {
  return join(launchAgentsDir(), `${SERVICE_PROXY_NAME}.plist`);
}
function cfPlist(): string {
  return join(launchAgentsDir(), `${SERVICE_CF_NAME}.plist`);
}

function stopService(label: string, plistPath: string): void {
  try {
    execSync(`launchctl list "${label}"`, { stdio: "ignore" });
    execSync(`launchctl unload "${plistPath}"`, { stdio: "ignore" });
  } catch {
    // service not loaded
  }
}

function buildPlist(
  label: string,
  args: string[],
  env: Record<string, string>,
  logFile: string,
): string {
  const argsXml = args.map((a) => `    <string>${a}</string>`).join("\n");
  const envXml = Object.entries(env)
    .map(([k, v]) => `    <key>${k}</key>\n    <string>${v}</string>`)
    .join("\n");

  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
${argsXml}
  </array>${
    Object.keys(env).length > 0
      ? `
  <key>EnvironmentVariables</key>
  <dict>
${envXml}
  </dict>`
      : ""
  }
  <key>WorkingDirectory</key>
  <string>${INSTALL_DIR}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${logFile}</string>
  <key>StandardErrorPath</key>
  <string>${logFile}</string>
</dict>
</plist>`;
}

export async function installServices(
  apiKey: string,
  tunnelToken: string,
  onStatus: (msg: string) => void,
): Promise<void> {
  onStatus("Creating install directory...");
  mkdirSync(INSTALL_DIR, { recursive: true });

  const arch = detectArch();
  const tag = await getLatestTag(GH_REPO);

  onStatus("Downloading printer-proxy...");
  const proxyUrl = `https://github.com/${GH_REPO}/releases/download/${tag}/printer-proxy-darwin-${arch}`;
  await downloadFile(proxyUrl, join(INSTALL_DIR, "printer-proxy"));
  execSync(`chmod +x "${join(INSTALL_DIR, "printer-proxy")}"`);

  onStatus("Downloading cloudflared...");
  const cfArch = arch === "arm64" ? "arm64" : "amd64";
  const cfUrl = `https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-${cfArch}.tgz`;
  const cfTmp = join(INSTALL_DIR, "cloudflared.tgz");
  await downloadFile(cfUrl, cfTmp);
  execSync(`tar -xzf "${cfTmp}" -C "${INSTALL_DIR}" cloudflared`);
  execSync(`chmod +x "${join(INSTALL_DIR, "cloudflared")}"`);
  try { rmSync(cfTmp); } catch {}

  onStatus("Writing configuration...");
  writeFileSync(join(INSTALL_DIR, ".env"), `API_KEY=${apiKey}\nPORT=9191\n`);

  onStatus("Installing launchd services...");
  mkdirSync(launchAgentsDir(), { recursive: true });

  stopService(SERVICE_PROXY_NAME, proxyPlist());
  stopService(SERVICE_CF_NAME, cfPlist());

  writeFileSync(
    proxyPlist(),
    buildPlist(
      SERVICE_PROXY_NAME,
      [join(INSTALL_DIR, "printer-proxy")],
      { API_KEY: apiKey, PORT: "9191" },
      join(INSTALL_DIR, "proxy.log"),
    ),
  );
  execSync(`launchctl load "${proxyPlist()}"`);

  writeFileSync(
    cfPlist(),
    buildPlist(
      SERVICE_CF_NAME,
      [join(INSTALL_DIR, "cloudflared"), "tunnel", "run", "--token", tunnelToken],
      {},
      join(INSTALL_DIR, "cloudflared.log"),
    ),
  );
  execSync(`launchctl load "${cfPlist()}"`);
}

export async function updateProxy(
  onStatus: (msg: string) => void,
): Promise<void> {
  if (!existsSync(join(INSTALL_DIR, "printer-proxy"))) {
    throw new Error(`Installation not found at ${INSTALL_DIR}. Please install first.`);
  }

  const arch = detectArch();
  const tag = await getLatestTag(GH_REPO);

  stopService(SERVICE_PROXY_NAME, proxyPlist());

  onStatus("Downloading latest printer-proxy...");
  const proxyUrl = `https://github.com/${GH_REPO}/releases/download/${tag}/printer-proxy-darwin-${arch}`;
  await downloadFile(proxyUrl, join(INSTALL_DIR, "printer-proxy"));
  execSync(`chmod +x "${join(INSTALL_DIR, "printer-proxy")}"`);

  execSync(`launchctl load "${proxyPlist()}"`);
}

export function uninstall(): void {
  stopService(SERVICE_PROXY_NAME, proxyPlist());
  stopService(SERVICE_CF_NAME, cfPlist());
  try { rmSync(proxyPlist()); } catch {}
  try { rmSync(cfPlist()); } catch {}
  if (existsSync(INSTALL_DIR)) {
    rmSync(INSTALL_DIR, { recursive: true, force: true });
  }
}
