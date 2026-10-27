#!/usr/bin/env bash
# Resets and seeds the local Supabase stack, then runs the iOS unit and UI tests on a
# simulator. Screenshots of every screen land in $SCREENSHOT_DIR when it's set.
#   scripts/test-ios.sh [-only-testing:WeeknotesUITests/WeeknotesUITests/testScreenshotTour ...]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM="${SIM:-iPhone 17 Pro}"
FIXTURES="${FIXTURE_DIR:-$ROOT/.seed-cache/fixtures}"
mkdir -p "$FIXTURES"

# Audio fixtures for dictation and a near-5-minute memo, spoken by macOS
if [ ! -f "$FIXTURES/dictation.m4a" ]; then
  say -v Samantha -r 165 -o "$FIXTURES/dictation.aiff" "um so this week was uh pretty pretty busy. we got dinner at seven actually eight with jalen [[slnc 600]] new paragraph [[slnc 600]] on saturday I went for a run"
  afconvert -f m4af -d aac -b 64000 -c 1 "$FIXTURES/dictation.aiff" "$FIXTURES/dictation.m4a"
fi
if [ ! -f "$FIXTURES/memo5min.m4a" ]; then
  LINE="Hi everyone, it's my long memo for the week. Monday started with the move, boxes in every room and a cat who refused to leave the closet. Tuesday I finally found the kettle. Wednesday I worked late, but the new place has a window where the evening light comes in sideways. Thursday I met Ben for dinner and we talked for three hours. Friday I went to the market, bought too many peaches, and made a pie that was more of a soup. Saturday was the hike up to the reservoir. Sunday I called Grandma, who told me the goat story again. "
  for i in 1 2 3 4 5 6; do printf '%s' "$LINE"; done > "$FIXTURES/long.txt"
  echo "And that's my week. [[slnc 17000]] Bye!" >> "$FIXTURES/long.txt"
  say -v Samantha -r 140 -o "$FIXTURES/long.aiff" -f "$FIXTURES/long.txt"
  afconvert -f m4af -d aac -b 64000 -c 1 "$FIXTURES/long.aiff" "$FIXTURES/memo5min.m4a"
fi

cd "$ROOT"
supabase db reset >/dev/null
deno run -A scripts/seed-local.ts

# The UI tests don't tap through permission alerts
UDID=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; n=sys.argv[1]; d=[x for r in json.load(sys.stdin)["devices"].values() for x in r if x["name"]==n]; print(d[-1]["udid"])' "$SIM")
xcrun simctl boot "$UDID" 2>/dev/null || true
for service in microphone contacts photos; do xcrun simctl privacy "$UDID" grant "$service" com.blai.weeknotes 2>/dev/null || true; done
# A contact for the M4 test: Ana's seeded, verified number
printf 'BEGIN:VCARD\nVERSION:3.0\nN:Morales;Ana;;;\nFN:Ana Morales\nTEL;TYPE=CELL:(555) 555-0101\nEND:VCARD\n' > "$FIXTURES/ana.vcf"
xcrun simctl addmedia "$UDID" "$FIXTURES/ana.vcf" 2>/dev/null || true

cd "$ROOT/ios"
TEST_RUNNER_FIXTURE_DIR="$FIXTURES" TEST_RUNNER_SCREENSHOT_DIR="${SCREENSHOT_DIR:-}" \
xcodebuild test -quiet -project Weeknotes.xcodeproj -scheme Weeknotes \
  -destination "platform=iOS Simulator,name=$SIM" \
  -derivedDataPath "${DERIVED_DATA:-$ROOT/.build/ios}" "$@"
