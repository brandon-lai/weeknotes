// Resolves a share link token for the web reader (PRD §12 "Access rules", M8). Uses the
// service role, and returns the update plus signed media URLs only while the link is valid.
// Signed URLs never outlive the link.
import { adminClient, json } from "../_shared/http.ts";

const MAX_URL_SECONDS = 6 * 60 * 60;

/** Locally the function reaches Storage at an internal host (http://kong:8000); browsers need
 *  the public one. PUBLIC_SUPABASE_URL fixes that; in production SUPABASE_URL is already public. */
export function publicUrl(url: string | null | undefined): string | null {
  if (!url) return null;
  const override = Deno.env.get("PUBLIC_SUPABASE_URL");
  if (!override) return url;
  const internal = new URL(url);
  const outside = new URL(override);
  internal.protocol = outside.protocol;
  internal.host = outside.host;
  return internal.toString();
}

type Row = {
  token: string;
  expires_at: string;
  updates: {
    id: string;
    week_start: string;
    prompt: string | null;
    body_text: string | null;
    posted_at: string;
    profiles: { display_name: string } | null;
    voice_memos: { storage_path: string; duration_ms: number; waveform: number[]; transcript_clean: string | null; transcript_raw: string | null } | null;
    update_photos: { storage_path: string; position: number; width: number | null; height: number | null }[];
  } | null;
};

export async function handle(req: Request): Promise<Response> {
  const url = new URL(req.url);
  let token = url.searchParams.get("token") ?? "";
  if (!token && req.method === "POST") {
    try {
      token = String((await req.json()).token ?? "");
    } catch {
      token = "";
    }
  }
  if (!/^[A-Za-z0-9_-]{16,64}$/.test(token)) return json({ status: "not_found" }, 404);

  const db = adminClient();
  const { data, error } = await db
    .from("share_links")
    .select(`token, expires_at,
      updates (id, week_start, prompt, body_text, posted_at,
        profiles!updates_author_id_fkey (display_name),
        voice_memos (storage_path, duration_ms, waveform, transcript_clean, transcript_raw),
        update_photos (storage_path, position, width, height))`)
    .eq("token", token)
    .maybeSingle<Row>();
  if (error) {
    console.error(`[share] ${error.message}`);
    return json({ status: "error" }, 500);
  }
  if (!data || !data.updates) return json({ status: "not_found" }, 404);

  const remaining = Math.floor((new Date(data.expires_at).getTime() - Date.now()) / 1000);
  if (remaining <= 0) return json({ status: "expired" }, 410);
  const ttl = Math.max(60, Math.min(remaining, MAX_URL_SECONDS));

  const update = data.updates;
  const memo = update.voice_memos;
  let memoUrl: string | null = null;
  if (memo) {
    const signed = await db.storage.from("memos").createSignedUrl(memo.storage_path, ttl);
    memoUrl = publicUrl(signed.data?.signedUrl);
  }
  const photos = [...(update.update_photos ?? [])].sort((a, b) => a.position - b.position);
  const signedPhotos = photos.length
    ? (await db.storage.from("photos").createSignedUrls(photos.map((p) => p.storage_path), ttl)).data ?? []
    : [];

  await db.rpc("count_share_view", { link: token });
  const { data: config } = await db.from("app_config").select("app_store_url").maybeSingle();

  return json({
    status: "ok",
    expires_at: data.expires_at,
    app_store_url: config?.app_store_url ?? null,
    update: {
      author_name: update.profiles?.display_name ?? "A friend",
      week_start: update.week_start,
      prompt: update.prompt,
      body_text: update.body_text,
      posted_at: update.posted_at,
      memo: memo && memoUrl
        ? {
          url: memoUrl,
          duration_ms: memo.duration_ms,
          waveform: memo.waveform,
          transcript: memo.transcript_clean ?? memo.transcript_raw,
        }
        : null,
      photos: photos
        .map((p, i) => ({ url: publicUrl(signedPhotos[i]?.signedUrl), width: p.width, height: p.height }))
        .filter((p) => p.url),
    },
  });
}
