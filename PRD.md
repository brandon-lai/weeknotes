# Weekly Update App: PRD

Working title: Weekly Update App (name TBD)
Owner: Brandon
Last updated: October 26, 2026
Status: Ready for build (Phase 0)

---

## Notes for Claude Code

- Build in the milestone order under "Build plan". Each milestone has acceptance criteria; treat those as the definition of done.
- Decisions marked **Decided** are settled. Items under "Open questions" are not: use the stated MVP default, keep it easy to change (config value or feature flag), and do not invent a different answer.
- All speech-to-text goes through one `TranscriptionEngine` protocol so engines can be swapped and compared. Do not call a specific engine directly from UI code.
- Never present AI-cleaned text as the only version of what a user said. The raw transcript is always stored and viewable.
- Dictation formatting is a pipeline of five stages (section 8, "Dictation formatting"). Only one stage uses an LLM. Build the other stages as plain, unit-tested code, and make the golden test set pass before tuning anything else.

---

## 1. Overview

A friends-only iOS app where, once a week, you log an update about your week and it shows up in the feed of every friend and group you choose. You post once instead of pasting the same message into several group chats.

You can log your update three ways:

1. **Type** it.
2. **Dictate** it: speak, and it becomes text. The audio is thrown away.
3. **Record a voice memo**: your friends hear your actual voice, with a transcript underneath.

**The problem.** Many friend groups already share weekly updates in a group chat. It breaks down in three ways:

- If you're in several groups, you copy and paste the same update into each one.
- Updates get buried under the day-to-day chatter of the chat.
- There's no record you can look back on.

**The bet.** If posting takes about five minutes and reading everyone takes about ten, people will keep the ritual going with more friends than one group chat holds, including the ones they rarely see.

## 2. Goals and non-goals

**Goals**

- Make the weekly update a short ritual: post in about five minutes, catch up on everyone in about ten.
- Post once and reach every circle you choose.
- Give each person a private archive of their weeks, so the app is useful even when nobody reads.
- Let friends hear each other's voices, not just read text.

**Non-goals**

- Public profiles, followers, creators, or algorithmic ranking.
- Daily posting or real-time chat.
- Photo-first sharing. Photos support the update; they are not the main act.
- Ads.

## 3. Target users

The first users are groups that already share weekly updates in a group chat.

| Who | Situation | What they want |
| --- | --- | --- |
| Friend in several groups | In two to five chats that each do updates | Post one update, not five |
| Scattered friends | College or hometown friends now in different cities | Stay in each other's lives without scheduling calls |
| Reflective writer | Likes the idea of journaling, doesn't stick with it | A weekly nudge and a record of what happened |
| Mostly-listener | Enjoys hearing from friends, posts less | Catch up on everyone in one sitting, maybe on a walk |

## 4. Existing alternatives

| Alternative | What it does well | Where it falls short here |
| --- | --- | --- |
| Group chat updates | Everyone is already there | Copy-paste per group, buried by chatter, no archive |
| Retro | Weekly, friends-only photo journal; you post at least one photo a week to see friends' posts | Photo-first; writing and voice are secondary |
| Instagram Close Friends stories | Reach and habit | Gone in 24 hours, performative |
| Personal newsletter (Substack) | Long-form writing with an archive | One-to-many broadcast; no feed of friends |
| Journaling apps (Day One) | Reflection and archive | No sharing |
| Voice notes in a group chat | You hear the person | Same copy-paste and burial problems; no transcript to skim |

**Where this app is different:** writing and voice first, one post sent to many circles, a private archive of your weeks, and voice memos that come with a transcript so they can be skimmed or listened to.

## 5. Product principles

1. **Once a week, on purpose.** One update per person per week.
2. **Write for yourself first.** Every update saves to your archive, even if you share it with no one.
3. **Your voice, not the AI's.** Cleanup removes filler words and adds punctuation. It never rewrites what you said, and the original is always one tap away.
4. **Friends only, chosen per circle.** You decide who sees each update.
5. **A finite feed.** When you've read or heard everyone, the app says you're caught up.

## 6. Decisions

| Area | Decision | Status |
| --- | --- | --- |
| Platform | Native iOS, SwiftUI, minimum iOS 26 | Decided |
| Backend | Supabase: Postgres, Auth, Storage, Edge Functions, pg_cron | Decided |
| Auth | Sign in with Apple, plus phone number for contact matching | Decided |
| Web reader for share links | Next.js on Vercel | Decided |
| Default speech-to-text engine | Apple SpeechAnalyzer, on device | Decided for MVP, revisit after bake-off |
| Alternate engine | WhisperKit running Whisper large-v3-turbo, on device | Build behind the same protocol for the bake-off |
| Dictation formatting | Five-stage pipeline (section 8, "Dictation formatting"): name biasing, spoken commands, dictionary, LLM formatting, validator | Decided |
| Formatting model | Apple Foundation Models on device; small hosted model as fallback | Decided for MVP, revisit after bake-off |
| Voice memo format | AAC, mono, 64 kbps, max 5 minutes | Decided |
| Dictation audio | Not stored. Only text is uploaded | Decided |
| Voice memo audio | Stored in private storage, served by signed URL | Decided |

## 7. Speech-to-text: options and recommendation

### What the products people compare against actually use

- **Wispr Flow** is not a model you can use. It's a cloud-only dictation app. It was built on OpenAI's open-source Whisper for transcription plus Meta's Llama for cleanup. In August 2026 Wispr previewed its own proprietary speech model, Canto, which isn't available to outside developers.
- **Open-source dictation apps** use the same two-step pattern. VoiceInk (macOS, GPLv3) transcribes on device with whisper.cpp, with NVIDIA Parakeet (via FluidAudio) and Apple's Speech framework as alternatives, then runs an AI cleanup pass through a cloud model, a local Ollama server, or a local MLX model. OpenWhispr offers Whisper and Parakeet models in the same way.
- **License note:** VoiceInk is GPLv3. Read it for ideas, but don't copy its code into this app unless the app is also released under GPL. Whisper itself (weights and code) is MIT and safe to use.

So the "Wispr Flow feel" comes from two things: a good speech model, and a cleanup pass that removes ums and fixes punctuation. Both are available without Wispr.

### OpenAI Whisper in detail

- Open weights under the MIT license, so it can run on the phone or on our own server with no per-minute fee.
- **large-v3**: about 1.55B parameters, the most accurate Whisper checkpoint.
- **large-v3-turbo**: about 809M parameters. Same encoder, decoder cut from 32 layers to 4, roughly 2 to 5 times faster with nearly the same accuracy. One published benchmark ran 10 minutes of audio through turbo in 82 seconds on an iPhone 15 Pro.
- Runs on iPhone through **WhisperKit** (Argmax, Core ML) or **whisper.cpp**.
- Handles 100+ languages and accepts custom vocabulary hints, which helps with friends' names.
- Trade-off: the model has to be downloaded to the phone on first use, which adds a large one-time download.

### Hosted options from OpenAI (if we transcribe on a server instead)

| Model | Approx. price | Notes |
| --- | --- | --- |
| whisper-1 (hosted Whisper) | $0.006 / min | The original API |
| gpt-4o-transcribe | $0.006 / min | OpenAI says lower word error rate than Whisper |
| gpt-4o-mini-transcribe | $0.003 / min | Cheapest; a third-party tracker lists it as retiring Feb 26, 2027 |
| gpt-transcribe | $0.0045 / min | Newer model per a third-party price tracker; confirm on OpenAI's pricing page before using |

At these prices a 3-minute voice memo costs about 1 to 2 cents to transcribe.

### Full comparison

| Engine | Runs on | Strengths | Weaknesses |
| --- | --- | --- | --- |
| Apple `SpeechTranscriber` | Device, iOS 26+ | Free, no model download to manage, fast; one benchmark put clean English at 2.12% word error rate, ahead of every on-device Whisper size tested | Ignores custom vocabulary; fewer languages |
| Apple `DictationTranscriber` | Device, iOS 26+ | Built for dictation; accepts up to 100 contextual phrases (friends' names) and custom language models | Uses the older on-device model path; accuracy vs. `SpeechTranscriber` untested |
| Whisper large-v3-turbo via WhisperKit | Device | Open (MIT), 100+ languages, custom vocabulary; won English in a separate test on messier real-world speech | Large model download; more battery and heat |
| NVIDIA Parakeet (via FluidAudio) | Device | Reported to do best on rambling, um-heavy speech | Smaller ecosystem on iOS |
| OpenAI hosted models | Server | Easy, accurate, no model on the phone | Per-minute cost; audio leaves the phone |

### Recommendation

1. **Live dictation:** Apple SpeechAnalyzer by default, because it's free, fast, and gives live partial results while you talk. Start M1 with `SpeechTranscriber`; the bake-off decides whether `DictationTranscriber` wins on names.
2. **Voice memos:** transcribe on device with the same engine before upload. Keep a server-side fallback (a hosted OpenAI model) for memos where on-device transcription fails.
3. **Build WhisperKit (large-v3-turbo) behind the same protocol** and run a bake-off in Phase 0. Weekly updates are casual, rambling speech full of friends' names, which is exactly where Whisper's custom vocabulary may win. Let real recordings decide.

### Bake-off plan (Phase 0)

- Record 20 real weekly updates (dictation and memos, quiet and noisy rooms).
- Run each through `SpeechTranscriber`, `DictationTranscriber` with contextual strings, WhisperKit turbo with a name glossary prompt, and one hosted OpenAI model.
- Score on: friends' names spelled right, slang, overall readability after formatting, time to final text, and battery/heat for a 5-minute memo.
- Also compare two formatting models: Apple's on-device Foundation Models and a small hosted model (for example Claude Haiku). Both must pass the golden test set; then compare on the 20 real recordings.

## 8. Logging modes

| Mode | What the author does | What friends get | Audio stored? |
| --- | --- | --- | --- |
| Type | Types in the composer | Text | No |
| Dictate | Taps mic, speaks, edits the cleaned-up text | Text | No |
| Voice memo | Records up to 5 minutes | Audio player plus transcript | Yes |

An update can combine modes: for example, a typed or dictated body plus one voice memo plus up to 4 photos. At least one of text or a voice memo is required.

### Dictation spec

- Tap mic to start, tap again to stop. Live partial text appears while speaking.
- When recording stops, run the dictation formatting pipeline (see "Dictation formatting" below). Show the formatted text in the editor.
- "Show original" toggle shows the raw transcript; undo restores it.
- Dictated text is inserted at the cursor, so typing and dictating can mix.
- Audio buffers are discarded after transcription.

### Voice memo spec

**Recording**

- Big record button; pause and resume; a timer counting toward the 5-minute limit.
- Live waveform while recording.
- After stopping: play back, re-record, or keep. (Trimming is a later feature.)
- Encode as AAC, mono, 64 kbps (about 0.5 MB per minute).
- Compute a waveform summary on device (about 100 amplitude values) and upload it with the audio so players render instantly.
- Transcribe on device after recording. The author can edit the transcript before posting.

**Playback (reader side)**

- Inline player on the feed card and the detail view: play/pause, scrubbing on the waveform, speed 1x / 1.5x / 2x.
- Transcript shown below the player, collapsed to 3 lines with "Show full transcript".
- Playback continues with the screen locked (background audio session).
- Track how much of each memo a reader listened to (for read coverage metrics).

**Storage and privacy**

- Private Supabase Storage bucket. Audio served only through short-lived signed URLs to users allowed to see the update.
- Share links (web reader) also play the memo through signed URLs that expire with the link.
- Deleting an update deletes its audio file.

**Later:** "Play all" to listen to every friend's memo back to back like a podcast; trimming; word-by-word transcript highlighting during playback.

### Dictation formatting (Wispr Flow parity)

Goal: dictated text comes out the way Wispr Flow's does. Filler words are gone, self-corrections are applied, lists and paragraphs are formatted, friends' names are spelled right, and the words are still the speaker's own. The same pipeline runs on voice memo transcripts, except stage 2 (spoken commands), which is dictation only.

#### What Wispr Flow does

| Behavior | What it does | Example |
| --- | --- | --- |
| Smart Formatting | Removes filler words; fixes grammar, punctuation, and capitalization. Its docs say it does **not** fix misheard words | |
| Backtrack | Applies self-corrections triggered by "actually", "scratch that", "never mind", or restating. Leaves alone statements that aren't corrections | "coffee at 2 actually 3" becomes "coffee at 3" |
| Lists | Sequence words ("first... second...") or numbers ("one... two...") become a list | |
| Spoken commands | "period", "comma", "question mark", "exclamation point", "colon", "semicolon", "new line", "new paragraph". These work even with Smart Formatting off | |
| Dictionary | Learns names, acronyms, and jargon from your corrections; can also be edited by hand | |
| Undo AI edit | Restores the unformatted dictation | |
| Failure fallback | If formatting fails, it pastes the raw transcript | |
| Em dashes | Not inserted automatically | |

How it's built: speech recognition, then a fine-tuned Llama model that formats the transcript. Wispr targets under 700 ms end to end at p99, with the Llama step generating 100+ tokens in under 250 ms. It learns from user edits on device.

**The key lesson:** accuracy and formatting are separate problems. An LLM formatting pass makes text read well, but it can't reliably fix a name the speech model misheard. Names have to be fixed earlier, by biasing the speech model and by a personal dictionary. This pipeline handles both.

#### Pipeline

```
mic
 → 1. Recognize (speech model biased toward friends' names and dictionary words)
 → 2. Spoken commands (deterministic: "new paragraph", "comma", ...)
 → 3. Dictionary (deterministic: fix known mishearings of names and terms)
 → 4. Smart formatting (LLM: fillers, backtrack, punctuation, lists, numbers)
 → 5. Validate (reject output that adds or drops content; fall back safely)
 → editor
      ↑ user edits feed back into the dictionary
```

Stages 2, 3, and 5 are plain code, so they're predictable and testable. Only stage 4 uses an LLM.

**Stage 1: Recognize with name biasing**

Build a vocabulary list for each user: friends' display names (first and last), circle names, and all dictionary entries. Pass it to the engine:

| Engine | How to bias | Limit |
| --- | --- | --- |
| Apple `DictationTranscriber` | `AnalysisContext.contextualStrings`; optional custom language model through `ContentHint.customizedLanguage` | Up to 100 phrases |
| Apple `SpeechTranscriber` | Not supported: Apple confirmed it ignores contextual strings. Names get fixed in stages 3 and 4 | |
| WhisperKit (Whisper) | Prompt text written as a glossary, e.g. "Friends: Maya, Jaylen, Priya." Whisper copies the prompt's spelling and style but does not follow instructions in it | 224 tokens; only the last 224 count, so put names at the end |
| OpenAI hosted | `prompt` parameter, same glossary approach | |

If the vocabulary has more than 100 entries, rank by recency of interaction (friends in the circles last posted to, then most recent replies).

If the engine reports per-word confidence, keep it. Words below a threshold get a light underline in the editor so the user can check them. (Confirm which engines expose confidence while building M1. Skip this if none do.)

**Stage 2: Spoken commands (dictation only)**

Deterministic replacement before the LLM sees the text:

| Spoken | Output |
| --- | --- |
| "period", "full stop" | `.` |
| "comma" | `,` |
| "question mark" | `?` |
| "exclamation point", "exclamation mark" | `!` |
| "colon" / "semicolon" | `:` / `;` |
| "new line", "next line", "line break" | marker `[[NL]]` |
| "new paragraph" | marker `[[P]]` |

- Treat a phrase as a command only when word timings show a pause right after it, or it ends the dictation. Otherwise leave it as words ("the period of time" stays). The pause threshold is a config value; start at 300 ms.
- The LLM is told to keep `[[NL]]` and `[[P]]` exactly where they are. Markers are converted to line breaks after validation.

**Stage 3: Dictionary**

- Each entry has a written form (exact spelling and case) and optional "sounds like" variants. Example: written "Jaylen", sounds like "Jalen", "Jay Lynn".
- Replace exact variant matches, case-insensitive, on word boundaries.
- Also replace close matches: phonetic match (Double Metaphone) plus edit distance of 2 or less, only for words not in a common-English word list. This catches new mishearings without touching normal words.
- Friends' names are automatic entries. Users add their own (nicknames, places, inside jokes) in Settings > Dictionary.

**Stage 4: Smart formatting (LLM)**

Model choice:

1. **Primary: Apple Foundation Models**, on device. Free, private, works offline. Requires a device with Apple Intelligence turned on. The context window is 4K tokens, shared by prompt and output.
2. **Fallback: a small hosted model** (for example Claude Haiku), called through a Supabase Edge Function so API keys stay on the server. It's used when the device model is unavailable (`deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady`), when a safety guardrail throws, or when the validator rejects the on-device output.
3. The bake-off decides whether the hosted model should be the default instead.
4. **Later:** fine-tune a small open model on consented pairs of raw text and the user's final text. That's the approach Wispr uses (fine-tuned Llama) and VoiceInk uses (VoiceInk Refine, fine-tuned from Gemma, Apache-2.0).

Chunking: the 4K window means about 1,000 words per call after the prompt. Split longer input at `[[P]]` markers, then at sentence boundaries near 600 words. Format chunks in order.

Latency target: formatted text within 1.5 seconds of tapping stop, for a 60-second dictation. We're an in-app composer, not a system keyboard, so this is looser than Wispr's 700 ms. While the user talks, show the live raw text. On stop, keep the raw text on screen with a subtle shimmer, then swap in the formatted version.

Formatting rules:

- Remove filler words (um, uh, er, "you know", "I mean", and "like" only when used as filler), false starts, and stutters.
- Apply backtrack: when the speaker corrects themselves ("actually", "scratch that", "no wait", "I mean", "never mind", or a restatement), keep only the corrected version. Leave these words alone when they aren't corrections ("the show was actually good").
- Add punctuation and capitalization. Break into paragraphs at clear topic changes, or every 4 to 6 sentences.
- Make a numbered list when the speaker enumerates with "first, second, third" or "one, two, three". Make a bulleted list when they say "a few things" or "a couple things" and then name them. Otherwise, no lists.
- Write times, dates, money, distances, and other measurements as digits ("6:30 am", "$40", "3.1 miles"). Write other numbers from one to nine as words.
- Keep the speaker's slang, contractions, and tone. Never formalize ("gonna" stays).
- Never add facts, words, emoji, headings, or summaries. Never insert em dashes.
- Keep `[[NL]]` and `[[P]]` markers exactly as given.
- Use the dictionary spellings given in the prompt.
- If unsure, keep the original wording.

Prompt for the formatting model (the few-shot examples are part of the prompt):

```
You format a transcript of someone speaking about their week. Their friends will read it.
Your job is formatting only. The words must stay the speaker's own.

Do:
- Remove filler words (um, uh, er, you know, I mean, and "like" only when it is filler),
  false starts, and stutters.
- When the speaker corrects themselves ("actually", "scratch that", "no wait", "never mind",
  or restating), keep only the corrected version. If those words are not a correction, keep them.
- Add punctuation and capitalization. Start a new paragraph at clear topic changes.
- If the speaker lists items with "first/second/third" or "one/two/three", write a numbered list.
  If they say "a few things" and then name them, write a bulleted list.
- Write times, dates, money, and measurements as digits. Write other numbers one to nine as words.
- Spell these names and terms exactly like this: {vocabulary}
- Keep [[NL]] and [[P]] markers exactly where they are.

Do not:
- Add any word, fact, emoji, heading, or summary that the speaker did not say.
- Change slang, tone, or word choice. Do not make it more formal.
- Use em dashes.

Return only the formatted text.

Example input: um so this week was uh pretty pretty busy honestly
Example output: So this week was pretty busy, honestly.

Example input: we got dinner at seven actually eight with maya
Example output: We got dinner at 8 with Maya.

Example input: the movie was actually really good
Example output: The movie was actually really good.

Example input: three highlights first I tried the new ramen place second maya visited third I finally started running again
Example output:
Three highlights:
1. I tried the new ramen place.
2. Maya visited.
3. I finally started running again.
```

**Stage 5: Validate, then show**

The validator compares stage 3 output (input to the LLM) against stage 4 output, word by word, after lowercasing and stripping punctuation.

- **Allowed removals:** filler words, repeated words, and words inside a span ended by a backtrack phrase.
- **Allowed additions:** digits that replace number words, list numbering, and dictionary spellings.
- **Reject** if the output adds any other word, keeps less than 60% of the non-filler words with no backtrack phrase present, or loses or moves a `[[NL]]` or `[[P]]` marker.
- **On reject:** retry once with the hosted fallback model. If that's rejected too, show the stage 3 text with basic sentence capitalization, and a small note: "Formatting skipped."
- Always store the raw transcript (`body_raw_transcript`). "Show original" displays it, and an undo action restores it.

**Learning from edits**

- After the user edits dictated text, diff the formatted output against their final text.
- If they replaced a word with a capitalized word or a known friend's name, offer: "Add 'Jaylen' to your dictionary?"
- If the same correction happens twice, add it automatically and show a small confirmation.
- Learned entries store the misheard form as a "sounds like" variant, so stage 3 catches it next time.

#### Golden test set

These cases ship as unit tests. Every formatting model must pass all of them before it can be the default. Grow the set with real failures from the bake-off.

| # | Input (after stages 1 to 3) | Expected output | Tests |
| --- | --- | --- | --- |
| 1 | um so this week was uh pretty pretty busy | So this week was pretty busy. | Fillers, stutter |
| 2 | we got dinner at seven actually eight | We got dinner at 8. | Backtrack |
| 3 | I went to the gym scratch that I went for a run | I went for a run. | Backtrack |
| 4 | we're doing brunch saturday no wait sunday | We're doing brunch Sunday. | Restatement |
| 5 | the movie was actually really good | The movie was actually really good. | Not a correction |
| 6 | I like the new place a lot | I like the new place a lot. | "like" kept |
| 7 | three highlights first I tried the new ramen place second Maya visited third I started running again | Three highlights: then a numbered list of 3 items | Numbered list |
| 8 | work was fine [[P]] on the weekend I saw Priya | Work was fine. (new paragraph) On the weekend I saw Priya. | Paragraph marker |
| 9 | can you guys come saturday ? | Can you guys come Saturday? | Punctuation command |
| 10 | hung out with Jaylen and Priya (dictionary already fixed "jalen", "pria") | Hung out with Jaylen and Priya. | Dictionary spelling kept |
| 11 | ran three point one miles at six thirty am | Ran 3.1 miles at 6:30 am. | Numbers and times |
| 12 | honestly the week was kinda mid | Honestly, the week was kinda mid. | Slang kept |
| 13 | I went to the market and then you know got dumplings | I went to the market and then got dumplings. | Filler, no em dash |
| 14 | Maya's birthday dinner was so fun | Maya's birthday dinner was so fun. | No added words or emoji |

## 9. MVP scope

| Feature | MVP | Later |
| --- | --- | --- |
| Sign in with Apple; phone number for contact matching | Yes | |
| Friends and named circles ("College", "Family") | Yes | |
| Composer: type, dictate, voice memo, up to 4 photos | Yes | |
| Wispr-style dictation formatting, personal dictionary, learning from edits | Yes | |
| Fine-tuned formatting model | | Yes |
| Optional prompts ("Best part of your week?") | Yes | |
| Audience picker per update, defaulting to last week's circles | Yes | |
| Weekly reminder at a user-chosen day and time | Yes | |
| Feed: one card per friend for this week; "You're caught up" | Yes | |
| Voice memo player with transcript and speed control | Yes | |
| Reactions and private replies | Yes | |
| Personal archive of past weeks | Yes | |
| Share link with web reader (text, photos, memo playback) | Yes | |
| Transcription bake-off debug screen (internal only) | Yes | |
| "Play all" memos | | Yes |
| AI interviewer that asks follow-up questions | | Yes |
| Memory joggers from this week's photos and calendar | | Yes |
| Monthly and yearly recaps | | Yes |
| Android app | | Yes |

## 10. Core user flows

**Logging an update**

1. At the user's chosen time (default Sunday 6 pm local), a push notification: "Your week is ready to write."
2. The composer opens on this week with optional prompts.
3. The user types, taps the mic to dictate, or switches to voice memo and records.
4. Edits text or memo transcript; adds photos.
5. Picks circles (last week's choice preselected).
6. Posts. The update saves to the archive, appears in each circle's feed, and offers a share link.

**Catching up**

1. Open the feed: one card per friend who posted this week, unread first.
2. Text cards show a preview; memo cards show a player and the first lines of the transcript.
3. Tap for the full update. React, or reply privately (goes to a one-to-one thread).
4. After the last card: "You're caught up."

**Bringing friends in**

1. After the first post, the app suggests sharing the link in existing group chats.
2. A friend opens the link and reads or listens on the web, no account needed.
3. The page invites them to post their own update and download the app.
4. When they join, they're connected to the inviter and added to that circle.

## 11. Screens

1. Onboarding: Sign in with Apple, name, phone number, contacts permission, reminder time.
2. Feed (this week).
3. Update detail (text, photos, memo player, transcript, reactions, reply).
4. Composer (type / dictate / memo tabs or controls, photos, prompts).
5. Voice memo recorder (full screen sheet).
6. Audience picker.
7. Friends and circles management.
8. Archive (my past weeks, newest first).
9. Replies inbox and one-to-one thread.
10. Settings (reminder day and time, time zone, Dictionary, account deletion).
11. Internal: transcription bake-off screen.

Web: share link page (`/u/{token}`).

## 12. Technical design

### App architecture (iOS)

- SwiftUI, Swift concurrency, iOS 26 minimum.
- `supabase-swift` client for auth, database, storage.
- AVFoundation for recording and playback.
- Local draft persistence (SwiftData) so an in-progress update survives app restarts.

### Transcription abstraction

```swift
protocol TranscriptionEngine {
    var id: String { get }   // "apple-speech", "apple-dictation", "whisperkit-turbo", "openai-hosted"
    func prepare(vocabulary: [String]) async throws      // model download, permissions, name biasing
    func liveTranscribe(_ audio: AsyncStream<AVAudioPCMBuffer>)
        -> AsyncThrowingStream<TranscriptChunk, Error>   // partial + final chunks
    func transcribeFile(at url: URL) async throws -> Transcript
}

struct TranscriptChunk { let text: String; let isFinal: Bool; let words: [TimedWord] }
struct TimedWord { let text: String; let start: TimeInterval; let end: TimeInterval; let confidence: Float? }
struct Transcript { let text: String; let words: [TimedWord]; let engineID: String; let durationMs: Int }

struct DictionaryEntry { let written: String; let soundsLike: [String] }

protocol FormattingEngine {
    var id: String { get }   // "apple-foundation", "hosted-small"
    func format(_ text: String, vocabulary: [String]) async throws -> String
}

/// Runs stages 2 to 5 from "Dictation formatting". Pure functions where possible, so each stage is unit-testable.
struct DictationPipeline {
    func applySpokenCommands(_ words: [TimedWord], pauseThreshold: TimeInterval) -> String
    func applyDictionary(_ text: String, entries: [DictionaryEntry]) -> String
    func validate(input: String, output: String) -> ValidationResult
    func run(_ transcript: Transcript, context: FormattingContext) async -> FormattedResult
}

struct FormattedResult { let raw: String; let formatted: String; let engineID: String; let fellBack: Bool }
```

The active transcription engine and formatting engine are config values, switchable in the internal bake-off screen.

### Data model (Postgres)

```sql
profiles(
  id uuid primary key references auth.users,
  display_name text not null,
  phone_hash text unique,           -- hashed E.164, for contact matching
  timezone text not null,           -- IANA, e.g. 'America/Toronto'
  reminder_weekday int not null default 0,   -- 0 = Sunday
  reminder_time time not null default '18:00',
  created_at timestamptz default now()
)

friendships(
  user_a uuid, user_b uuid,         -- user_a < user_b
  status text check (status in ('pending','accepted')),
  requested_by uuid,
  created_at timestamptz default now(),
  primary key (user_a, user_b)
)

circles(id uuid pk, owner_id uuid, name text, created_at timestamptz)
circle_members(circle_id uuid, user_id uuid, primary key (circle_id, user_id))

updates(
  id uuid pk,
  author_id uuid not null,
  week_start date not null,         -- Monday of the week, author's time zone
  body_text text,
  body_raw_transcript text,         -- raw dictation, if any
  posted_at timestamptz,
  edited_at timestamptz,
  unique (author_id, week_start)
)

voice_memos(
  id uuid pk,
  update_id uuid unique references updates on delete cascade,
  storage_path text not null,
  duration_ms int not null,
  waveform jsonb not null,          -- ~100 floats, 0..1
  transcript_raw text,
  transcript_clean text,
  engine_id text,
  created_at timestamptz default now()
)

update_photos(id uuid pk, update_id uuid references updates on delete cascade, storage_path text, position int)
update_audiences(update_id uuid, circle_id uuid, primary key (update_id, circle_id))
reactions(update_id uuid, user_id uuid, emoji text, created_at timestamptz, primary key (update_id, user_id))
reads(update_id uuid, user_id uuid, read_at timestamptz, listened_ms int default 0, primary key (update_id, user_id))
threads(id uuid pk, user_a uuid, user_b uuid, unique (user_a, user_b))
messages(id uuid pk, thread_id uuid, sender_id uuid, update_id uuid null, body text, created_at timestamptz)
share_links(token text pk, update_id uuid references updates on delete cascade, created_at timestamptz, expires_at timestamptz)

user_dictionary(
  id uuid pk,
  user_id uuid not null,
  written text not null,             -- exact spelling, e.g. 'Jaylen'
  sounds_like text[] default '{}',   -- misheard variants, e.g. {'Jalen','Jay Lynn'}
  source text check (source in ('manual','learned')),
  created_at timestamptz default now(),
  unique (user_id, written)
)
-- Friends' names are added to the vocabulary at runtime from friendships; they are not copied into this table.
```

### Access rules (Row Level Security)

- A user can read an update if they are its author, or they are a member of a circle listed in `update_audiences` for that update and are accepted friends with the author.
- Same rule for that update's photos, voice memo row, and storage objects.
- Only the author can create, edit, or delete their update.
- Share links are resolved by an Edge Function using the service role, which returns the update and signed media URLs only if the token exists and hasn't expired.

### Week boundaries

- A week runs Monday 00:00 to Sunday 23:59 in the author's time zone.
- MVP default: posts made before Monday 12:00 local count toward the previous week. Keep this as a config value.

### Reminders

- pg_cron runs every 15 minutes and calls an Edge Function that finds users whose local reminder day and time fall in that window and who haven't posted this week, then sends a push through APNs.

### Contact matching

- The app hashes phone numbers from contacts (normalized to E.164) on device and sends only hashes. The server returns matching profiles.

## 13. Success metrics

North star: **weekly post rate**, the share of active users who post each week. Targets are set after the first four weeks of beta data.

| Metric | What it tells you |
| --- | --- |
| Weekly post rate | Whether the ritual holds |
| Read coverage (read or listened) per update | Whether posting feels worth it |
| Median time from opening composer to posting | Whether logging is easy enough |
| Share of updates by mode (typed / dictated / memo) | Which modes people actually use |
| Average share of each voice memo listened to | Whether memos get heard or skipped |
| Share-link views that become installs | Whether the group chat wedge works |
| Week 8 retention | Whether people stay after the novelty |

## 14. Risks

| Risk | Mitigation |
| --- | --- |
| Empty feed for new users | Share links readable and playable without an account; start with whole groups |
| One session a week is easy to forget | Reminder at a time the user picks; the archive gives value in quiet weeks |
| Pressure to have an impressive week | Prompts that invite small moments; no public counts |
| Long voice memos nobody finishes | 5-minute cap, speed control, transcript to skim |
| Transcription errors on names and slang | Engine bake-off; name hints; editable transcript; raw always kept |
| Audio storage cost | AAC 64 kbps mono (about 0.5 MB/min), 5-minute cap |
| Retro adds writing or voice | Lean into voice and writing, which a photo-first product treats as secondary |

## 15. Open questions (use MVP default until decided)

| Question | MVP default |
| --- | --- |
| Default reminder day: Friday or Sunday evening? | Sunday 18:00 local, user-changeable |
| Must you post to see friends' updates this week? | No gate; build behind a feature flag `require_post_to_read` |
| Can a post on Monday morning count for last week? | Yes, until Monday 12:00 local |
| Can an update be private (archive only, no audience)? | Yes: posting with zero circles saves to archive only |
| Should replies to a memo be allowed as voice? | Text only for MVP |
| App name | TBD |

## 16. Build plan

**M0: Foundation**
- Xcode project (SwiftUI, iOS 26), Supabase project, SQL migrations for the schema above, RLS policies, Sign in with Apple.
- Done when: a user can sign in, set a name, time zone, and reminder time, and RLS tests pass for update visibility.

**M1: Composer with typing and dictation**
- `TranscriptionEngine` protocol with the `SpeechTranscriber` implementation; `DictationPipeline` (spoken commands, dictionary, validator); `FormattingEngine` with Apple Foundation Models plus the hosted fallback through an Edge Function; `user_dictionary` table and Settings > Dictionary; learning from edits; show-original toggle and undo; local drafts.
- Done when:
    - All 14 golden test cases pass as unit tests against both formatting engines.
    - Unit tests cover spoken commands (including "the period of time" staying as words) and dictionary fuzzy matching.
    - A user can dictate 2 minutes, see live text, and get formatted text within 1.5 seconds of stopping for a 60-second dictation on a recent iPhone.
    - On a device without Apple Intelligence, formatting falls back to the hosted model.
    - Correcting the same misheard name twice adds it to the dictionary, and the next dictation spells it right.
    - The draft survives an app restart.

**M2: Voice memos**
- Recorder (pause, resume, re-record, 5-minute cap), AAC encoding, waveform summary, on-device transcription, upload to private storage, player with scrubbing and speed control, background playback.
- Done when: a 5-minute memo records, uploads, transcribes, and plays back from another account with the transcript shown.

**M3: Transcription bake-off**
- WhisperKit (large-v3-turbo) and one hosted OpenAI model implemented behind the protocol; internal screen to run one recording through every engine and compare outputs side by side.
- Done when: the 20-recording bake-off can be run and results exported.

**M4: Friends and circles**
- Contact matching by hashed phone, friend requests, circles create/edit/delete.
- Done when: two test accounts can find each other from contacts, become friends, and be put in a circle.

**M5: Posting and feed**
- Audience picker, post, feed of this week, detail view, reactions, read and listen tracking, "You're caught up".
- Done when: an update posted to one circle is visible to its members and not to a friend outside it.

**M6: Replies and archive**
- One-to-one threads from an update; archive of my past weeks.

**M7: Reminders**
- pg_cron + Edge Function + APNs.
- Done when: a user with a reminder at a given local time receives it within 15 minutes, and does not receive it if they already posted this week.

**M8: Share links and web reader**
- Token links, Edge Function resolver, Next.js page showing text, photos, and memo player, with an App Store call to action.
- Done when: a link opened in a logged-out mobile browser shows the update and plays the memo; an expired link shows a friendly message.

## 17. Roadmap

| Phase | What happens | Gate to move on |
| --- | --- | --- |
| Phase 0: Dogfood | Your own group chats on TestFlight; run the transcription bake-off | Your group posts 4 weeks in a row |
| Phase 1: Private beta | A few friend groups; share links and web reader live; measure weekly post rate | Post rate holds through week 8 |
| Phase 2: App Store launch | Public release, invite-driven growth, "Play all", AI interviewer, recaps | |

## 18. Sources

- Retro: [Fast Company](https://www.fastcompany.com/91462432/retro-photo-sharing-app), [Engadget](https://engadget.com/2234246/retro-app-what-is-it-how-to-use)
- Wispr Flow built on Whisper and Llama: [9to5Mac](https://9to5mac.com/?p=1008112)
- Wispr Flow is cloud-only: [tl;dv review](https://tldv.io/blog/wisprflow/)
- Wispr Canto model: [Reworked](https://www.reworked.co/ai-platforms/wispr-hits-2b-valuation-launches-canto-voice-model/)
- VoiceInk engines and cleanup options: [openapps.pro](https://openapps.pro/apps/voiceink), [GitHub (GPLv3, dependencies)](https://github.com/mrtry-lab/VoiceInk)
- OpenWhispr models: [OpenWhispr vs VoiceInk](https://openwhispr.com/compare/voiceink)
- Whisper large-v3-turbo specs and MIT license: [model summary](https://thegtmdirectory.com/models/openai-whisper-large-turbo/whisper-large-v3-turbo), [iPhone benchmark (Whisper Notes)](https://whispernotes.app/en/blog/introducing-whisper-large-v3-turbo)
- OpenAI transcription models and prices: [gpt-4o-transcribe docs](https://developers.openai.com/api/docs/models/gpt-4o-transcribe), [price list](https://lmmarketcap.com/openai-whisper-pricing), [newer models and retirements (third-party tracker)](https://www.developersdigest.tech/models/speech/openai)
- Apple SpeechAnalyzer: [WWDC25 session](https://developer.apple.com/videos/play/wwdc2025/277/), [benchmark summary](https://rohitraj.tech/notes/apple-speechanalyzer-vs-whisper-on-device-stt-2026)
- WhisperKit: [GitHub](https://github.com/argmaxinc/whisperkit)
- Wispr Flow formatting behaviors (Smart Formatting, Backtrack, lists, spoken commands): [Wispr Flow docs](https://docs.wisprflow.ai/articles/5373093536-how-do-i-use-smart-formatting-and-backtrack)
- Wispr Flow architecture and latency budgets: [Wispr technical challenges](https://wisprflow.ai/post/technical-challenges), [Baseten case study](https://www.baseten.co/resources/customers/wispr-flow/)
- Wispr Flow dictionary, snippets, styles: [Letterly review](https://letterly.app/blog/wispr-flow-review/)
- `SpeechTranscriber` ignores contextual strings: [Apple Developer Forums](https://developer.apple.com/forums/thread/811083)
- `DictationTranscriber` contextual strings and custom language models: [Blake Crosley](https://blakecrosley.com/blog/speech-framework-vs-sfspeechrecognizer)
- Whisper prompting for names (224-token limit): [OpenAI Whisper prompting guide](https://developers.openai.com/cookbook/examples/whisper_prompting_guide)
- Apple Foundation Models (4K context, availability checks): [Blake Crosley](https://blakecrosley.com/pl/blog/apple-foundation-models-framework)
- VoiceInk prompt structure and Refine model: [VoiceInk docs](https://tryvoiceink.com/docs/custom-prompts), [VoiceInk Refine](https://featherless.ai/models/beingpax/voiceink-refine-v1)
