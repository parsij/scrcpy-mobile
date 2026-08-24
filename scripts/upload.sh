#!/bin/bash
set -euo pipefail

# ── Upload to TestFlight ─────────────────────────────────────────
# Usage: scripts/upload.sh
#
# Archives a Release build of Scrcpy Remote and uploads it to
# App Store Connect / TestFlight via xcodebuild. Build number is
# auto-managed by Xcode to avoid conflicts with existing builds on
# App Store Connect.
#
# Uses Xcode's logged-in Apple Developer account for authentication.
# This is SEPARATE from scripts/build-debug-ipa.sh + upload-dev-ipa.sh,
# which produce a development-signed IPA for the internal OTA service.
# ──────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BUILD_DIR="$REPO_ROOT/build/appstore"
EXPORT_DIR="$BUILD_DIR/ipa"
PROJECT="$REPO_ROOT/scrcpy-app/Scrcpy Remote.xcodeproj"
SCHEME="Scrcpy Remote"
TEAM_ID="K8Q74NT2BG"

# Archive into Xcode's default Organizer directory so the build shows up
# in Organizer → Archives alongside GUI-archived builds (and stays
# associated with the dSYM history Apple ingests crash reports against).
# Each archive gets a timestamped filename so re-runs accumulate instead
# of clobbering, matching Xcode's own naming scheme.
ARCHIVE_DIR="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)"
ARCHIVE_PATH="$ARCHIVE_DIR/Scrcpy Remote $(date +%Y-%m-%d\ %H.%M.%S).xcarchive"

# ── Stage paths ─────────────────────────────────────────────────
# Don't blow away the previous export up front — a failed upload
# would leave the user with nothing. Export to a sibling dir and
# swap in only after both archive + export succeed.
mkdir -p "$BUILD_DIR" "$ARCHIVE_DIR"
STAGE_DIR="$BUILD_DIR/.staging"
EXPORT_STAGE="$STAGE_DIR/ipa"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

# ── ExportOptions plist ──────────────────────────────────────────
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions-Upload.plist"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>uploadSymbols</key>
    <true/>
    <key>manageAppVersionAndBuildNumber</key>
    <true/>
</dict>
</plist>
PLIST

# ── Archive ──────────────────────────────────────────────────────
JOBS="${SCRCPY_BUILD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"
echo "🔨 Archiving $SCHEME (Release)..."
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -parallelizeTargets \
    -allowProvisioningUpdates \
    IDEBuildOperationMaxNumberOfConcurrentCompileTasks="$JOBS" \
    -quiet

echo "✅ Archive complete: $ARCHIVE_PATH"

# ── Export & Upload ──────────────────────────────────────────────
echo "🚀 Exporting and uploading to App Store Connect..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_STAGE" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates \
    -quiet

# Upload succeeded — replace the previous export atomically.
# With destination=upload xcodebuild uploads directly and may not write
# an IPA to -exportPath, so only swap if something was actually exported.
if [ -d "$EXPORT_STAGE" ]; then
    rm -rf "$EXPORT_DIR"
    mv "$EXPORT_STAGE" "$EXPORT_DIR"
fi
rm -rf "$STAGE_DIR"

echo "✅ Upload complete! Please check TestFlight in App Store Connect for the new build."
