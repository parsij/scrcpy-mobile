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
# ---------------------------------------------------------------------------
echo ""
echo "📤 Uploading IPA to dev-ipa.wsen.me..."
UPLOAD_RESP=$(curl -sS -X POST https://dev-ipa.wsen.me/api/upload \
  -F "file=@${IPA_PATH}")
echo "Upload response: $UPLOAD_RESP"

# Try to pull out id / url from the JSON response for convenience. Best
# effort only — never let a parse failure abort the script.
if command -v python3 >/dev/null 2>&1; then
    python3 - "$UPLOAD_RESP" <<'PY' || true
import json, sys
raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)
if isinstance(data, dict):
    for key in ("id", "url"):
        if key in data and data[key]:
            print(f"   {key}: {data[key]}")
PY
fi

# Success is signalled by the presence of an "id" field in the JSON body.
if printf '%s' "$UPLOAD_RESP" | grep -q '"id"'; then
    echo "✅ Upload succeeded! Install at: https://dev-ipa.wsen.me"
else
    echo "❌ Upload may have failed, check response above"
    exit 1
fi
