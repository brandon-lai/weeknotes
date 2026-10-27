import demo from "./demo-update.json" with { type: "json" };

export type SharedMemo = {
  url: string;
  duration_ms: number;
  waveform: number[];
  transcript: string | null;
};

export type SharedUpdate = {
  author_name: string;
  week_start: string;
  prompt: string | null;
  body_text: string | null;
  posted_at: string;
  memo: SharedMemo | null;
  photos: { url: string; width: number | null; height: number | null }[];
};

export type ShareResult =
  | { status: "ok"; update: SharedUpdate; expiresAt: string | null; appStoreUrl: string | null }
  | { status: "expired" }
  | { status: "not_found" }
  | { status: "error" };

/** One flag, checked at every entry point: with no Supabase configured the reader runs on demo data. */
export const hasDatabase = Boolean(process.env.SUPABASE_URL && process.env.SUPABASE_ANON_KEY);

export const TOKEN_PATTERN = /^[A-Za-z0-9_-]{16,64}$/;

export function appStoreUrl(fromServer: string | null = null): string | null {
  return fromServer || process.env.NEXT_PUBLIC_APP_STORE_URL || null;
}

/**
 * Resolves a share token through the `share` Edge Function, which uses the service role and
 * returns the update with signed media URLs only while the link is valid.
 */
export async function resolveShare(token: string, fetcher: typeof fetch = fetch): Promise<ShareResult> {
  if (token === "demo") {
    return { status: "ok", update: demo as SharedUpdate, expiresAt: null, appStoreUrl: appStoreUrl() };
  }
  if (!TOKEN_PATTERN.test(token)) return { status: "not_found" };
  if (!hasDatabase) return { status: "not_found" };

  const base = process.env.SUPABASE_URL!.replace(/\/$/, "");
  const key = process.env.SUPABASE_ANON_KEY!;
  let response: Response;
  try {
    response = await fetcher(`${base}/functions/v1/share?token=${encodeURIComponent(token)}`, {
      headers: { apikey: key, Authorization: `Bearer ${key}` },
      cache: "no-store",
      signal: AbortSignal.timeout(10_000),
    });
  } catch {
    return { status: "error" };
  }
  if (response.status === 410) return { status: "expired" };
  if (response.status === 404) return { status: "not_found" };
  if (!response.ok) return { status: "error" };
  const body = (await response.json()) as { status: string; update?: SharedUpdate; expires_at?: string; app_store_url?: string | null };
  if (body.status !== "ok" || !body.update) return { status: "not_found" };
  return { status: "ok", update: body.update, expiresAt: body.expires_at ?? null, appStoreUrl: appStoreUrl(body.app_store_url ?? null) };
}

const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** "Oct 19 – 25", or "Sep 28 – Oct 4" across months. Same style as the app. */
export function weekLabel(weekStart: string): string {
  const [y, m, d] = weekStart.split("-").map(Number);
  const start = new Date(Date.UTC(y, m - 1, d));
  const end = new Date(Date.UTC(y, m - 1, d + 6));
  const startText = `${months[start.getUTCMonth()]} ${start.getUTCDate()}`;
  const endText = start.getUTCMonth() === end.getUTCMonth() ? `${end.getUTCDate()}` : `${months[end.getUTCMonth()]} ${end.getUTCDate()}`;
  return `${startText} – ${endText}`;
}

export function firstName(name: string): string {
  return name.trim().split(/\s+/)[0] || name;
}

export function initials(name: string): string {
  return name.trim().split(/\s+/).slice(0, 2).map((p) => p[0]?.toUpperCase() ?? "").join("") || "?";
}

export function excerpt(update: SharedUpdate, length = 150): string {
  const text = (update.body_text ?? update.memo?.transcript ?? "").replace(/\s+/g, " ").trim();
  return text.length > length ? `${text.slice(0, length - 1).trimEnd()}…` : text;
}
