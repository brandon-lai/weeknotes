// Seeds the LOCAL Supabase stack with a realistic friend group: 10 people in four time zones,
// circles, ten weeks of updates (some with voice memos and photos), reads, reactions,
// replies, a pending friend request and a personal dictionary. Deterministic (seeded PRNG).
//
//   supabase db reset && deno run -A scripts/seed-local.ts
//
// Every account's password is "weeknotes-dev-password" (the app's Developer sign-in).
// Voice memos are spoken by macOS voices (`say`) and encoded like real memos (AAC, mono,
// 64 kbps); photos come from picsum.photos with fixed seeds. Refuses to run against anything
// but 127.0.0.1.
import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import postgres from "npm:postgres@3.4.7";

const status = JSON.parse(
  new TextDecoder().decode((await new Deno.Command("supabase", { args: ["status", "-o", "json"] }).output()).stdout),
);
const API_URL: string = status.API_URL;
const DB_URL: string = status.DB_URL;
if (!API_URL.includes("127.0.0.1") || !DB_URL.includes("127.0.0.1")) throw new Error("Refusing to seed a non-local project");
const admin = createClient(API_URL, status.SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const sql = postgres(DB_URL, { max: 1, onnotice: () => {} });
const PASSWORD = "weeknotes-dev-password";
const CACHE = new URL("../.seed-cache/", import.meta.url).pathname;
await Deno.mkdir(CACHE, { recursive: true });

// ---------- deterministic randomness ----------
let state = 20261026;
function rand() {
  state |= 0;
  state = (state + 0x6d2b79f5) | 0;
  let t = Math.imul(state ^ (state >>> 15), 1 | state);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const pick = <T>(items: T[]) => items[Math.floor(rand() * items.length)];

// ---------- people ----------
type Person = { key: string; name: string; tz: string; phone?: string; voice: string; id?: string };
const people: Person[] = [
  { key: "ana", name: "Ana Morales", tz: "America/New_York", phone: "+15555550101", voice: "Samantha" },
  { key: "ben", name: "Ben Okafor", tz: "America/Chicago", phone: "+15555550102", voice: "Reed (English (US))" },
  { key: "cal", name: "Cal Whitfield", tz: "Europe/London", phone: "+15555550103", voice: "Daniel" },
  { key: "dee", name: "Deepa Raman", tz: "America/Los_Angeles", phone: "+15555550111", voice: "Rishi" },
  { key: "eli", name: "Eli Brooks", tz: "America/New_York", phone: "+15555550112", voice: "Eddy (English (US))" },
  { key: "fay", name: "Fay Morales", tz: "America/Denver", voice: "Karen" },
  { key: "gus", name: "Gus Morales", tz: "America/Denver", voice: "Fred" },
  { key: "hana", name: "Hana Sato", tz: "Asia/Tokyo", phone: "+15555550113", voice: "Moira" },
  { key: "ivy", name: "Ivy Chen", tz: "America/Los_Angeles", voice: "Tessa" },
  { key: "jo", name: "Jo Lindqvist", tz: "Europe/Stockholm", voice: "Shelley (English (UK))" },
];
const by = (key: string) => people.find((p) => p.key === key)!;

for (const person of people) {
  const email = `${person.key}@weeknotes.test`;
  const { data, error } = await admin.auth.admin.createUser({
    email,
    password: PASSWORD,
    email_confirm: true,
    phone: person.phone?.slice(1),
    phone_confirm: Boolean(person.phone),
  });
  if (error) throw new Error(`${email}: ${error.message}`);
  person.id = data.user.id;
}
// An account with no profile yet, for the onboarding flow
await admin.auth.admin.createUser({ email: "new@weeknotes.test", password: PASSWORD, email_confirm: true });

for (const p of people) {
  await sql`insert into public.profiles (id, display_name, timezone, reminder_weekday, reminder_time)
            values (${p.id!}, ${p.name}, ${p.tz}, 0, '18:00')`;
}

// Friendships: Ana knows everyone; the college friends know each other; Jo's request is pending
async function befriend(a: Person, b: Person, status = "accepted", requestedBy = a) {
  const [x, y] = [a.id!, b.id!].sort();
  await sql`insert into public.friendships (user_a, user_b, status, requested_by, created_at)
            values (${x}, ${y}, ${status}, ${requestedBy.id!}, now() - interval '70 days') on conflict do nothing`;
}
for (const p of people) if (p.key !== "ana" && p.key !== "jo") await befriend(by("ana"), p);
await befriend(by("jo"), by("ana"), "pending", by("jo"));
for (const [a, b] of [["ben", "cal"], ["ben", "dee"], ["ben", "eli"], ["cal", "dee"], ["cal", "eli"], ["dee", "eli"], ["fay", "gus"], ["hana", "ivy"], ["ivy", "dee"]]) {
  await befriend(by(a), by(b));
}

// Circles
async function circle(owner: Person, name: string, members: string[]) {
  const [row] = await sql`insert into public.circles (owner_id, name, created_at) values (${owner.id!}, ${name}, now() - interval '60 days') returning id`;
  for (const m of members) await sql`insert into public.circle_members (circle_id, user_id) values (${row.id}, ${by(m).id!})`;
  return row.id as string;
}
const anaCircles = {
  college: await circle(by("ana"), "College", ["ben", "cal", "dee", "eli"]),
  family: await circle(by("ana"), "Family", ["fay", "gus"]),
  books: await circle(by("ana"), "Book club", ["hana", "ivy"]),
};
const friendCircle: Record<string, string> = {};
for (const key of ["ben", "cal", "dee", "eli"]) {
  friendCircle[key] = await circle(by(key), "College", ["ana", ...["ben", "cal", "dee", "eli"].filter((k) => k !== key)]);
}
for (const key of ["fay", "gus"]) friendCircle[key] = await circle(by(key), "Family", ["ana", key === "fay" ? "gus" : "fay"]);
for (const key of ["hana", "ivy"]) friendCircle[key] = await circle(by(key), "Book club", ["ana", key === "hana" ? "ivy" : "hana"]);

// ---------- writing ----------
const updatesBank = [
  "Work was a lot this week. We shipped the thing we've been building since August, and I slept for eleven hours on Saturday to celebrate.\n\nSunday I finally went to the Thai place on Fifth everyone keeps talking about. It lived up to it. Get the khao soi.",
  "Quiet one. Mostly reading and long walks. I'm halfway through the new Sally Rooney and I can't decide if I love it or if it's making me anxious. Probably both.",
  "My sister visited from Denver! We did the whole tourist circuit: the market, the ferry, the ice cream place with the line around the block. My feet hurt and I'm very happy.",
  "Three highlights:\n1. I ran 5 miles without stopping for the first time.\n2. The tomatoes on the balcony finally turned red.\n3. Dee sent me the best voice memo about her neighbor's parrot.",
  "Honestly kind of a rough week. My landlord is selling the building so I'm apartment hunting, which is its own special kind of misery. Send good listing energy.",
  "Started pottery class on Tuesday. I made a bowl that is more of a plate that is more of a sad disc. Going back next week anyway.",
  "Big week at the clinic, short on sleep, long on coffee. Saturday was the first real day off in ages and I spent it in the park doing absolutely nothing. 10 out of 10.",
  "Went to a wedding upstate. The couple wrote their own vows and I cried twice, once during the vows and once when the band played September.",
  "I finally fixed my bike after it sat with a flat for a month. Rode to work twice. Feel like a new person, or at least a person with a working bike.",
  "Small week. Cooked a lot. Made dumplings from scratch with Priya on Thursday, which took four hours and was worth every minute.",
  "Trying to get better at calling people back. Called Grandma on Sunday and she told me the story about the goat again. Still great.",
  "Got the job! Starting in two weeks. Celebrated with tacos and a very small cake.",
  "Moved desks at work so I now sit by a window and my mood has improved by roughly 40 percent.",
  "We hosted game night and it got way too competitive. Ben flipped the Catan board. Not literally. Mostly literally.",
  "Rain all week. Finished a 1,000 piece puzzle of a lighthouse. Not sure what this says about me.",
  "Spent the weekend at the coast with my parents. Dad tried to teach me to fish and we caught nothing and it was perfect.",
  "Saw two movies: one great, one so bad it became great. Ask me about the second one, I have a lot of thoughts.",
  "Ran my first 10K! Slow, but done. Legs are destroyed, heart is full.",
  "Mostly survived a deadline. Celebrated with a nap that lasted until dinner.",
  "New neighbor has a dog named Pickles who now waits for me by the stairs. This is the relationship I didn't know I needed.",
];
const anaBank = [
  "This week was mostly about the move. Boxes everywhere, but the new place gets morning light and I can hear the river at night.\n\nCal, I owe you a call. Saturday?",
  "Quiet week. I read two books and went to the farmers market twice because the peaches are back.",
  "Work trip to Chicago. Saw Ben for dinner on Wednesday. Deep dish was involved. No regrets.",
  "I started learning the guitar again. My fingertips hurt and I can play exactly one song badly.",
  "Long week, good weekend. Hiked up to the reservoir with Eli on Sunday and the leaves are starting to turn.",
  "Mom's birthday dinner was so fun. Gus made his famous lasagna and Fay brought the cake.",
  "Not much to report, and I'm writing it down anyway: walked a lot, slept enough, called Grandma.",
  "Book club picked a 700-page novel and I am on page 40. Hana, please spoil nothing.",
  "Tried the new ramen place, then the bakery next door, then a nap. A perfect Saturday.",
];
const prompts = [null, null, null, "Best part of your week?", "What made you laugh?", "Something small you noticed?", "Who did you see?"];

const memoScripts: Record<string, string> = {
  ben: "Hey everyone. Okay so this week, I finally tried that climbing gym near my place. I could not feel my arms on Thursday. But I'm going back on Monday. Also, Eli, I found your sunglasses in my car. They are safe. Love you all, talk soon.",
  dee: "Hi friends, quick one from the car. The parrot update: my neighbor's parrot has learned to say my name. Only my name. At six in the morning. I'm honored and also very tired. Otherwise a good week, finished the big report, and made soup.",
  hana: "Hello from Tokyo. It's finally cooler here, so I walked along the river every evening this week. On Saturday I went to a tiny jazz bar with eight seats. I think about it constantly now. Ivy, you would love it.",
  fay: "Hi sweetheart, and hi everyone. Your dad and I cleaned out the garage this weekend. We found your old science fair volcano. It still works. We tested it. The neighbors were not thrilled. Call us Sunday.",
  ana: "Okay, my week. I spent most of it unpacking, and I found a box of letters from college. I read all of them on the floor instead of unpacking. No regrets. Talk soon.",
};

async function run(cmd: string, args: string[]) {
  const out = await new Deno.Command(cmd, { args }).output();
  if (!out.success) throw new Error(`${cmd} ${args.join(" ")}: ${new TextDecoder().decode(out.stderr)}`);
}

/** Speaks a memo, encodes it like the app does, and computes its waveform summary. */
async function makeMemo(key: string, voice: string, text: string) {
  const aiff = `${CACHE}${key}.aiff`, m4a = `${CACHE}${key}.m4a`, wav = `${CACHE}${key}.wav`;
  try {
    await Deno.stat(m4a);
  } catch {
    await run("say", ["-v", voice, "-r", "175", "-o", aiff, text]);
    await run("afconvert", ["-f", "m4af", "-d", "aac", "-b", "64000", "-c", "1", aiff, m4a]);
  }
  await run("afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", m4a, wav]);
  const bytes = await Deno.readFile(wav);
  const view = new DataView(bytes.buffer);
  let offset = 12, dataStart = 0, dataLength = 0;
  while (offset < bytes.length - 8) {
    const id = new TextDecoder().decode(bytes.slice(offset, offset + 4));
    const size = view.getUint32(offset + 4, true);
    if (id === "data") { dataStart = offset + 8; dataLength = size; break; }
    offset += 8 + size;
  }
  const count = Math.floor(dataLength / 2);
  const buckets = 100, values: number[] = [];
  for (let b = 0; b < buckets; b++) {
    const start = Math.floor((b * count) / buckets), end = Math.floor(((b + 1) * count) / buckets);
    let sum = 0;
    for (let i = start; i < end; i++) { const s = view.getInt16(dataStart + i * 2, true) / 32768; sum += s * s; }
    values.push(Math.sqrt(sum / Math.max(1, end - start)));
  }
  const peak = Math.max(...values);
  const waveform = values.map((v) => Math.round(Math.sqrt(v / peak) * 1000) / 1000);
  return { bytes: await Deno.readFile(m4a), durationMs: Math.round((count / 16000) * 1000), waveform };
}

async function photo(seed: string) {
  const path = `${CACHE}photo-${seed}.jpg`;
  try {
    return await Deno.readFile(path);
  } catch {
    const response = await fetch(`https://picsum.photos/seed/${seed}/1200/900.jpg`);
    const bytes = new Uint8Array(await response.arrayBuffer());
    await Deno.writeFile(path, bytes);
    return bytes;
  }
}

// ---------- updates ----------
await sql`alter table public.updates disable trigger updates_stamp`;
const [{ now }] = await sql`select now() as now`;

async function weekStart(person: Person, offsetWeeks: number): Promise<string> {
  const [row] = await sql`select (public.week_start_for(now(), ${person.tz}, 12) - ${offsetWeeks * 7}::int)::text as d`;
  return row.d;
}

async function postUpdate(person: Person, offsetWeeks: number, opts: {
  body?: string; prompt?: string | null; circles: string[]; memo?: string; photos?: string[]; postedAt?: string;
}) {
  const week = await weekStart(person, offsetWeeks);
  // Last week's posts land on Saturday or Sunday evening; this week's earlier today
  const postedAt = opts.postedAt ?? (offsetWeeks === 0
    ? new Date(Date.now() - (20 + Math.floor(rand() * 120)) * 60_000).toISOString()
    : (await sql`select ((${week}::date + ${5 + Math.floor(rand() * 2)}::int)::timestamp + interval '17 hours' + ${Math.floor(rand() * 240)} * interval '1 minute') at time zone ${person.tz} as t`)[0].t.toISOString());
  const composed = [opts.body ? (rand() < 0.5 ? "dictated" : "typed") : null, opts.memo ? "memo" : null].filter(Boolean);
  const [row] = await sql`
    insert into public.updates (author_id, week_start, prompt, body_text, body_raw_transcript, composed_with, compose_ms, posted_at)
    values (${person.id!}, ${week}, ${opts.prompt ?? null}, ${opts.body ?? null},
            ${composed.includes("dictated") && opts.body ? opts.body.toLowerCase().replace(/[.,!?:]/g, "") : null},
            ${composed as string[]}, ${180_000 + Math.floor(rand() * 300_000)}, ${postedAt})
    returning id`;
  for (const c of opts.circles) await sql`insert into public.update_audiences (update_id, circle_id) values (${row.id}, ${c})`;
  if (opts.memo) {
    const memo = await makeMemo(`${person.key}-${offsetWeeks}`, person.voice, opts.memo);
    const path = `${person.id}/${row.id}/memo.m4a`;
    const { error } = await admin.storage.from("memos").upload(path, memo.bytes, { contentType: "audio/mp4", upsert: true });
    if (error) throw new Error(error.message);
    await sql`insert into public.voice_memos (update_id, storage_path, duration_ms, waveform, transcript_raw, transcript_clean, engine_id)
              values (${row.id}, ${path}, ${memo.durationMs}, ${sql.json(memo.waveform)},
                      ${opts.memo.toLowerCase().replace(/[.,!?]/g, "")}, ${opts.memo}, 'apple-speech')`;
  }
  for (const [index, seed] of (opts.photos ?? []).entries()) {
    const path = `${person.id}/${row.id}/photo-${index}.jpg`;
    const { error } = await admin.storage.from("photos").upload(path, await photo(seed), { contentType: "image/jpeg", upsert: true });
    if (error) throw new Error(error.message);
    await sql`insert into public.update_photos (update_id, storage_path, position, width, height) values (${row.id}, ${path}, ${index}, 1200, 900)`;
  }
  return row.id as string;
}

// Friends' past nine weeks (most weeks, not all: real groups skip)
let bankIndex = 0;
for (const key of ["ben", "cal", "dee", "eli", "fay", "gus", "hana", "ivy"]) {
  for (let w = 9; w >= 2; w--) {
    if (rand() < 0.25) continue;
    await postUpdate(by(key), w, { body: updatesBank[bankIndex++ % updatesBank.length], prompt: pick(prompts), circles: [friendCircle[key]] });
  }
}

// Last week's posts, read on Monday: some unread (they show in "This week" as late arrivals)
const lastWeek: Record<string, string> = {};
lastWeek.ben = await postUpdate(by("ben"), 1, { body: "Climbing gym update below. Also: I found Eli's sunglasses.", memo: memoScripts.ben, circles: [friendCircle.ben] });
lastWeek.cal = await postUpdate(by("cal"), 1, { body: updatesBank[0], prompt: "Best part of your week?", circles: [friendCircle.cal], photos: ["cal-thai", "cal-street"] });
lastWeek.fay = await postUpdate(by("fay"), 1, { memo: memoScripts.fay, circles: [friendCircle.fay], photos: ["fay-garage"] });
lastWeek.ivy = await postUpdate(by("ivy"), 1, { body: updatesBank[5], circles: [friendCircle.ivy] });

// This week (posted today, after Monday noon in their time zone)
await postUpdate(by("dee"), 0, { body: "Parrot news, in audio form. The written version: he knows my name now.", memo: memoScripts.dee, circles: [friendCircle.dee] });
await postUpdate(by("hana"), 0, { body: updatesBank[2], prompt: "Something small you noticed?", circles: [friendCircle.hana], photos: ["hana-river", "hana-bar", "hana-tea"], postedAt: new Date(Date.now() - 50 * 60_000).toISOString() });
await postUpdate(by("eli"), 0, { body: updatesBank[3], circles: [friendCircle.eli] });
await postUpdate(by("gus"), 0, { body: "Made the lasagna again. Fay says it was the best one yet, which she says every time, which I choose to believe every time.", circles: [friendCircle.gus], photos: ["gus-lasagna"] });

// Ana's own archive (eight past weeks; one archive-only)
const anaUpdates: string[] = [];
for (let w = 9; w >= 1; w--) {
  const body = anaBank[(9 - w) % anaBank.length];
  const circles = w === 6 ? [] : w % 3 === 0 ? [anaCircles.college, anaCircles.family, anaCircles.books] : [anaCircles.college, anaCircles.family];
  anaUpdates.push(await postUpdate(by("ana"), w, { body, prompt: w === 4 ? "Best part of your week?" : null, circles, memo: w === 2 ? memoScripts.ana : undefined, photos: w === 5 ? ["ana-hike"] : [] }));
}
await sql`alter table public.updates enable trigger updates_stamp`;

// Reads: Ana has read Ivy's and Gus's; Cal, Ben and Dee are unread. Friends read Ana's.
await sql`insert into public.reads (update_id, user_id, read_at)
          select id, ${by("ana").id!}, now() - interval '1 hour' from public.updates
          where author_id <> ${by("ana").id!} and (week_start < public.week_start_for(now(), 'America/New_York', 12) - 7
             or id in (${lastWeek.ivy}))`;
await sql`insert into public.reads (update_id, user_id, read_at)
          select u.id, ${by("ana").id!}, now() - interval '30 minutes' from public.updates u
          where u.author_id = ${by("gus").id!} and u.week_start >= public.week_start_for(now(), 'America/Denver', 12)`;
for (const id of anaUpdates) {
  for (const key of ["ben", "cal", "fay", "hana"]) {
    if (rand() < 0.7) await sql`insert into public.reads (update_id, user_id, listened_ms) values (${id}, ${by(key).id!}, ${Math.floor(rand() * 40000)}) on conflict do nothing`;
  }
}

// Reactions on Ana's updates
for (const id of anaUpdates.slice(-5)) {
  for (const [key, emoji] of [["ben", "❤️"], ["cal", "😂"], ["fay", "🥹"], ["dee", "🔥"]] as const) {
    if (rand() < 0.6) await sql`insert into public.reactions (update_id, user_id, emoji) values (${id}, ${by(key).id!}, ${emoji}) on conflict do nothing`;
  }
}

// Replies: Ben and Cal wrote back about Ana's latest; one unread
async function thread(a: Person, b: Person) {
  const [x, y] = [a.id!, b.id!].sort();
  const [row] = await sql`insert into public.threads (user_a, user_b) values (${x}, ${y}) returning id`;
  return row.id as string;
}
const latest = anaUpdates[anaUpdates.length - 1];
const benThread = await thread(by("ana"), by("ben"));
await sql`insert into public.messages (thread_id, sender_id, update_id, body, created_at) values
  (${benThread}, ${by("ben").id!}, ${latest}, 'Ok I need to know which ramen place. Sending this to my brother.', now() - interval '20 hours'),
  (${benThread}, ${by("ana").id!}, null, 'Menya Kono on 3rd! Get the spicy miso.', now() - interval '19 hours'),
  (${benThread}, ${by("ben").id!}, null, 'Going Friday. Report to follow.', now() - interval '3 hours')`;
await sql`insert into public.thread_reads (thread_id, user_id, last_read_at) values (${benThread}, ${by("ana").id!}, now() - interval '18 hours')`;
const calThread = await thread(by("ana"), by("cal"));
await sql`insert into public.messages (thread_id, sender_id, update_id, body, created_at) values
  (${calThread}, ${by("cal").id!}, ${anaUpdates[0]}, 'Saturday works. 10am your time?', now() - interval '6 days'),
  (${calThread}, ${by("ana").id!}, null, 'Perfect. Talk then.', now() - interval '6 days')`;
await sql`insert into public.thread_reads (thread_id, user_id, last_read_at) values (${calThread}, ${by("ana").id!}, now())`;

// Ana's dictionary
await sql`insert into public.user_dictionary (user_id, written, sounds_like, source) values
  (${by("ana").id!}, 'Jaylen', ${["jalen", "jay lynn"]}, 'manual'),
  (${by("ana").id!}, 'Menya Kono', ${["manya kono"]}, 'learned'),
  (${by("ana").id!}, 'Priya', ${[]}, 'manual')`;

const [{ count }] = await sql`select count(*)::int as count from public.updates`;
console.log(`Seeded ${people.length} people, ${count} updates (now: ${now.toISOString()}). Password: ${PASSWORD}`);
await sql.end();
