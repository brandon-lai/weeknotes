import Link from "next/link";

export default function NotFound() {
  return (
    <main className="page narrow">
      <header className="site"><Link href="/" className="wordmark">Weeknotes</Link></header>
      <section className="card empty">
        <h1>Nothing here</h1>
        <p>This page doesn't exist. <Link href="/">Go to Weeknotes</Link>.</p>
      </section>
    </main>
  );
}
