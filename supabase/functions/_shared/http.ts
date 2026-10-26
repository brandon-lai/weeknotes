import { createClient, type SupabaseClient, type User } from "npm:@supabase/supabase-js@2.118.0";

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

let admin: SupabaseClient | undefined;

/** Service-role client. Only Edge Functions hold this key. */
export function adminClient(): SupabaseClient {
  admin ??= createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return admin;
}

/** The signed-in user behind the request's bearer token, or null. */
export async function requireUser(req: Request): Promise<User | null> {
  const header = req.headers.get("Authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (!token) return null;
  const { data, error } = await adminClient().auth.getUser(token);
  if (error || !data.user) return null;
  return data.user;
}

/** Scheduled jobs authenticate with the shared CRON_SECRET (pg_cron sends it). */
export function isCron(req: Request): boolean {
  const secret = Deno.env.get("CRON_SECRET");
  if (!secret) return false;
  const header = req.headers.get("Authorization") ?? "";
  return timingSafeEqual(header, `Bearer ${secret}`);
}

function timingSafeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

/** Counts a call against the user's daily allowance; false once it's used up. */
export async function consumeQuota(userId: string, kind: string, dailyLimit: number): Promise<boolean> {
  const { data, error } = await adminClient().rpc("consume_quota", { who: userId, quota_kind: kind, daily_limit: dailyLimit });
  if (error) {
    console.error(`[quota] ${error.message}`);
    return false;
  }
  return data === true;
}
