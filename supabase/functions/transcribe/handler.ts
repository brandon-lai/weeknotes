// Server-side fallback for voice memos where on-device transcription failed (PRD §7,
// "Recommendation" 2), and the "openai-hosted" engine in the bake-off. The audio is sent
// to OpenAI and not kept here.
import { consumeQuota, json, requireUser } from "../_shared/http.ts";

const MODEL = Deno.env.get("OPENAI_TRANSCRIBE_MODEL") ?? "gpt-4o-transcribe";
const DAILY_LIMIT = Number(Deno.env.get("TRANSCRIBE_DAILY_LIMIT") ?? 30);
const ANONYMOUS_DAILY_LIMIT = Number(Deno.env.get("TRANSCRIBE_ANONYMOUS_DAILY_LIMIT") ?? 10);
const MAX_BYTES = 5 * 1024 * 1024;

export async function handle(req: Request): Promise<Response> {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const user = await requireUser(req);
  if (!user) return json({ error: "Sign in first" }, 401);
  const key = Deno.env.get("OPENAI_API_KEY");
  if (!key) return json({ error: "Hosted transcription isn't configured" }, 503);

  let form: FormData;
  try {
    form = await req.formData();
  } catch {
    return json({ error: "Expected multipart form data" }, 400);
  }
  const file = form.get("file");
  if (!(file instanceof File) || file.size === 0) return json({ error: "Missing audio file" }, 400);
  if (file.size > MAX_BYTES) return json({ error: "Audio too large" }, 413);
  // Whisper-style glossary: names to spell right, most important last
  const prompt = String(form.get("prompt") ?? "").slice(0, 800);

  if (!(await consumeQuota(user.id, "transcribe", user.is_anonymous ? ANONYMOUS_DAILY_LIMIT : DAILY_LIMIT))) return json({ error: "Daily transcription limit reached" }, 429);

  const upstream = new FormData();
  upstream.set("file", file, file.name || "memo.m4a");
  upstream.set("model", MODEL);
  upstream.set("response_format", "json");
  if (prompt) upstream.set("prompt", prompt);

  const started = Date.now();
  const response = await fetch("https://api.openai.com/v1/audio/transcriptions", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}` },
    body: upstream,
    signal: AbortSignal.timeout(120_000),
  });
  if (!response.ok) {
    console.error(`[transcribe] OpenAI ${response.status}: ${(await response.text()).slice(0, 300)}`);
    return json({ error: "Transcription service error" }, 502);
  }
  const result = await response.json() as { text?: string };
  return json({ text: (result.text ?? "").trim(), engine_id: "openai-hosted", model: MODEL, elapsed_ms: Date.now() - started });
}
