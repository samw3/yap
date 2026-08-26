#!/usr/bin/env bash
# Regenerate bundle/Yap.icns from scripts/make-icon.mm.
#
# The .icns is committed, so building and shipping the app never needs this script
# -- run it only after editing the artwork.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/scripts/make-icon.mm"
OUT="$ROOT/bundle/Yap.icns"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> compile generator"
clang++ -std=c++17 -fobjc-arc -O1 -o "$TMP/mkicon" "$SRC" -framework AppKit

echo "==> render sizes"
"$TMP/mkicon" "$TMP/Yap.iconset"

echo "==> pack .icns"
iconutil -c icns "$TMP/Yap.iconset" -o "$OUT"
echo "==> $OUT ($(du -h "$OUT" | cut -f1))"
