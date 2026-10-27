import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { excerpt, firstName, initials, resolveShare, weekLabel } from "@/lib/share";
import MemoPlayer from "./MemoPlayer";
import Transcript from "./Transcript";

type Props = { params: Promise<{ token: string }> };

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { token } = await params;
  const result = await resolveShare(token);
  if (result.status !== "ok") return { title: "Weeknotes", robots: { index: false, follow: false } };
  const name = firstName(result.update.author_name);
  return {
    title: `${name}'s week · Weeknotes`,
    description: excerpt(result.update),
    robots: { index: false, follow: false },
    openGraph: { title: `${name}'s week`, description: excerpt(result.update), siteName: "Weeknotes", type: "article" },
  };
}

export default async function SharedUpdatePage({ params }: Props) {
  const { token } = await params;
  const result = await resolveShare(token);

  if (result.status === "not_found") notFound();
  if (result.status !== "ok") {
    const copy = {
      expired: ["This link has expired", "Share links stop working after a while, so updates don't travel further than they were meant to. Ask your friend for a fresh one."],
      error: ["Something went wrong", "We couldn't load this update. Try again in a moment."],
    }[result.status];
    return (
      <main className="page narrow">
        <Header />
        <section className="card empty" data-testid="share-unavailable">
          <h1>{copy[0]}</h1>
          <p>{copy[1]}</p>
        </section>
        <Invite appStoreUrl={null} token={null} />
      </main>
    );
  }

  const { update } = result;
  const paragraphs = (update.body_text ?? "").split(/\n{2,}/).map((p) => p.trim()).filter(Boolean);
  return (
    <main className="page narrow">
      <Header />
      <article className="card update" data-testid="shared-update">
        <header className="byline">
          <span className="avatar" aria-hidden="true">{initials(update.author_name)}</span>
          <div>
            <div className="author">{update.author_name}</div>
            <div className="week">Week of {weekLabel(update.week_start)}</div>
          </div>
        </header>
        {update.prompt && <p className="prompt">{update.prompt}</p>}
        {paragraphs.map((p, i) => (
          <p key={i} className="body">{p.split("\n").flatMap((line, j) => (j === 0 ? [line] : [<br key={j} />, line]))}</p>
        ))}
        {update.memo && (
          <div className="memo">
            <MemoPlayer url={update.memo.url} durationMs={update.memo.duration_ms} waveform={update.memo.waveform} author={firstName(update.author_name)} />
            {update.memo.transcript && <Transcript text={update.memo.transcript} />}
          </div>
        )}
        {update.photos.length > 0 && (
          <div className={`photos n${update.photos.length}`}>
            {update.photos.map((photo, i) => (
              // eslint-disable-next-line @next/next/no-img-element -- short-lived signed URLs; no optimizer
              <img key={i} src={photo.url} alt={`Photo ${i + 1} from ${firstName(update.author_name)}`} loading="lazy" />
            ))}
          </div>
        )}
        {result.expiresAt && (
          <p className="expires">This link works until {new Date(result.expiresAt).toLocaleDateString("en-US", { month: "long", day: "numeric" })}.</p>
        )}
      </article>
      <Invite appStoreUrl={result.appStoreUrl} token={token === "demo" ? null : token} name={firstName(update.author_name)} />
    </main>
  );
}

export function Header() {
  return (
    <header className="site">
      <Link href="/" className="wordmark">Weeknotes</Link>
    </header>
  );
}

/** Bringing friends in (PRD §10): read without an account, then post your own week. */
export function Invite({ appStoreUrl, token, name }: { appStoreUrl: string | null; token: string | null; name?: string }) {
  return (
    <section className="invite">
      <h2>Write your own week</h2>
      <p>
        {name ? `${name} uses Weeknotes to tell friends how the week went, once.` : "Weeknotes is a once-a-week update for your friends."}{" "}
        Type it, dictate it, or record a voice memo. Post once and it reaches every circle you choose.
      </p>
      <div className="actions">
        {appStoreUrl ? (
          <a className="button primary" href={appStoreUrl}>Get Weeknotes for iPhone</a>
        ) : (
          <span className="button disabled" aria-disabled="true">Coming soon to the App Store</span>
        )}
        {token && <a className="button" href={`weeknotes://u/${token}`}>Open in the app</a>}
      </div>
      {token && <p className="fine">Join from this link and you'll be connected with {name ?? "your friend"} automatically.</p>}
    </section>
  );
}
