// Settings → Delete account. Removes the user's memo and photo files, then the auth user;
// every row they own goes with it (foreign keys cascade from auth.users).
import { adminClient, json, requireUser } from "../_shared/http.ts";

async function listAll(bucket: string, prefix: string): Promise<string[]> {
  const db = adminClient();
  const paths: string[] = [];
  const { data: folders } = await db.storage.from(bucket).list(prefix, { limit: 1000 });
  for (const entry of folders ?? []) {
    // Folders come back without an id; files have one
    if (entry.id) {
      paths.push(`${prefix}/${entry.name}`);
    } else {
      const { data: files } = await db.storage.from(bucket).list(`${prefix}/${entry.name}`, { limit: 1000 });
      for (const file of files ?? []) paths.push(`${prefix}/${entry.name}/${file.name}`);
    }
  }
  return paths;
}

export async function handle(req: Request): Promise<Response> {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const user = await requireUser(req);
  if (!user) return json({ error: "Sign in first" }, 401);
  const db = adminClient();

  let files = 0;
  for (const bucket of ["memos", "photos"]) {
    const paths = await listAll(bucket, user.id);
    for (let i = 0; i < paths.length; i += 500) {
      const { data, error } = await db.storage.from(bucket).remove(paths.slice(i, i + 500));
      if (error) {
        console.error(`[delete-account] ${bucket}: ${error.message}`);
        return json({ error: "Couldn't delete your files. Nothing was deleted; try again." }, 500);
      }
      files += data?.length ?? 0;
    }
  }
  const { error } = await db.auth.admin.deleteUser(user.id);
  if (error) {
    console.error(`[delete-account] ${error.message}`);
    return json({ error: "Couldn't delete your account. Try again." }, 500);
  }
  return json({ deleted: true, files });
}
