#!/usr/bin/env bash
# Archive the iOS app and upload it to App Store Connect (TestFlight).
#
#   Scripts/archive.sh            # archive + export .ipa
#   Scripts/archive.sh --upload   # …and upload to App Store Connect
#
# Requires: Xcode signed in to the developer account (Xcode > Settings >
# Accounts) so automatic signing can create certificates and profiles
# (-allowProvisioningUpdates), the web bundle built (Scripts/build-web.sh),
# and the project generated (xcodegen).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
ROOSTR_TEAM_ID="${ROOSTR_TEAM_ID:-58GKGS43UM}"
out="${ROOSTR_ARCHIVE_DIR:-$root/.build/archive}"
archive="$out/Roostr.xcarchive"
mkdir -p "$out"

cat > "$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>method</key><string>app-store-connect</string>
	<key>teamID</key><string>$ROOSTR_TEAM_ID</string>
	<key>signingStyle</key><string>automatic</string>
	<key>uploadSymbols</key><true/>
	<key>destination</key><string>$([[ "${1:-}" == "--upload" ]] && echo upload || echo export)</string>
</dict></plist>
EOF

(cd "$root" && ROOSTR_TEAM_ID="$ROOSTR_TEAM_ID" xcodegen generate --quiet)
xcodebuild -project "$root/Roostr.xcodeproj" -scheme Roostr -configuration Release \
	-destination 'generic/platform=iOS' -archivePath "$archive" \
	-skipPackagePluginValidation -skipMacroValidation -allowProvisioningUpdates \
	DEVELOPMENT_TEAM="$ROOSTR_TEAM_ID" archive
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out/export" \
	-exportOptionsPlist "$out/ExportOptions.plist" -allowProvisioningUpdates
echo "archive: $archive"
ls "$out/export"
