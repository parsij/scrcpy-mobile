#!/bin/bash
#
# build-debug-ipa.sh — archive + export a Debug IPA with full debug symbols.
#
# Produces:
#   build/debug/Scrcpy Remote.xcarchive   (archive, dSYMs bundled inside)
#   build/debug/Scrcpy Remote.ipa         (development-signed Debug IPA)
#   build/debug/dSYMs/                     (copy of the archive's dSYMs for
#                                           offline crash symbolication)
#
# Debug symbols are preserved end to end:
#   - archive built with DEBUG_INFORMATION_FORMAT=dwarf-with-dsym
#   - symbols not stripped (STRIP_INSTALLED_PRODUCT/COPY_PHASE_STRIP = NO)
#   - export keeps symbols (uploadSymbols = true)
#
set -euo pipefail

# Resolve repo root from this script's location (scripts/ -> repo root).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT="$REPO_ROOT/scrcpy-app/Scrcpy Remote.xcodeproj"
SCHEME="Scrcpy Remote"
CONFIGURATION="Debug"
TEAM_ID="K8Q74NT2BG"

OUT_DIR="$REPO_ROOT/build/debug"
ARCHIVE_PATH="$OUT_DIR/Scrcpy Remote.xcarchive"
IPA_DIR="$OUT_DIR"
IPA_PATH="$OUT_DIR/Scrcpy Remote.ipa"
EXPORT_OPTIONS="$OUT_DIR/ExportOptions.plist"
DSYM_DEST="$OUT_DIR/dSYMs"

mkdir -p "$OUT_DIR"

echo "==> Archiving (Debug, dwarf-with-dsym, no strip)…"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    DEBUG_INFORMATION_FORMAT=dwarf-with-dsym \
    ENABLE_BITCODE=NO \
    STRIP_INSTALLED_PRODUCT=NO \
    COPY_PHASE_STRIP=NO

echo "==> Writing ExportOptions.plist…"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>compileBitcode</key>
    <false/>
    <key>uploadBitcode</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

echo "==> Exporting IPA…"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$IPA_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS"

# xcodebuild names the exported IPA after the scheme; normalize to our
# expected path if it differs.
EXPORTED_IPA="$(/usr/bin/find "$IPA_DIR" -maxdepth 1 -name '*.ipa' -print -quit)"
if [ -n "$EXPORTED_IPA" ] && [ "$EXPORTED_IPA" != "$IPA_PATH" ]; then
    mv -f "$EXPORTED_IPA" "$IPA_PATH"
fi

echo "==> Copying dSYMs for symbolication…"
rm -rf "$DSYM_DEST"
mkdir -p "$DSYM_DEST"
if [ -d "$ARCHIVE_PATH/dSYMs" ]; then
    cp -R "$ARCHIVE_PATH/dSYMs/." "$DSYM_DEST/"
fi

echo ""
echo "==> Done."
echo "    Archive: $ARCHIVE_PATH"
echo "    IPA:     $IPA_PATH"
echo "    dSYMs:   $DSYM_DEST"

# ---------------------------------------------------------------------------
# Upload the freshly-built IPA to the internal OTA distribution service.
#
# Delegated to scripts/upload-dev-ipa.sh so the upload can also be re-run on
# its own without rebuilding. Invoked with `set +e` because the archive, IPA
# and dSYMs above are the real output of this script: a failed upload (service
# down, no network) should warn rather than discard a successful build.
# ---------------------------------------------------------------------------
echo ""
set +e
bash "$SCRIPT_DIR/upload-dev-ipa.sh" "$IPA_PATH"
UPLOAD_STATUS=$?
set -e

if [ "$UPLOAD_STATUS" -ne 0 ]; then
    echo ""
    echo "⚠️  Upload failed (exit $UPLOAD_STATUS), but the build succeeded."
    echo "    Retry with: bash scripts/upload-dev-ipa.sh \"$IPA_PATH\""
fi
