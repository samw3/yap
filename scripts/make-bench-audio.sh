#!/usr/bin/env bash
# Regenerate benchmark fixtures from whisper.cpp's bundled JFK sample.
# 16 kHz mono s16 -- the exact format our capture path produces and the only
# format parakeet accepts (PARAKEET_SAMPLE_RATE == 16000).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/third_party/whisper.cpp/samples/jfk.wav"
OUT="$ROOT/bench"
[ -f "$SRC" ] || { echo "missing $SRC -- run scripts/setup-deps.sh first" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg required (brew install ffmpeg)" >&2; exit 1; }
mkdir -p "$OUT"

for d in 2 5 11; do
  ffmpeg -v error -y -i "$SRC" -t "$d" -ar 16000 -ac 1 -c:a pcm_s16le "$OUT/jfk_${d}s.wav"
done
# 30 s by looping the 11 s source.
ffmpeg -v error -y -stream_loop 3 -i "$SRC" -t 30 -ar 16000 -ac 1 -c:a pcm_s16le "$OUT/jfk_30s.wav"
ls -lh "$OUT"/*.wav
