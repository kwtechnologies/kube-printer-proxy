import { randomBytes } from "crypto";
import { CF_API_BASE, CF_DOMAIN } from "./config.js";

export interface TunnelResult {
  token: string;
  proxyUrl: string;
}

async function cfRequest(
  method: string,
  endpoint: string,
  token: string,
  body?: unknown,
): Promise<any> {
  const headers: Record<string, string> = {
    Authorization: `Bearer ${token}`,
  };
  const init: RequestInit = { method, headers };
  if (body) {
    headers["Content-Type"] = "application/json";
    init.body = JSON.stringify(body);
  }
  const res = await fetch(`${CF_API_BASE}${endpoint}`, init);
  return res.json();
}

function cfGet(endpoint: string, token: string) {
  return cfRequest("GET", endpoint, token);
}
function cfPost(endpoint: string, token: string, body: unknown) {
  return cfRequest("POST", endpoint, token, body);
}
function cfPut(endpoint: string, token: string, body: unknown) {
  return cfRequest("PUT", endpoint, token, body);
}

export async function verifyTokenAndGetAccount(
  token: string,
): Promise<string> {
  const accounts = await cfGet("/accounts?per_page=1", token);
  if (!accounts.success) {
    throw new Error(
      `API token invalid: ${JSON.stringify(accounts.errors ?? [])}`,
    );
  }

  if (accounts.result?.length > 0) {
    return accounts.result[0].id;
  }

  const zones = await cfGet(`/zones?name=${CF_DOMAIN}&per_page=1`, token);
  if (zones.result?.length > 0 && zones.result[0].account?.id) {
    return zones.result[0].account.id;
  }

  throw new Error(
    "Could not determine account ID. Ensure the token has Account > Cloudflare Tunnel > Edit and Zone > DNS > Edit permissions.",
  );
}

export async function getZoneId(token: string): Promise<string> {
  const zones = await cfGet(`/zones?name=${CF_DOMAIN}&per_page=1`, token);
  if (!zones.result?.[0]?.id) {
    throw new Error(`Could not find zone ${CF_DOMAIN}.`);
  }
  return zones.result[0].id;
}

export async function findOrCreateTunnel(
  token: string,
  accountId: string,
  tunnelName: string,
): Promise<string> {
  const existing = await cfGet(
    `/accounts/${accountId}/cfd_tunnel?name=${tunnelName}&is_deleted=false`,
    token,
  );

  if (existing.result?.length > 0) {
    return existing.result[0].id;
  }

  const secret = randomBytes(32).toString("base64");
  const resp = await cfPost(`/accounts/${accountId}/cfd_tunnel`, token, {
    name: tunnelName,
    config_src: "cloudflare",
    tunnel_secret: secret,
  });

  if (!resp.result?.id) {
    throw new Error(`Failed to create tunnel: ${JSON.stringify(resp)}`);
  }
  return resp.result.id;
}

export async function configureIngress(
  token: string,
  accountId: string,
  tunnelId: string,
  hostname: string,
): Promise<void> {
  const resp = await cfPut(
    `/accounts/${accountId}/cfd_tunnel/${tunnelId}/configurations`,
    token,
    {
      config: {
        ingress: [
          { hostname, service: "http://localhost:9191" },
          { service: "http_status:404" },
        ],
      },
    },
  );
  if (!resp.success) {
    throw new Error(`Failed to configure ingress: ${JSON.stringify(resp)}`);
  }
}

export async function ensureDnsRecord(
  token: string,
  zoneId: string,
  hostname: string,
  tunnelId: string,
): Promise<void> {
  const check = await cfGet(
    `/zones/${zoneId}/dns_records?name=${hostname}&type=CNAME`,
    token,
  );

  const record = {
    type: "CNAME",
    name: hostname,
    content: `${tunnelId}.cfargotunnel.com`,
    proxied: true,
  };

  if (check.result?.length > 0) {
    await cfPut(
      `/zones/${zoneId}/dns_records/${check.result[0].id}`,
      token,
      record,
    );
  } else {
    await cfPost(`/zones/${zoneId}/dns_records`, token, record);
  }
}

export async function getTunnelToken(
  token: string,
  accountId: string,
  tunnelId: string,
): Promise<string> {
  const resp = await cfGet(
    `/accounts/${accountId}/cfd_tunnel/${tunnelId}/token`,
    token,
  );
  if (!resp.result) {
    throw new Error(`Failed to get tunnel token: ${JSON.stringify(resp)}`);
  }
  return resp.result;
}

export async function setupTunnel(
  cfToken: string,
  tunnelName: string,
  onStatus: (msg: string) => void,
): Promise<TunnelResult> {
  const subdomain = `print-proxy-${tunnelName}`;
  const hostname = `${subdomain}.${CF_DOMAIN}`;

  onStatus("Verifying Cloudflare API token...");
  const accountId = await verifyTokenAndGetAccount(cfToken);

  onStatus(`Fetching zone ID for ${CF_DOMAIN}...`);
  const zoneId = await getZoneId(cfToken);

  onStatus(`Setting up tunnel '${tunnelName}'...`);
  const tunnelId = await findOrCreateTunnel(cfToken, accountId, tunnelName);

  onStatus(`Configuring ingress (${hostname} -> localhost:9191)...`);
  await configureIngress(cfToken, accountId, tunnelId, hostname);

  onStatus(`Creating DNS record (${hostname})...`);
  await ensureDnsRecord(cfToken, zoneId, hostname, tunnelId);

  onStatus("Retrieving tunnel token...");
  const token = await getTunnelToken(cfToken, accountId, tunnelId);

  return { token, proxyUrl: `https://${hostname}` };
}
