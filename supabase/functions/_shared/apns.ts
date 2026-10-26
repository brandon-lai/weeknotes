// Apple Push Notification service over HTTP/2 with token (JWT) authentication.
// Needs APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY (the .p8 file's contents) and
// APNS_TOPIC (the bundle id). APNS_HOST overrides the endpoint (tests point it at a mock).

export type ApnsConfig = {
  keyId: string;
  teamId: string;
  privateKeyPem: string;
  topic: string;
  hostOverride?: string;
};

export function apnsConfigFromEnv(): ApnsConfig | null {
  const keyId = Deno.env.get("APNS_KEY_ID");
  const teamId = Deno.env.get("APNS_TEAM_ID");
  const privateKeyPem = Deno.env.get("APNS_PRIVATE_KEY")?.replaceAll("\\n", "\n");
  const topic = Deno.env.get("APNS_TOPIC");
  if (!keyId || !teamId || !privateKeyPem || !topic) return null;
  return { keyId, teamId, privateKeyPem, topic, hostOverride: Deno.env.get("APNS_HOST") ?? undefined };
}

function base64url(bytes: Uint8Array | string): string {
  const data = typeof bytes === "string" ? new TextEncoder().encode(bytes) : bytes;
  let binary = "";
  for (const b of data) binary += String.fromCharCode(b);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

async function importKey(pem: string): Promise<CryptoKey> {
  const body = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

let cached: { token: string; issuedAt: number; keyId: string } | undefined;

/** ES256 provider token. Apple accepts one for up to an hour; we refresh after 50 minutes. */
export async function providerToken(config: ApnsConfig, now = Math.floor(Date.now() / 1000)): Promise<string> {
  if (cached && cached.keyId === config.keyId && now - cached.issuedAt < 50 * 60) return cached.token;
  const header = base64url(JSON.stringify({ alg: "ES256", kid: config.keyId }));
  const claims = base64url(JSON.stringify({ iss: config.teamId, iat: now }));
  const key = await importKey(config.privateKeyPem);
  // WebCrypto's ECDSA signature is already the raw r||s form JWS wants
  const signature = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${header}.${claims}`)),
  );
  const token = `${header}.${claims}.${base64url(signature)}`;
  cached = { token, issuedAt: now, keyId: config.keyId };
  return token;
}

export type PushResult = { ok: boolean; status: number; reason?: string; unregistered: boolean };

export async function sendPush(
  config: ApnsConfig,
  device: { token: string; environment: string },
  payload: Record<string, unknown>,
): Promise<PushResult> {
  const host = config.hostOverride ??
    (device.environment === "sandbox" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com");
  const response = await fetch(`${host}/3/device/${device.token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${await providerToken(config)}`,
      "apns-topic": config.topic,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": String(Math.floor(Date.now() / 1000) + 6 * 3600),
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(10_000),
  });
  let reason: string | undefined;
  if (!response.ok) {
    try {
      reason = (await response.json()).reason;
    } catch {
      reason = undefined;
    }
  } else {
    await response.body?.cancel();
  }
  const unregistered = response.status === 410 || reason === "BadDeviceToken" || reason === "Unregistered";
  return { ok: response.ok, status: response.status, reason, unregistered };
}
