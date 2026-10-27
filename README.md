# Weeknotes

**A friends-only iOS app where, once a week, you log an update about your week and it shows up in the feed of every friend and group you choose.** Type it, dictate it, or record a voice memo; post once instead of pasting the same message into several group chats; every week saves to your own archive.

The full brief is [`PRD.md`](./PRD.md). "Weeknotes" is the working name (PRD §15 left it open).

- **Web reader (live):** https://weeknotes-app.vercel.app. It runs in no-database mode for now: [`/u/demo`](https://weeknotes-app.vercel.app/u/demo) shows a sample shared update with a playable memo, and every other link reads as not found.
- **Repo:** https://github.com/brandon-lai/weeknotes. Pushing `main` deploys `web/` to Vercel.
- **Backend:** Supabase. There's **no hosted project yet**, because the free tier's two active slots are held by `heatcheck` and `attn`. Everything was built and tested against the local Supabase stack. See [Launch checklist](#launch-checklist-owner-only).

## What works, and what's stubbed

| Area | State |
| --- | --- |
| **iOS app** (SwiftUI, iOS 26) | All 11 screens in PRD §11: onboarding, this week's feed, update detail, composer, memo recorder, audience picker, people and circles, archive, replies inbox and threads, settings with the dictionary, and the internal bake-off. It builds in Debug (simulator) and Release (device). |
| **Dictation pipeline** | All five stages. Stage 1 runs on Apple SpeechAnalyzer: `SpeechTranscriber`, or `DictationTranscriber` with friends' names as contextual strings. Stages 2, 3 and 5 are plain code. Stage 4 uses Apple Foundation Models on device, with Claude Haiku 5.5 as the hosted fallback. **Both formatters pass all 14 golden cases.** |
| **Voice memos** | AAC, mono, 64 kbps, 5-minute cap, pause and resume, a live waveform, and a 100-value waveform summary. Transcription is on device, with OpenAI as the fallback. Memos upload to private storage and play inline at 1×/1.5×/2× with lock-screen controls. Listening progress is tracked. |
| **Friends and circles** | Contact matching sends only hashed phone numbers, compared server-side against a peppered hash of the *verified* phone. There are friend requests, and circles can be created, edited and deleted. |
| **Posting and feed** | Updates go to circles or stay archive-only, defaulting to last week's circles. There are reactions, private replies, read and listen tracking, and "You're caught up". |
| **Reminders** | pg_cron runs every 15 minutes and calls the `reminders` Edge Function, which sends APNs pushes. **Sending needs your APNs key.** Until then the function says "APNs is not configured" and sends nothing. |
| **Share links** | Token links resolve through the `share` Edge Function, with signed media URLs that expire with the link. The Next.js reader shows the text, photos and memo player. People who join from a link are connected to the author and added to that circle. |
| **Bake-off (M3)** | WhisperKit (large-v3 turbo) and OpenAI's hosted model are implemented behind the same protocol as Apple's engines. The internal screen runs one recording through every engine and both formatters, scores word error rate and names, and exports CSV and JSON. **The 20 real recordings are yours to make.** |
| **Stubbed** | Sign in with Apple and push only work with your Apple developer configuration. Phone verification needs an SMS provider in production. Locally both use Supabase's test OTP and a Developer sign-in that isn't compiled into Release builds. |

## Acceptance criteria (PRD §16) and how each was verified

| Milestone | Status | Evidence |
| --- | --- | --- |
| **M0**: sign in, set name, time zone and reminder time; RLS tests pass | ✅ | UI test `testOnboardingNewAccount`, plus 61 pgTAP access tests (`supabase/tests/database/access.test.sql`). Sign in with Apple itself needs a device and your Apple config. Tests use Developer sign-in. |
| **M1**: 14 golden cases on both formatters | ✅ | `GoldenSetTests`: on-device 14/14 (stable across runs on this Mac), hosted 14/14 (three runs in a row). |
| **M1**: spoken commands ("the period of time" stays words) and fuzzy dictionary | ✅ | `SpokenCommandTests`, `DictionaryTests`, plus stage 1 → 2 on real speech audio (`SpeechEngineTests`). |
| **M1**: live text, formatted within 1.5 s of stop for 60 s | ✅ on Mac, ❓ on iPhone | `LatencyTests`: a 56 s, 192-word dictation, with formatted text **1.05 s** after stop on this Mac. The iPhone number needs a device. |
| **M1**: no Apple Intelligence → hosted fallback | ✅ | `PipelineTests.fallsBackWhenTheDeviceModelIsUnavailable`. The app also has a `-noOnDeviceFormatting` launch argument. |
| **M1**: same correction twice → dictionary → next dictation right | ✅ | `EditLearningTests.secondCorrectionLearnsAndTheNextDictationIsRight` |
| **M1**: draft survives a restart | ✅ | UI test `testDraftSurvivesRelaunch` |
| **M2**: 5-minute memo records, uploads, transcribes, plays from another account with transcript | ✅ | UI test `testMemoPlaysBackFromAnotherAccount` with a 4:58 spoken fixture, transcribed on device (Apple dictation model, 4,470 characters) and played from Ana's account. |
| **M3**: bake-off can be run and exported | ✅ built, ❓ run | The screen and engines exist and export works. The Apple engines are tested on real audio. **WhisperKit has never run** (it's a 632 MB download on first use). |
| **M4**: two accounts find each other from contacts, become friends, share a circle | ✅ | UI test `testFindFriendFromContactsThenCircle` covers phone verification with a code, the iOS 18+ contacts access sheet, the match, the request, accept, and a new circle. Also pgTAP "contacts match verified phones only". |
| **M5**: posted to one circle → members see it, a friend outside it doesn't | ✅ | UI test `testPostToOneCircleIsVisibleOnlyToItsMembers`, plus pgTAP visibility tests and a storage test where a friend outside the circle can't sign a URL for the files. |
| **M6**: replies and archive | ✅ | Screenshot tour, plus pgTAP replies tests (participants only, friends only, unread counts). |
| **M7**: reminder within 15 minutes, none after posting | ✅ against a mock APNs | `supabase/tests/functions.test.ts` checks one ES256-signed push, never two, none for anyone who posted, and dead tokens removed. pg_cron → pg_net → function was verified on the local stack. Real delivery needs your APNs key. |
| **M8**: logged-out mobile browser shows the update and plays the memo; an expired link is friendly | ✅ | Rendered at 390 px against real share links on the local stack: three photos, memo playback, "This link has expired". Production `/u/demo` plays too. |

## Decisions (and why)

**Formatting on device.** The PRD's prompt alone got the ~3B on-device model to 3/14 golden cases: it copied words from the inline examples ("honestly", "finally"), added preambles, and dropped markers. Three changes got it to 14/14 without touching the rules:

- The examples became conversation turns, chosen not to overlap the golden cases.
- Output goes through guided generation into a single `text` field.
- `[[NL]]`/`[[P]]` markers never reach the model. The text is split at them, and they're put back in code.

The hosted model keeps the PRD prompt verbatim (`supabase/functions/_shared/formatting-prompt.ts`). A test fails if it drifts from the app's copy.

**Two deterministic steps after any model.** Both are documented in code, and neither ever changes a word the speaker said.

- **Polish:** capitalizes sentence and list starts, ends sentences with punctuation, removes bare "um"/"uh", and writes times as "6:30 am" (the PRD's style; Haiku writes "AM").
- **Stage 5 repair:** if the only thing a model added is up to three small words ("brunch *on* Sunday", "*I* ran"), those exact words are removed and the result is validated again. This enforces "never add words" without trusting the model to.

**Formatting while you talk.** Running stages 2–5 once after stop took 5.2 s for a 60 s dictation on device, against a 1.5 s target. `LiveDictationFormatter` formats finished sentence groups while the user is still talking. It keeps one word of lookahead so stage 2 can measure the pause after a word, and it never splits right before a command. After stop, only the tail is left.

**Engine fallback chain.** Apple Speech → Apple Dictation → hosted. `SpeechTranscriber` reports itself unsupported in the Simulator (and on devices without the model). The configured engine is used when it can run.

**Phone numbers.** A number is matchable only after it's verified with a code (Supabase Auth phone change). The server derives the hash itself, as HMAC with a secret pepper over SHA-256 of the E.164 number, so nobody can claim someone else's number and a leaked table can't be reversed by enumerating numbers. Matching is limited to 30 calls a day and 3,000 hashes per call.

**Visibility rule.** It lives in one function, `can_read_update()`: the author, or an *accepted friend* in one of the update's circles, and, if `require_post_to_read` is on, a reader who has posted that week. RLS is on every table, and media buckets use the same rule.

**No public counts** (PRD §14). Reactions are visible only to the author and the reactor. Readers never see an update's audience or who else read it.

**"Show original" for readers too.** The raw dictation is viewable by anyone who can read the update. The PRD says the raw transcript is always viewable, and showing readers the speaker's actual words fits "your voice, not the AI's".

**Late arrivals.** The feed is "this week" in *your* time zone, which would hide a friend's Sunday-night post on Monday afternoon. Last week's updates you haven't read stay in the feed, labeled "Last week", for four days.

**Joining from a link** (PRD §10) connects you to the inviter and adds you to the link's circle, as the PRD says. Links expire after 30 days (`app_config.share_link_days`) and are never indexed or cached, which limits how far a forwarded link can travel.

**Reminder window.** A reminder is sent in the first 15-minute run after the user's local time, and is idempotent per week through `reminder_log`. Due users are looked up within the past hour, so one failed cron run is retried instead of lost.

**Deleting an update deletes its files.** The app removes the files, and a trigger also queues them, so the hourly `sweep` function deletes anything a crash left behind. This was verified locally.

**Stack.** SwiftUI and Swift 6, with supabase-swift 2.55, WhisperKit 1.1, and SwiftData for drafts. The pure logic lives in a local Swift package, `WeeknotesCore`, tested with `swift test` on a Mac. Supabase (Postgres, Auth, Storage, Edge Functions on Deno, pg_cron). The web reader is Next.js 16.4.3 with plain CSS and no database dependency.

### PRD §15 open questions: the shipped answers

| Question | Shipped | Where it's configured |
| --- | --- | --- |
| Default reminder day | Sunday 18:00 local, user-changeable | `profiles.reminder_weekday` / `reminder_time` defaults; `AppConfig.defaultReminder*` |
| Must you post to see friends' updates? | No gate | `app_config.require_post_to_read` (false). Both settings are tested. |
| Can a Monday-morning post count for last week? | Yes, until 12:00 local | `app_config.monday_cutoff_hour`; `AppConfig.mondayCutoffHour` (shared test vectors) |
| Can an update be private? | Yes: zero circles means archive only | The audience picker's "Archive only"; tested |
| Voice replies? | Text only | — |
| App name | **Weeknotes** (working name) | `INFOPLIST_KEY_CFBundleDisplayName`, web wordmark |

## Architecture

```
ios/
  Weeknotes.xcodeproj           app + unit + UI test targets (synchronized folders, iOS 26)
  WeeknotesCore/                Swift package: everything testable without a phone
    Transcription.swift           TranscriptionEngine protocol, TimedWord, Transcript
    AppleSpeechEngines.swift      SpeechTranscriber / DictationTranscriber engines (stage 1)
    SpokenCommands.swift          stage 2
    PersonalDictionary.swift      stage 3 (+ DoubleMetaphone.swift, common-words.txt)
    Formatting.swift              stage 4: FormattingEngine, PRD prompt, Apple + hosted engines
    FormatValidator.swift         stage 5, including the repair step
    DictationPipeline.swift       stages 2-5, chunking; LiveDictationFormatter.swift for live
    EditLearning.swift            "Add 'Jaylen' to your dictionary?" and auto-learning
    Week.swift, PhoneNumber.swift, Waveform.swift, Vocabulary.swift, BakeOff.swift, AppConfig.swift
  Weeknotes/                    the app
    App/          entry point, AppModel (session, deep links), environment
    Services/     API (every backend call), audio, engines, contacts and photos, drafts, push
    Features/     Onboarding, Feed, Composer, People, Archive, Inbox, Settings, BakeOff
    DesignSystem/ theme (paper, ink, marmalade; serif bodies) and components
supabase/
  migrations/     schema, access (RLS), RPCs, storage, cron, quotas
  functions/      format, transcribe, share, reminders, sweep, delete-account (Deno)
  tests/          pgTAP (database/*.test.sql) and Edge Function/Storage tests (functions.test.ts)
web/              Next.js reader: /u/[token], /, /privacy, /support, AASA
scripts/          seed-local.ts (realistic friend group), test-ios.sh
```

## Running it locally

You need Xcode 26.3+, Docker (`brew install colima docker && colima start --cpu 4 --memory 6`), Supabase CLI **2.122+** (2.109's edge runtime fails to boot under colima), and Deno 2.

```bash
supabase start                      # local Postgres, Auth, Storage, Edge runtime
supabase db reset                   # applies migrations
deno run -A scripts/seed-local.ts   # 10 friends, circles, 10 weeks of updates, memos, photos
cp supabase/functions/.env.example supabase/functions/.env   # then fill in the keys you have
supabase functions serve --env-file supabase/functions/.env
open ios/Weeknotes.xcodeproj        # run on a simulator; "Developer sign-in" → ana@weeknotes.test
cd web && npm install && SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY=<local anon key> npm run dev
```

All seeded accounts use the password `weeknotes-dev-password`. The Debug build points at `http://127.0.0.1:54321` (build settings `SUPABASE_URL` / `SUPABASE_ANON_KEY`).

## Tests

| Suite | Command | Count |
| --- | --- | --- |
| Core logic, golden set (on device), speech on real audio | `cd ios/WeeknotesCore && swift test` | 73 (golden set needs Apple Intelligence on the Mac) |
| Golden set, hosted engine | `WEEKNOTES_FUNCTIONS_URL=… WEEKNOTES_ANON_KEY=… WEEKNOTES_TEST_JWT=… swift test --filter Hosted` | 14 |
| 60-second dictation latency | `WEEKNOTES_LATENCY=1 swift test --filter Latency` | 1 |
| Database: RLS, RPCs, week math, reminders | `supabase test db` | 78 |
| Edge Functions and Storage policies | `deno test -A supabase/tests/functions.test.ts` | 9 |
| iOS app: unit + UI flows (resets and seeds first) | `scripts/test-ios.sh` (`SCREENSHOT_DIR=…` saves every screen) | 6 + 8 |
| Web reader | `cd web && npm test` | 4 |

## Launch checklist (owner only)

These need your accounts, your money or your judgment.

1. **Create the Supabase project.** The free tier allows two active projects per user, and `heatcheck` and `attn` hold both. Pausing a live product or upgrading is your call. Then:
   ```bash
   supabase projects create weeknotes --org-id <org> --db-password <pw> --region us-west-1
   supabase link --project-ref <ref>
   supabase db push
   supabase functions deploy format transcribe share reminders sweep delete-account
   supabase secrets set ANTHROPIC_API_KEY=… OPENAI_API_KEY=… CRON_SECRET=$(openssl rand -hex 32) \
     APNS_KEY_ID=… APNS_TEAM_ID=KT2Y8F24DZ APNS_TOPIC=com.blai.weeknotes APNS_PRIVATE_KEY="$(cat AuthKey_XXXX.p8)"
   ```
   Then point pg_cron at the functions:
   ```sql
   insert into private.secrets values ('functions_url','https://<ref>.supabase.co/functions/v1'),('cron_secret','<CRON_SECRET>')
   on conflict (name) do update set value = excluded.value;
   ```
   In the dashboard:
   - Enable the **Apple** provider with client ID `com.blai.weeknotes`.
   - Enable **phone** with an SMS provider such as Twilio, and turn on **Confirm phone changes**. Contact matching depends on verified numbers.

   Then run the security advisor and fix anything it flags.
2. **Apple Developer.**
   - Let Xcode register `com.blai.weeknotes` on team KT2Y8F24DZ with Sign in with Apple, Push Notifications and Associated Domains (`applinks:weeknotes-app.vercel.app`). A first device build with automatic signing does it.
   - Create an APNs key (.p8) for the secrets above.
3. **iOS Release config.** Set the `SUPABASE_URL` and `SUPABASE_ANON_KEY` build settings for **Release** in the Weeknotes target. Without them, the app shows "Weeknotes isn't set up".
4. **Vercel env, then push to redeploy.**
   - `SUPABASE_URL` and `SUPABASE_ANON_KEY` turn on real share links.
   - Optional: `NEXT_PUBLIC_APP_STORE_URL` (TestFlight or App Store link) and `NEXT_PUBLIC_SUPPORT_EMAIL`.
5. **A device pass.** It has to cover:
   - dictation latency on a recent iPhone (M1's 1.5 s)
   - a device without Apple Intelligence (hosted fallback)
   - Sign in with Apple
   - a real reminder push
   - a share link opening the app (universal link)
   - lock-screen memo playback
   - contacts on a real address book
6. **Run the bake-off.** Record 20 real updates (dictation and memos, quiet and noisy rooms), add reference transcripts, run every engine, export, and decide the defaults (Settings → tap Version 7 times in Release). WhisperKit downloads ~632 MB on first use.
7. **App Store.**
   - The privacy questionnaire: name, phone number (hashed), audio, photos, other user content and user ID, all linked to the user and none used for tracking. `PrivacyInfo.xcprivacy` matches this.
   - Privacy policy URL: https://weeknotes-app.vercel.app/privacy
   - Age rating and screenshots.
8. **The name and a domain.** "Weeknotes" is a working name. If you change it, update the display name, the web wordmark, and the associated domain.
9. **Keys used for local testing.** The hosted formatter and transcription tests used the `ANTHROPIC_API_KEY` from `smiski.world/.env.local` and the `OPENAI_API_KEY` from `affi/.env.local`. They were copied only into the gitignored `supabase/functions/.env`. Production should use dedicated keys with spend limits. The functions enforce daily per-user quotas of 300 formats and 30 transcriptions.

## Known limitations

- **In the iPhone 17 Pro iOS 26.3.1 simulator on this Mac, every emoji draws as "?".** Safari in the same simulator does it too, so it isn't an app bug. Real devices are fine.
- **Apple's `SpeechTranscriber` doesn't run in the Simulator.** There, dictation and memos use `DictationTranscriber` through the fallback chain.
- **Live dictation formats in sentence groups.** A self-correction that spans two groups ("…at seven. Actually eight") isn't caught. The bake-off will show whether that matters in practice.

## Later (PRD §9)

"Play all", the AI interviewer, memory joggers, monthly and yearly recaps, Android, a fine-tuned formatting model, memo trimming, and word-by-word transcript highlighting.
