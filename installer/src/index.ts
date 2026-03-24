import { execSync, spawnSync } from "child_process";
import { randomBytes } from "crypto";
import { existsSync, writeFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";

import * as p from "@clack/prompts";

import { setupTunnel } from "./cloudflare.js";
import { INSTALL_DIR, isWindows, isMac } from "./config.js";

function generateApiKey(): string {
  return randomBytes(16).toString("hex");
}

async function healthCheck(): Promise<boolean> {
  try {
    const res = await fetch("http://localhost:9191/health", {
      signal: AbortSignal.timeout(5000),
    });
    return res.ok;
  } catch {
    return false;
  }
}

function saveCredentials(proxyUrl: string, apiKey: string): string[] {
  const content = [
    "Printer Proxy Credentials",
    "========================",
    `Proxy URL : ${proxyUrl}`,
    `API Key   : ${apiKey}`,
    "",
    "Enter these values in Portal > Print Proxy settings.",
  ].join("\n");

  const paths: string[] = [];
  const installCred = join(INSTALL_DIR, "credentials.txt");
  writeFileSync(installCred, content);
  paths.push(installCred);

  if (isWindows) {
    try {
      const desktop = join(homedir(), "Desktop", "printer-proxy-credentials.txt");
      writeFileSync(desktop, content);
      paths.push(desktop);
    } catch {}
  }

  return paths;
}

async function doInstall(): Promise<void> {
  const tunnelMode = await p.select({
    message: "How would you like to configure the Cloudflare Tunnel?",
    options: [
      {
        value: "auto",
        label: "Create a new tunnel automatically",
        hint: "requires a Cloudflare API token",
      },
      {
        value: "manual",
        label: "I already have a tunnel token",
      },
    ],
  });
  if (p.isCancel(tunnelMode)) return process.exit(0);

  let tunnelToken = "";
  let proxyUrl = "";
  let apiKey = "";

  if (tunnelMode === "manual") {
    const token = await p.text({
      message: "Enter your Cloudflare Tunnel token:",
      validate: (v) => (!v.trim() ? "Tunnel token is required" : undefined),
    });
    if (p.isCancel(token)) return process.exit(0);
    tunnelToken = token;

    const key = await p.text({
      message: "Enter the API key for the print proxy:",
      validate: (v) => (!v.trim() ? "API key is required" : undefined),
    });
    if (p.isCancel(key)) return process.exit(0);
    apiKey = key;
  } else {
    const cfToken = await p.text({
      message: "Enter your Cloudflare API token:",
      validate: (v) => (!v.trim() ? "API token is required" : undefined),
    });
    if (p.isCancel(cfToken)) return process.exit(0);

    const tunnelName = await p.text({
      message: "Enter a tunnel name:",
      placeholder: "e.g. alvin-office",
      validate: (v) => (!v.trim() ? "Tunnel name is required" : undefined),
    });
    if (p.isCancel(tunnelName)) return process.exit(0);

    const spin = p.spinner();
    spin.start("Setting up Cloudflare Tunnel...");
    try {
      const result = await setupTunnel(cfToken, tunnelName, (msg) =>
        spin.message(msg),
      );
      tunnelToken = result.token;
      proxyUrl = result.proxyUrl;
      spin.stop("Tunnel setup complete!");
    } catch (err) {
      spin.stop("Tunnel setup failed.");
      p.log.error(err instanceof Error ? err.message : String(err));
      return;
    }

    apiKey = generateApiKey();
    p.log.info(`Generated API key: ${apiKey}`);
  }

  const spin = p.spinner();
  try {
    const services = isWindows
      ? await import("./service-windows.js")
      : await import("./service-macos.js");

    spin.start("Installing services...");
    await services.installServices(apiKey, tunnelToken, (msg) =>
      spin.message(msg),
    );
    spin.stop("Services installed!");

    spin.start("Running health check...");
    await new Promise((r) => setTimeout(r, 3000));
    const healthy = await healthCheck();
    if (healthy) {
      spin.stop("Health check passed!");
    } else {
      spin.stop(
        "Health check did not pass yet -- the service may still be starting.",
      );
      p.log.warn(`Check logs at ${join(INSTALL_DIR, "proxy.log")}`);
    }
  } catch (err) {
    spin.stop("Installation failed.");
    p.log.error(err instanceof Error ? err.message : String(err));
    return;
  }

  p.note(
    [
      `Install directory : ${INSTALL_DIR}`,
      `Logs              : ${INSTALL_DIR}/proxy.log`,
    ].join("\n"),
    "Installation Complete",
  );

  if (proxyUrl) {
    const credPaths = saveCredentials(proxyUrl, apiKey);
    p.note(
      [
        `Proxy URL : ${proxyUrl}`,
        `API Key   : ${apiKey}`,
        "",
        `Saved to  : ${credPaths.join("\n            ")}`,
      ].join("\n"),
      "Enter these in Portal > Print Proxy",
    );
  }
}

async function doUpdate(): Promise<void> {
  const spin = p.spinner();
  try {
    const services = isWindows
      ? await import("./service-windows.js")
      : await import("./service-macos.js");

    spin.start("Updating printer-proxy...");
    await services.updateProxy((msg) => spin.message(msg));
    spin.stop("Update complete! Service restarted.");
  } catch (err) {
    spin.stop("Update failed.");
    p.log.error(err instanceof Error ? err.message : String(err));
  }
}

async function doUninstall(): Promise<void> {
  const confirmed = await p.confirm({
    message: "This will remove all services and files. Continue?",
    initialValue: false,
  });
  if (p.isCancel(confirmed) || !confirmed) {
    p.log.info("Aborted.");
    return;
  }

  const spin = p.spinner();
  try {
    const services = isWindows
      ? await import("./service-windows.js")
      : await import("./service-macos.js");

    spin.start("Uninstalling...");
    services.uninstall();
    spin.stop("Uninstall complete.");
  } catch (err) {
    spin.stop("Uninstall failed.");
    p.log.error(err instanceof Error ? err.message : String(err));
  }
}

function ensureElevated(): void {
  if (isMac && process.getuid?.() !== 0) {
    const args = process.argv.slice(1);
    const result = spawnSync("sudo", [process.argv[0], ...args], {
      stdio: "inherit",
    });
    process.exit(result.status ?? 1);
  }
  // Windows elevation is handled by the bootstrap setup.ps1
}

async function main(): Promise<void> {
  ensureElevated();

  p.intro("Printer Proxy Installer");

  const action = await p.select({
    message: "What would you like to do?",
    options: [
      { value: "install", label: "Install", hint: "fresh installation" },
      {
        value: "update",
        label: "Update",
        hint: "download latest proxy binary",
      },
      {
        value: "uninstall",
        label: "Uninstall",
        hint: "remove everything",
      },
    ],
  });

  if (p.isCancel(action)) {
    p.outro("Cancelled.");
    return;
  }

  switch (action) {
    case "install":
      await doInstall();
      break;
    case "update":
      await doUpdate();
      break;
    case "uninstall":
      await doUninstall();
      break;
  }

  p.outro("Done!");
}

main().catch((err) => {
  p.log.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
