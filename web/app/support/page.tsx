import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = { title: "Help and feedback · Weeknotes" };

export default function Support() {
  const email = process.env.NEXT_PUBLIC_SUPPORT_EMAIL;
  return (
    <main className="page narrow prose">
      <header className="site"><Link href="/" className="wordmark">Weeknotes</Link></header>
      <h1>Help and feedback</h1>
      <h2>Dictation spells a friend's name wrong</h2>
      <p>Fix it once and Weeknotes offers to remember it; fix the same name twice and it learns it on its own. You can also add names, nicknames and places in Settings → Dictionary.</p>
      <h2>A friend can't see my update</h2>
      <p>They need to be your friend in the app and in one of the circles you picked when you posted. You can edit this week's update to change its circles.</p>
      <h2>I didn't get my weekly reminder</h2>
      <p>Check that notifications are on for Weeknotes in iOS Settings, and your reminder day and time in Settings → Reminder. Reminders skip weeks you've already posted.</p>
      <h2>Get in touch</h2>
      <p>
        {email ? <>Email <a href={`mailto:${email}`}>{email}</a>. </> : null}
        Bug reports and ideas are welcome on <a href="https://github.com/brandon-lai/weeknotes/issues">GitHub</a>.
      </p>
    </main>
  );
}
