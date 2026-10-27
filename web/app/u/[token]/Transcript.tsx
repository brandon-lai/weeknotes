"use client";

import { useState } from "react";

/** The transcript under a memo: three lines, then "Show full transcript". */
export default function Transcript({ text }: { text: string }) {
  const [open, setOpen] = useState(false);
  const long = text.length > 160;
  return (
    <div className="transcript">
      <p className={open || !long ? "" : "clamped"}>{text}</p>
      {long && !open && (
        <button className="link" onClick={() => setOpen(true)}>Show full transcript</button>
      )}
    </div>
  );
}
