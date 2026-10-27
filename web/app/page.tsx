import Link from "next/link";
import { appStoreUrl } from "@/lib/share";

export default function Home() {
  const store = appStoreUrl();
  return (
    <main className="page wide">
      <header className="site">
        <span className="wordmark">Weeknotes</span>
        <nav>
          <Link href="/u/demo">See an example</Link>
          <Link href="/privacy">Privacy</Link>
        </nav>
      </header>

      <section className="hero">
        <h1>Once a week, tell your friends how it went.</h1>
        <p>
          Post one update and it reaches every circle you choose: college friends, family, the book club.
          No more pasting the same message into five group chats, and every week saves to your own archive.
        </p>
        <div className="actions">
          {store ? (
            <a className="button primary" href={store}>Get Weeknotes for iPhone</a>
          ) : (
            <span className="button disabled" aria-disabled="true">Coming soon to the App Store</span>
          )}
          <Link className="button" href="/u/demo">See an example update</Link>
        </div>
      </section>

      <section className="modes" aria-label="Three ways to write">
        <div className="card">
          <h3>Type it</h3>
          <p>A few lines or a few paragraphs. Pick a prompt if you're stuck: “Best part of your week?”</p>
        </div>
        <div className="card">
          <h3>Dictate it</h3>
          <p>Talk, and it becomes text. Fillers and false starts are cleaned up; the words stay yours, and the original is one tap away.</p>
        </div>
        <div className="card">
          <h3>Record a voice memo</h3>
          <p>Friends hear your actual voice, with a transcript underneath to skim. Up to five minutes, playable at 2×.</p>
        </div>
      </section>

      <ul className="principles">
        <li><strong>Once a week, on purpose.</strong><span>One update per person per week. About five minutes to write, ten to catch up on everyone.</span></li>
        <li><strong>Write for yourself first.</strong><span>Every update saves to your archive, even if you share it with no one.</span></li>
        <li><strong>Friends only, chosen per circle.</strong><span>You decide who sees each update. No public profiles, no followers, no ranking, no ads.</span></li>
        <li><strong>A finite feed.</strong><span>When you've read or heard everyone, the app says you're caught up.</span></li>
      </ul>

      <footer className="foot">
        <span>© {new Date().getFullYear()} Weeknotes</span>
        <Link href="/privacy">Privacy policy</Link>
        <Link href="/support">Help and feedback</Link>
      </footer>
    </main>
  );
}
