// Stage 4 fallback (PRD §8): formats a transcript with a small hosted model when the
// on-device model is unavailable or its output was rejected. The app validates whatever
// comes back (stage 5), so this function only formats.
import Anthropic from "npm:@anthropic-ai/sdk@1.3.0";
import { formattingInstructions } from "../_shared/formatting-prompt.ts";
import { consumeQuota, json, requireUser } from "../_shared/http.ts";

const MODEL = Deno.env.get("FORMAT_MODEL") ?? "claude-haiku-5-5";
const DAILY_LIMIT = Number(Deno.env.get("FORMAT_DAILY_LIMIT") ?? 300);
// Signed-out apps use anonymous sessions, which are cheap to create: they get less
const ANONYMOUS_DAILY_LIMIT = Number(Deno.env.get("FORMAT_ANONYMOUS_DAILY_LIMIT") ?? 100);
const MAX_CHARS = 8000;

let client: Anthropic | undefined;

export async function handle(req: Request): Promise<Response> {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const user = await requireUser(req);
  if (!user) return json({ error: "Sign in first" }, 401);

  let body: { text?: unknown; vocabulary?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Expected JSON" }, 400);
  }
  const text = typeof body.text === "string" ? body.text.trim() : "";
  if (!text || text.length > MAX_CHARS) return json({ error: `text must be 1 to ${MAX_CHARS} characters` }, 400);
  const vocabulary = Array.isArray(body.vocabulary)
    ? body.vocabulary.filter((v): v is string => typeof v === "string" && v.length <= 60).slice(0, 100)
    : [];

  const key = Deno.env.get("ANTHROPIC_API_KEY");
  if (!key) return json({ error: "Hosted formatting isn't configured" }, 503);
  if (!(await consumeQuota(user.id, "format", user.is_anonymous ? ANONYMOUS_DAILY_LIMIT : DAILY_LIMIT))) return json({ error: "Daily formatting limit reached" }, 429);

  client ??= new Anthropic({ apiKey: key, timeout: 15_000, maxRetries: 1 });
  try {
    const message = await client.messages.create({
      model: MODEL,
      max_tokens: Math.min(4096, Math.ceil(text.length / 2) + 256),
      system: formattingInstructions(vocabulary),
      messages: [{ role: "user", content: text }],
      output_config: { effort: "low" },
    });
    if (message.stop_reason === "refusal") return json({ error: "The model declined to format this" }, 502);
    const formatted = message.content
      .flatMap((block) => (block.type === "text" ? [block.text] : []))
      .join("")
      .trim();
    if (!formatted) return json({ error: "Empty response" }, 502);
    return json({ text: formatted, engine_id: "hosted-small", model: MODEL });
  } catch (error) {
    if (error instanceof Anthropic.APIError) {
      console.error(`[format] Anthropic ${error.status}: ${error.message}`);
      return json({ error: "Formatting service error" }, 502);
    }
    console.error("[format]", error);
    return json({ error: "Formatting failed" }, 500);
  }
}


