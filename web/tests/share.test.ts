import assert from "node:assert/strict";
import { test } from "node:test";
import { excerpt, firstName, initials, resolveShare, TOKEN_PATTERN, weekLabel } from "../lib/share.ts";

test("week labels match the app", () => {
  assert.equal(weekLabel("2026-10-19"), "Oct 19 – 25");
  assert.equal(weekLabel("2026-09-28"), "Sep 28 – Oct 4");
  assert.equal(weekLabel("2026-12-28"), "Dec 28 – Jan 3");
});

test("names", () => {
  assert.equal(firstName("Hana Sato"), "Hana");
  assert.equal(initials("Hana Sato"), "HS");
  assert.equal(initials(""), "?");
});

test("tokens are validated before any request", async () => {
  assert.equal(TOKEN_PATTERN.test("short"), false);
  assert.equal(TOKEN_PATTERN.test("AbCdEfGhIjKlMnOpQrStUvWx"), true);
  let called = false;
  const result = await resolveShare("../../etc/passwd", (async () => { called = true; return new Response(); }) as typeof fetch);
  assert.equal(result.status, "not_found");
  assert.equal(called, false);
});

test("the demo link works with no database", async () => {
  const result = await resolveShare("demo");
  assert.equal(result.status, "ok");
  if (result.status === "ok") {
    assert.equal(result.update.author_name, "Hana Sato");
    assert.ok(result.update.memo && result.update.memo.waveform.length === 100);
    assert.ok(excerpt(result.update).length <= 150);
  }
});
