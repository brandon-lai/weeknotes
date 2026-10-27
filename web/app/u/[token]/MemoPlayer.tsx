"use client";

import { useEffect, useRef, useState } from "react";

const RATES = [1, 1.5, 2];
const BARS = 48;

/** ~100 stored values down to BARS, keeping peaks, so the waveform fits a phone-width player. */
function resample(values: number[], count = BARS): number[] {
  if (values.length <= count) return values;
  return Array.from({ length: count }, (_, i) => {
    const start = Math.floor((i * values.length) / count);
    const end = Math.max(start + 1, Math.floor(((i + 1) * values.length) / count));
    return Math.max(...values.slice(start, end));
  });
}

function time(seconds: number) {
  const s = Math.max(0, Math.floor(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

/** The memo player: play/pause, scrub on the waveform, 1x / 1.5x / 2x. Keeps playing with
 *  the screen locked, with lock-screen controls where the browser supports them. */
export default function MemoPlayer({ url, durationMs, waveform, author }: {
  url: string;
  durationMs: number;
  waveform: number[];
  author: string;
}) {
  const audio = useRef<HTMLAudioElement>(null);
  const [playing, setPlaying] = useState(false);
  const [position, setPosition] = useState(0);
  const [rate, setRate] = useState(1);
  const [failed, setFailed] = useState(false);
  const duration = durationMs / 1000;
  const progress = duration > 0 ? Math.min(1, position / duration) : 0;
  const bars = resample(waveform);

  useEffect(() => {
    const el = audio.current;
    if (!el) return;
    const onTime = () => setPosition(el.currentTime);
    const onEnd = () => { setPlaying(false); setPosition(0); };
    el.addEventListener("timeupdate", onTime);
    el.addEventListener("ended", onEnd);
    return () => { el.removeEventListener("timeupdate", onTime); el.removeEventListener("ended", onEnd); };
  }, []);

  useEffect(() => {
    if (audio.current) audio.current.playbackRate = rate;
  }, [rate]);

  async function toggle() {
    const el = audio.current;
    if (!el) return;
    if (playing) {
      el.pause();
      setPlaying(false);
      return;
    }
    try {
      el.playbackRate = rate;
      await el.play();
      setPlaying(true);
      if ("mediaSession" in navigator) {
        navigator.mediaSession.metadata = new MediaMetadata({ title: `${author}'s week`, artist: "Weeknotes" });
        navigator.mediaSession.setActionHandler("pause", () => { el.pause(); setPlaying(false); });
        navigator.mediaSession.setActionHandler("play", () => { void el.play(); setPlaying(true); });
      }
    } catch (error) {
      // NotAllowedError: the browser wants a real tap first (autoplay rules); stay paused
      if (!(error instanceof DOMException && error.name === "NotAllowedError")) setFailed(true);
    }
  }

  function seek(event: React.PointerEvent<HTMLDivElement>) {
    const el = audio.current;
    if (!el || duration <= 0) return;
    const box = event.currentTarget.getBoundingClientRect();
    const fraction = Math.max(0, Math.min(1, (event.clientX - box.left) / box.width));
    el.currentTime = fraction * duration;
    setPosition(el.currentTime);
  }

  function key(event: React.KeyboardEvent<HTMLDivElement>) {
    const el = audio.current;
    if (!el) return;
    if (event.key === "ArrowRight") el.currentTime = Math.min(duration, el.currentTime + 5);
    if (event.key === "ArrowLeft") el.currentTime = Math.max(0, el.currentTime - 5);
  }

  return (
    <div className="player">
      <audio ref={audio} src={url} preload="metadata" onError={() => setFailed(true)} />
      <button className="play" onClick={toggle} aria-label={playing ? `Pause ${author}'s memo` : `Play ${author}'s memo`}>
        {playing ? (
          <svg viewBox="0 0 24 24" aria-hidden="true"><rect x="6" y="5" width="4" height="14" rx="1" /><rect x="14" y="5" width="4" height="14" rx="1" /></svg>
        ) : (
          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5.5v13a1 1 0 0 0 1.5.86l10.5-6.5a1 1 0 0 0 0-1.72L9.5 4.64A1 1 0 0 0 8 5.5z" /></svg>
        )}
      </button>
      <div className="track">
        <div
          className="wave"
          role="slider"
          tabIndex={0}
          aria-label="Position"
          aria-valuemin={0}
          aria-valuemax={Math.round(duration)}
          aria-valuenow={Math.round(position)}
          onPointerDown={seek}
          onPointerMove={(e) => { if (e.buttons === 1) seek(e); }}
          onKeyDown={key}
        >
          {bars.map((v, i) => (
            <span key={i} className={i / bars.length < progress ? "on" : ""} style={{ height: `${Math.max(8, v * 100)}%` }} />
          ))}
        </div>
        <div className="meta">
          <span>{failed ? "Couldn't load the memo" : `${time(position > 0 ? position : duration)}`}</span>
          <button className="rate" onClick={() => setRate(RATES[(RATES.indexOf(rate) + 1) % RATES.length])} aria-label={`Playback speed ${rate}x`}>
            {rate}×
          </button>
        </div>
      </div>
    </div>
  );
}
