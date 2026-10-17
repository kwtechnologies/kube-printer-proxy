# 0001. Baked tunnel token, no self-registration

The device runs a pre-created, remotely-managed Cloudflare tunnel whose token is baked into the SD image together with the API key, and it never creates tunnels or registers with kube-api-v2. We chose this because there is one site and the API holds a singleton `PrintProxyConfig {url, apiKey}`; self-registration would need a new API endpoint, Cloudflare account credentials in prod, and would let a copied card or a test Pi hijack every print job. Revisit when a second site appears.
