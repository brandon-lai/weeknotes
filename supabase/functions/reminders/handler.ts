// Weekly reminders (PRD §12, M7). pg_cron calls this every 15 minutes with CRON_SECRET. It
// asks Postgres who is due (local reminder time just passed, no update this week, not yet
// reminded), sends each a push, and logs the week so nobody gets two.
import { apnsConfigFromEnv, type ApnsConfig, sendPush } from "../_shared/apns.ts";
import { adminClient, isCron, json } from "../_shared/http.ts";

export const REMINDER = {
  aps: {
    alert: { title: "Weeknotes", body: "Your week is ready to write." },
    sound: "default",
    "thread-id": "weekly-reminder",
  },
  link: "weeknotes://compose",
};

type Due = { user_id: string; week_start: string; tokens: { token: string; environment: string }[] };

export async function handle(req: Request, config: ApnsConfig | null = apnsConfigFromEnv(), at?: string): Promise<Response> {
  if (!isCron(req)) return json({ error: "Unauthorized" }, 401);
  if (!config) return json({ sent: 0, skipped: "APNs is not configured" });

  const db = adminClient();
  const { data, error } = await db.rpc("due_reminders", at ? { at_time: at } : {});
  if (error) {
    console.error(`[reminders] ${error.message}`);
    return json({ error: "Could not list reminders" }, 500);
  }
  const due = (data ?? []) as Due[];
  let sent = 0;
  let failed = 0;
  const stale: string[] = [];
  for (const person of due) {
    let delivered = false;
    for (const device of person.tokens ?? []) {
      const result = await sendPush(config, device, REMINDER);
      if (result.ok) delivered = true;
      else if (result.unregistered) stale.push(device.token);
      else console.error(`[reminders] APNs ${result.status} ${result.reason ?? ""}`);
    }
    if (delivered) {
      // Only a delivered reminder counts; a failed one is retried on the next run (within the hour)
      const { error: logError } = await db.from("reminder_log").insert({ user_id: person.user_id, week_start: person.week_start });
      if (logError && logError.code !== "23505") console.error(`[reminders] log: ${logError.message}`);
      sent++;
    } else {
      failed++;
    }
  }
  if (stale.length) await db.from("push_tokens").delete().in("token", stale);
  return json({ due: due.length, sent, failed, removed_tokens: stale.length });
}
