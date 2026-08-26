#!/usr/bin/env bash
# Build, bundle, sign, relaunch. Keeps TCC grants intact across rebuilds by
# signing with a real certificate identity (a stable designated requirement)
# rather than ad-hoc (which pins to a cdhash that changes every build).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${YAP_APP_PATH:-$HOME/Applications/Yap.app}"   # MUST stay stable; TCC notices moves
BUILD="$REPO/build"
IDENTITY="${YAP_SIGN_IDENTITY:-Developer ID Application: Sam Washburn (266VNLKVKQ)}"

echo "==> build"
ninja -C "$BUILD" yap

echo "==> bundle -> $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Single canonical plist. Never let a dev heredoc drift from the release one.
cp "$REPO/bundle/Info.plist" "$APP/Contents/Info.plist"
cp "$BUILD/yap"              "$APP/Contents/MacOS/yap"
cp "$REPO/bundle/Yap.icns"   "$APP/Contents/Resources/Yap.icns"
chmod +x "$APP/Contents/MacOS/yap"

# Models live in Resources so ggml/Metal lookups and our own paths are bundle-relative.
for m in "$REPO"/models/*.gguf "$REPO"/models/*.bin; do
  [ -e "$m" ] || continue
  cp -c "$m" "$APP/Contents/Resources/" 2>/dev/null || cp "$m" "$APP/Contents/Resources/"
done

echo "==> sign"
# No --deep (deprecated, nothing nested). No --options runtime for local dev:
# hardened runtime without com.apple.security.device.audio-input silently kills the mic.
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
# A stable DR prints leaf[subject.OU]; a cdhash here means TCC will forget us next build.
if codesign -d -r- "$APP" 2>&1 | grep -q 'cdhash'; then
  echo "!! WARNING: ad-hoc/cdhash designated requirement -- permissions will reset on rebuild" >&2
fi

echo "==> relaunch"
pkill -x yap 2>/dev/null || true
for _ in $(seq 1 40); do pgrep -x yap >/dev/null || break; sleep 0.05; done
open "$APP"
# `open` returns before the process exists, so poll rather than sleeping blind.
for _ in $(seq 1 60); do pgrep -x yap >/dev/null && break; sleep 0.05; done
echo "==> pid $(pgrep -x yap || echo '<not running>')"
echo "    logs: log stream --predicate 'process == \"yap\"' --style compact"
