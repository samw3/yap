#!/usr/bin/env bash
# Download the two models. ~1.1 GB total; skipped if already present.
set -euo pipefail
MD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/models"
mkdir -p "$MD"

get() { # $1=filename $2=url $3=min-bytes
  if [ -f "$MD/$1" ]; then
    local sz; sz=$(stat -f%z "$MD/$1")
    if [ "$sz" -ge "$3" ]; then echo "== $1 present (${sz} bytes)"; return; fi
    echo "== $1 truncated (${sz} < $3) -- refetching"
  fi
  echo "== fetching $1"
  curl -fL --progress-bar -o "$MD/$1.part" "$2"
  mv "$MD/$1.part" "$MD/$1"
}

# S1-mini by Superwhisper -- Apache 2.0 plus a naming clause (see NOTICE).
get s1-mini-q4_k_m.gguf \
  "https://huggingface.co/superwhisper/s1-mini-GGUF/resolve/main/s1-mini-q4_k_m.gguf" \
  480000000

# Parakeet TDT 0.6B v3, ggml conversion by ggml-org.
get ggml-parakeet-tdt-0.6b-v3-q8_0.bin \
  "https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/ggml-parakeet-tdt-0.6b-v3-q8_0.bin" \
  650000000

ls -lh "$MD"
