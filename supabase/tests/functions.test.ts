// Edge Function and Storage tests against the LOCAL stack (seeded by scripts/seed-local.ts).
//   deno test -A supabase/tests/functions.test.ts
//
// The handlers are imported and called directly with the local service-role key, and APNs is
// a mock server in this process, so M7 is tested end to end without Apple: a user whose local
// reminder time just passed gets one correctly signed push; nobody gets two; nobody who posted
// gets one.
import { assert, assertEquals, assertExists } from "jsr:@std/assert@1.0.13";
import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import postgres from "npm:postgres@3.4.7";

const status = JSON.parse(new TextDecoder().decode((await new Deno.Command("supabase", { args: ["status", "-o", "json"] }).output()).stdout));
Deno.env.set("SUPABASE_URL", status.API_URL);
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", status.SERVICE_ROLE_KEY);
Deno.env.set("CRON_SECRET", "test-cron-secret");
const sql = postgres(status.DB_URL, { max: 1, onnotice: () => {} });
const anon = status.ANON_KEY as string;

const { handle: reminders } = await import("../functions/reminders/handler.ts");
const { handle: share } = await import("../functions/share/handler.ts");
const { handle: format } = await import("../functions/format/handler.ts");

const cron = (path: string) => new Request(`http://local/${path}`, { method: "POST", headers: { Authorization: "Bearer test-cron-secret" } });

// ---------- a mock APNs that records requests ----------
const { privateKey, publicKey } = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", privateKey));
const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8))}\n-----END PRIVATE KEY-----`;
type Received = { path: string; headers: Headers; body: unknown };
const received: Received[] = [];
let respondWith = 200;
const server = Deno.serve({ port: 0, onListen() {} }, async (req) => {
  received.push({ path: new URL(req.url).pathname, headers: req.headers, body: await req.json() });
  return respondWith === 200 ? new Response(null, { status: 200 }) : Response.json({ reason: "Unregistered" }, { status: respondWith });
});
const apns = { keyId: "TESTKEY123", teamId: "KT2Y8F24DZ", privateKeyPem: pem, topic: "com.blai.weeknotes", hostOverride: `http://127.0.0.1:${server.addr.port}` };

function b64urlDecode(s: string) {
  return Uint8Array.from(atob(s.replaceAll("-", "+").replaceAll("_", "/") + "===".slice((s.length + 3) % 4)), (c) => c.charCodeAt(0));
}

/** Makes `who` due right now: reminder day and time = their local "now minus 5 minutes". */
async function makeDue(who: string) {
  await sql`update public.profiles p set
              reminder_weekday = extract(dow from (now() - interval '5 minutes') at time zone p.timezone)::int,
              reminder_time = ((now() - interval '5 minutes') at time zone p.timezone)::time,
              reminders_enabled = true
            where display_name = ${who}`;
  await sql`delete from public.reminder_log r using public.profiles p where r.user_id = p.id and p.display_name = ${who}`;
  await sql`insert into public.push_tokens (token, user_id, environment)
            select ${"ab".repeat(32)}, id, 'sandbox' from public.profiles where display_name = ${who}
            on conflict (token) do update set user_id = excluded.user_id`;
}

Deno.test("reminders: refuses calls without the cron secret", async () => {
  const response = await reminders(new Request("http://local/reminders", { method: "POST" }), apns);
  assertEquals(response.status, 401);
});

Deno.test("reminders: one signed push to a user who is due and hasn't posted", async () => {
  // Fay hasn't posted this week in the seed
  await sql`update public.profiles set reminders_enabled = false`;
  await makeDue("Fay Morales");
  received.length = 0;
  const response = await reminders(cron("reminders"), apns);
  const result = await response.json();
  assertEquals(result.sent, 1, JSON.stringify(result));
  assertEquals(received.length, 1);
  const push = received[0];
  assertEquals(push.path, `/3/device/${"ab".repeat(32)}`);
  assertEquals(push.headers.get("apns-topic"), "com.blai.weeknotes");
  assertEquals(push.headers.get("apns-push-type"), "alert");
  assertEquals((push.body as { aps: { alert: { body: string } } }).aps.alert.body, "Your week is ready to write.");

  // The provider token is an ES256 JWT that verifies against the key pair
  const token = push.headers.get("authorization")!.replace(/^bearer /, "");
  const [header, claims, signature] = token.split(".");
  assertEquals(JSON.parse(new TextDecoder().decode(b64urlDecode(header))), { alg: "ES256", kid: "TESTKEY123" });
  assertEquals(JSON.parse(new TextDecoder().decode(b64urlDecode(claims))).iss, "KT2Y8F24DZ");
  const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, b64urlDecode(signature), new TextEncoder().encode(`${header}.${claims}`));
  assert(valid, "JWT signature verifies");

  // Logged, so a second run in the same window sends nothing
  const [{ count }] = await sql`select count(*)::int as count from public.reminder_log r join public.profiles p on p.id = r.user_id where p.display_name = 'Fay Morales'`;
  assertEquals(count, 1);
  received.length = 0;
  const again = await (await reminders(cron("reminders"), apns)).json();
  assertEquals(again.sent, 0);
  assertEquals(received.length, 0);
});

Deno.test("reminders: nobody who already posted this week", async () => {
  await sql`update public.profiles set reminders_enabled = false`;
  await makeDue("Hana Sato"); // posted this week in the seed
  received.length = 0;
  const result = await (await reminders(cron("reminders"), apns)).json();
  assertEquals(result.due, 0);
  assertEquals(received.length, 0);
});

Deno.test("reminders: an unregistered device token is removed and nothing is logged", async () => {
  await sql`update public.profiles set reminders_enabled = false`;
  await makeDue("Ivy Chen");
  respondWith = 410;
  received.length = 0;
  const result = await (await reminders(cron("reminders"), apns)).json();
  respondWith = 200;
  assertEquals(result.removed_tokens, 1);
  assertEquals(result.sent, 0);
  const [{ count }] = await sql`select count(*)::int as count from public.push_tokens where token = ${"ab".repeat(32)}`;
  assertEquals(count, 0);
});

Deno.test("reminders: without APNs credentials it says so and sends nothing", async () => {
  const result = await (await reminders(cron("reminders"), null)).json();
  assertEquals(result.skipped, "APNs is not configured");
});

// ---------- share links ----------

Deno.test("share: valid, expired and unknown tokens", async () => {
  const [update] = await sql`select u.id from public.updates u join public.profiles p on p.id = u.author_id
                             join public.update_photos ph on ph.update_id = u.id where p.display_name = 'Hana Sato' limit 1`;
  await sql`insert into public.share_links (token, update_id, expires_at) values
              ('testValidShareToken00001', ${update.id}, now() + interval '2 hours'),
              ('testExpiredShareToken001', ${update.id}, now() - interval '1 minute')
            on conflict (token) do update set expires_at = excluded.expires_at`;
  const ok = await share(new Request("http://local/share?token=testValidShareToken00001"));
  assertEquals(ok.status, 200);
  const body = await ok.json();
  assertEquals(body.update.author_name, "Hana Sato");
  assert(body.update.photos.length > 0);
  // Signed URLs never outlive the link (2 hours here, not the 6-hour maximum)
  const signed = new URL(body.update.photos[0].url);
  const jwt = JSON.parse(new TextDecoder().decode(b64urlDecode(signed.searchParams.get("token")!.split(".")[1])));
  assert(jwt.exp - jwt.iat <= 2 * 3600 + 5, `signed for ${jwt.exp - jwt.iat}s`);

  assertEquals((await share(new Request("http://local/share?token=testExpiredShareToken001"))).status, 410);
  assertEquals((await share(new Request("http://local/share?token=doesNotExist0000000000"))).status, 404);
  assertEquals((await share(new Request("http://local/share?token=../../etc"))).status, 404);
});

// ---------- format ----------

Deno.test("format: requires a signed-in user and sane input", async () => {
  assertEquals((await format(new Request("http://local/format", { method: "POST", body: "{}" }))).status, 401);
  const client = createClient(status.API_URL, anon, { auth: { persistSession: false } });
  const { data } = await client.auth.signInWithPassword({ email: "ana@weeknotes.test", password: "weeknotes-dev-password" });
  const auth = { Authorization: `Bearer ${data.session!.access_token}` };
  assertEquals((await format(new Request("http://local/format", { method: "POST", headers: auth, body: JSON.stringify({ text: "" }) }))).status, 400);
  assertEquals((await format(new Request("http://local/format", { method: "POST", headers: auth, body: "x".repeat(10) }))).status, 400);
  assertEquals((await format(new Request("http://local/format", { method: "POST", headers: auth, body: JSON.stringify({ text: "y".repeat(9000) }) }))).status, 400);
});

// ---------- storage policies (private memos and photos) ----------

Deno.test("storage: only people who can read an update can sign its files", async () => {
  const [photo] = await sql`select ph.storage_path from public.update_photos ph join public.updates u on u.id = ph.update_id
                            join public.profiles p on p.id = u.author_id where p.display_name = 'Hana Sato' limit 1`;
  async function signAs(email: string | null) {
    const client = createClient(status.API_URL, anon, { auth: { persistSession: false } });
    if (email) await client.auth.signInWithPassword({ email, password: "weeknotes-dev-password" });
    return await client.storage.from("photos").createSignedUrl(photo.storage_path, 60);
  }
  // Ana is in Hana's Book club circle
  const ana = await signAs("ana@weeknotes.test");
  assertExists(ana.data?.signedUrl, ana.error?.message);
  // Ben is not Hana's friend; Deepa is Ivy's friend but not Hana's
  assertEquals((await signAs("ben@weeknotes.test")).data, null);
  assertEquals((await signAs("dee@weeknotes.test")).data, null);
  assertEquals((await signAs(null)).data, null);
  // Nobody can upload into someone else's folder
  const client = createClient(status.API_URL, anon, { auth: { persistSession: false } });
  await client.auth.signInWithPassword({ email: "ben@weeknotes.test", password: "weeknotes-dev-password" });
  const upload = await client.storage.from("photos").upload(photo.storage_path.replace(/photo-\d/, "intruder"), new Uint8Array([1, 2, 3]), { contentType: "image/jpeg" });
  assertExists(upload.error);
});

Deno.test({
  name: "cleanup",
  fn: async () => {
    await server.shutdown();
    await sql.end();
  },
  sanitizeResources: false,
  sanitizeOps: false,
});
