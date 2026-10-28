import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = { title: "Privacy policy · Weeknotes" };

export default function Privacy() {
  const email = process.env.NEXT_PUBLIC_SUPPORT_EMAIL;
  return (
    <main className="page narrow prose">
      <header className="site"><Link href="/" className="wordmark">Weeknotes</Link></header>
      <h1>Privacy policy</h1>
      <p className="updated">Last updated October 28, 2026</p>

      <p>
        Weeknotes is a weekly journal that you can share with friends. This page explains what we store, why,
        who else touches it, and how to delete it. The short version: without an account your weeks stay on
        your phone; with one, they go only to the circles you pick; we don't sell or share your data for
        advertising; and you can delete everything at any time.
      </p>

      <h2>Without an account</h2>
      <p>
        Your weeks, voice memos, photos, drafts and personal dictionary are stored on your iPhone, and weekly
        reminders are scheduled on your iPhone. Nothing is uploaded, with one exception: if your iPhone can&apos;t
        clean up dictated text or transcribe a memo on its own, that text or audio is sent to our server for
        processing (see the services below) under an anonymous session that isn&apos;t linked to you, and it
        isn&apos;t kept.
      </p>

      <h2>With an account</h2>
      <p>
        An account is optional. It lets you connect with friends and share weeks, and it keeps a private backup
        of your weeks, including those written before you signed up.
      </p>

      <h2>What we store for an account</h2>
      <ul>
        <li><strong>Your account:</strong> the identifier Sign in with Apple gives us, and the name you choose to show friends.</li>
        <li><strong>Your phone number, if you add it:</strong> only as a scrambled (hashed) value used to match you with friends who have your number. It is never shown to anyone.</li>
        <li><strong>Your updates:</strong> text, voice memos, their transcripts (the cleaned-up version and the original), photos, and which circles each update went to.</li>
        <li><strong>Your social graph:</strong> friends, the circles you create, reactions, private replies, and which updates you've read or listened to (so the feed can say you're caught up).</li>
        <li><strong>Settings:</strong> your time zone (which decides the week an update belongs to) and your personal dictionary of names and words.</li>
      </ul>

      <h2>What we don't store</h2>
      <ul>
        <li><strong>Dictation audio.</strong> When you dictate, audio is turned into text on your phone and thrown away. Only text is uploaded.</li>
        <li><strong>Your contacts.</strong> To find friends, phone numbers from your address book are scrambled on your phone and compared on our server; nothing from your contacts is kept.</li>
        <li><strong>Photo metadata.</strong> Photos are re-encoded on your phone before upload, which removes location and camera details.</li>
      </ul>

      <h2>Who can see your updates</h2>
      <p>
        You, and accepted friends who are in a circle you shared that update with. Readers don't see who
        else an update went to, and reactions are visible only to you and the person who reacted. If you
        create a share link, anyone with the link can read or listen to that one update until the link
        expires. Voice memos and photos are kept in private storage and are only reachable through links
        that expire within hours.
      </p>

      <h2>Services that process your data</h2>
      <ul>
        <li><strong>Supabase</strong> hosts our database, file storage and server functions.</li>
        <li><strong>Apple</strong> handles Sign in with Apple. Speech-to-text and text cleanup normally run on your iPhone with Apple's on-device models.</li>
        <li><strong>Anthropic</strong> (Claude) cleans up dictated text only when your iPhone can't do it on device. The text is sent for formatting and isn't used to train models.</li>
        <li><strong>OpenAI</strong> transcribes a voice memo only when on-device transcription fails. The audio is sent for transcription and isn't used to train models.</li>
        <li><strong>Vercel</strong> hosts this website and the pages behind share links.</li>
      </ul>

      <h2>Deleting your data</h2>
      <p>
        Delete any week from the app and its memo and photos are deleted with it, on your phone and on our
        server. Settings → Delete account removes your profile and everything you&apos;ve shared, backed up, reacted
        or replied, permanently; the weeks on your phone stay until you choose Settings → Erase this
        iPhone&apos;s weeks.
      </p>

      <h2>Children</h2>
      <p>Weeknotes isn't meant for children under 13, and we don't knowingly collect their data.</p>

      <h2>Contact</h2>
      <p>
        Questions or requests: {email ? <a href={`mailto:${email}`}>{email}</a> : <Link href="/support">our support page</Link>}.
        If this policy changes in a way that matters, we'll say so in the app first.
      </p>
    </main>
  );
}
