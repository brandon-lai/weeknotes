import Link from "next/link";

export default function ShareNotFound() {
  return (
    <main className="page narrow">
      <header className="site"><Link href="/" className="wordmark">Weeknotes</Link></header>
      <section className="card empty" data-testid="share-unavailable">
        <h1>This update isn&apos;t here</h1>
        <p>The link may be mistyped, or the update was deleted.</p>
      </section>
      <section className="invite">
        <h2>Write your own week</h2>
        <p>Weeknotes is a once-a-week update for your friends. Type it, dictate it, or record a voice memo, and post once to every circle you choose.</p>
        <div className="actions"><Link className="button primary" href="/">Learn more</Link></div>
      </section>
    </main>
  );
}
