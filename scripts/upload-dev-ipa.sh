#!/bin/bash
#
# upload-dev-ipa.sh — upload a built Scrcpy Remote .ipa to the internal OTA
# service dev-ipa.wsen.me (multipart POST, no auth). This is SEPARATE from:
#   - scripts/upload.sh  (App Store Connect / TestFlight distribution)
#
# Usage: scripts/upload-dev-ipa.sh [path-to-ipa]
#   No arg   -> auto-locate the IPA under build/debug (see resolve_ipa).
#   With arg -> upload that exact IPA.
#
set -euo pipefail

ENDPOINT="https://dev-ipa.wsen.me/api/upload"
INSTALL_URL="https://dev-ipa.wsen.me"

# Resolve repo root from this script's location (scripts/ -> repo root).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

resolve_ipa() {
    local arg="${1:-}"
    if [ -n "$arg" ]; then
        if [ -f "$arg" ]; then
            printf '%s' "$arg"
            return 0
        fi
        echo "❌ No such file: $arg" >&2
        return 1
    fi

    # 1) The canonical path written by scripts/build-debug-ipa.sh.
    if [ -f "$REPO_ROOT/build/debug/Scrcpy Remote.ipa" ]; then
        printf '%s' "$REPO_ROOT/build/debug/Scrcpy Remote.ipa"
        return 0
    fi
    # 2) Otherwise the newest IPA anywhere under build/.
    local found
    found=$(/usr/bin/find "$REPO_ROOT/build" -maxdepth 3 -name '*.ipa' -type f 2>/dev/null \
            | xargs -I{} stat -f '%m %N' {} 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
    if [ -n "$found" ]; then
        printf '%s' "$found"
        return 0
    fi
    echo "❌ No .ipa found under $REPO_ROOT/build. Build one first (e.g. 'make debug-ipa')." >&2
    return 1
}

IPA_PATH=$(resolve_ipa "${1:-}")
IPA_SIZE=$(stat -f '%z' "$IPA_PATH" 2>/dev/null || echo "?")
echo "📦 IPA: $IPA_PATH (${IPA_SIZE} bytes)"
echo "📤 Uploading to ${ENDPOINT} ..."

UPLOAD_RESP=$(curl -sS -X POST "$ENDPOINT" -F "file=@${IPA_PATH}")
echo "Response: $UPLOAD_RESP"

# Pull id / version / name out of the JSON for a tidy summary (best effort).
if command -v python3 >/dev/null 2>&1; then
    python3 - "$UPLOAD_RESP" <<'PY' || true
import json, sys
raw = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)
# id/version may be top-level or nested under "data".
node = data.get("data", data) if isinstance(data, dict) else {}
for key in ("id", "version", "build", "name", "identifier"):
    if isinstance(node, dict) and node.get(key):
        print(f"   {key}: {node[key]}")
PY
fi

if printf '%s' "$UPLOAD_RESP" | grep -q '"id"'; then
    echo "✅ Upload succeeded! Install at: ${INSTALL_URL}"
    exit 0
else
    echo "❌ Upload may have failed — see response above."
    exit 1
fi
