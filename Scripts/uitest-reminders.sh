#!/usr/bin/env bash
# Drives the reminders UI test on a booted simulator against the local relay:
# seeds a recurring task under a fresh key, runs the app, and delivers a
# notification once the reminder is scheduled so the tap→open path is covered.
#   Scripts/uitest-reminders.sh [simulator-name]   (default "iPhone 17"; relay ws://127.0.0.1:7799)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
sim="${1:-iPhone 17}"
relay="${ROOSTR_TEST_RELAY:-ws://127.0.0.1:7799}"
secret="$(python3 -c 'import secrets;print(secrets.token_hex(32))')"
xcrun simctl bootstatus "$sim" -b >/dev/null
object="$(cd "$root" && ROOSTR_SEED_SECRET="$secret" ROOSTR_SEED_RELAY="$relay" swift test --filter SeedRecurringForUITest 2>&1 | sed -n 's/^SEEDED_OBJECT //p' | tail -1)"
[[ -n "$object" ]] || { echo "seeding failed"; exit 1; }
push="$(mktemp -t roostr-push).json"
printf '{"Simulator Target Bundle":"app.roostr.Roostr","aps":{"alert":{"title":"Water the plants","body":"Due now"}},"objectId":"%s"}' "$object" > "$push"
xcrun simctl terminate "$sim" app.roostr.Roostr 2>/dev/null || true
xcrun simctl uninstall "$sim" app.roostr.Roostr 2>/dev/null || true
( sleep 40; xcrun simctl push "$sim" app.roostr.Roostr "$push" >/dev/null ) &
cd "$root" && xcodegen generate --quiet
TEST_RUNNER_ROOSTR_UITEST_SECRET="$secret" TEST_RUNNER_ROOSTR_UITEST_OBJECT="$object" TEST_RUNNER_ROOSTR_UITEST_RELAY="$relay" TEST_RUNNER_ROOSTR_UITEST_PUSHED=1 \
	xcodebuild -project Roostr.xcodeproj -scheme Roostr -destination "platform=iOS Simulator,name=$sim" \
	-derivedDataPath "${ROOSTR_DERIVED_DATA:-/tmp/roostr_dd}" -skipPackagePluginValidation -skipMacroValidation test 2>&1 \
	| grep -E "Test Case|error:|\*\* TEST"
wait
