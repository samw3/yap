#!/usr/bin/env bash
# Clone the two native deps at exact pinned commits.
#
# Deliberately NOT git submodules: we want --depth 1 (250 MB instead of GBs of
# history), and shallow/grafted checkouts interact badly with submodule pinning.
# A pinned SHA here is just as reproducible.
#
# When bumping either pin, re-verify with `ninja yap-smoke && ./build/yap-smoke ...`:
# the two projects each vendor ggml and only one copy is built (llama.cpp's, since
# it is added to the CMake graph first). A successful *link* is not sufficient
# evidence -- run a real transcription AND a real completion.
set -euo pipefail

LLAMA_REPO="https://github.com/ggml-org/llama.cpp.git"
LLAMA_SHA="c1d0e7a004015f23bc0233470b747b596f29b264"   # tag v0.3.0 / b10621, 2026-08-25

WHISPER_REPO="https://github.com/ggml-org/whisper.cpp.git"
WHISPER_SHA="978113305b2ead22249b881deafa131dc8884911"  # master, 2026-08-25 (has include/parakeet.h)

TP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/third_party"
mkdir -p "$TP"

fetch() { # $1=dir $2=repo $3=sha
  local dir="$TP/$1"
  if [ -d "$dir/.git" ]; then
    local have; have="$(git -C "$dir" rev-parse HEAD)"
    if [ "$have" = "$3" ]; then echo "== $1 already at $3"; return; fi
    echo "== $1 at $have, want $3 -- refetching"
  fi
  rm -rf "$dir"
  git init -q "$dir"
  git -C "$dir" remote add origin "$2"
  git -C "$dir" fetch -q --depth 1 origin "$3"
  git -C "$dir" checkout -q FETCH_HEAD
  echo "== $1 -> $3"
}

fetch llama.cpp   "$LLAMA_REPO"   "$LLAMA_SHA"
fetch whisper.cpp "$WHISPER_REPO" "$WHISPER_SHA"

# Sanity: the files our build actually depends on.
test -f "$TP/llama.cpp/include/llama.h"      || { echo "missing llama.h" >&2; exit 1; }
test -f "$TP/whisper.cpp/include/parakeet.h" || { echo "missing parakeet.h" >&2; exit 1; }
grep -q "NOT TARGET ggml" "$TP/llama.cpp/CMakeLists.txt"   || { echo "llama.cpp lost its ggml guard" >&2; exit 1; }
grep -q "NOT TARGET ggml" "$TP/whisper.cpp/CMakeLists.txt" || { echo "whisper.cpp lost its ggml guard" >&2; exit 1; }
echo "== deps OK (shared-ggml guards present in both)"
