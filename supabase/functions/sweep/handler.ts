// Deletes storage files whose rows are gone (deleted updates, replaced memos, deleted
// accounts). Rows are queued by triggers; pg_cron calls this hourly with CRON_SECRET.
import { adminClient, isCron, json } from "../_shared/http.ts";

export async function handle(req: Request): Promise<Response> {
  if (!isCron(req)) return json({ error: "Unauthorized" }, 401);
  const db = adminClient();
  const { data, error } = await db.rpc("take_storage_garbage", { max_rows: 500 });
  if (error) {
    console.error(`[sweep] ${error.message}`);
    return json({ error: "Could not read the queue" }, 500);
  }
  const byBucket = new Map<string, string[]>();
  for (const row of (data ?? []) as { bucket: string; path: string }[]) {
    byBucket.set(row.bucket, [...(byBucket.get(row.bucket) ?? []), row.path]);
  }
  let removed = 0;
  for (const [bucket, paths] of byBucket) {
    const { data: gone, error: removeError } = await db.storage.from(bucket).remove(paths);
    if (removeError) {
      console.error(`[sweep] ${bucket}: ${removeError.message}`);
      // Put them back so the next run retries
      await db.rpc("requeue_storage_garbage", { bucket_name: bucket, paths });
      continue;
    }
    removed += gone?.length ?? 0;
  }
  return json({ removed });
}
