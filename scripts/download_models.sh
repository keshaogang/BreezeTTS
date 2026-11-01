#!/bin/bash
# Download and verify the GGUF weights.
#
#   scripts/download_models.sh                 # Q8_0 into the app support folder
#   scripts/download_models.sh q4_k /tmp/m     # a specific tier elsewhere
#
# HuggingFace is blocked on some networks, so the mirror is the default. Set
# HF_BASE=https://huggingface.co/HoppouAI/Breeze-TTS-2.cpp/resolve/main to go direct.
set -euo pipefail

DEST="${2:-$HOME/Library/Application Support/BreezeTTS/models}"
TIER="${1:-q8_0}"
BASE="${HF_BASE:-https://hf-mirror.com/HoppouAI/Breeze-TTS-2.cpp/resolve/main}"

mkdir -p "$DEST"

# name -> exact byte count, so a truncated download is never mistaken for a model
case "$TIER" in
  f16)        FILE=breeze-tts-2-f16.gguf;        SIZE=6279630784 ;;
  q8_0)       FILE=breeze-tts-2-q8_0.gguf;       SIZE=3568844480 ;;
  q6_k)       FILE=breeze-tts-2-q6_k.gguf;       SIZE=3069969664 ;;
  q4_k)       FILE=breeze-tts-2-q4_k.gguf;       SIZE=2538909376 ;;
  q8_0_dd2)   FILE=breeze-tts-2-q8_0-dd2.gguf;   SIZE=3322429120 ;;
  q8_0_dd4)   FILE=breeze-tts-2-q8_0-dd4.gguf;   SIZE=3401072320 ;;
  q4_k_dd2)   FILE=breeze-tts-2-q4_k-dd2.gguf;   SIZE=2460266176 ;;
  ref_voice)  FILE=ref_voice.wav;                SIZE=257324 ;;
  all)
    for t in f16 q8_0 q6_k q4_k q8_0_dd2 q8_0_dd4 q4_k_dd2 ref_voice; do
      "$0" "$t" "$DEST"
    done
    exit 0 ;;
  *)
    echo "unknown tier: $TIER" >&2
    echo "choose from: f16 q8_0 q6_k q4_k q8_0_dd2 q8_0_dd4 q4_k_dd2 ref_voice all" >&2
    exit 2 ;;
esac

OUT="$DEST/$FILE"
if [ -f "$OUT" ]; then
  GOT=$(stat -f%z "$OUT")
  if [ "$GOT" = "$SIZE" ]; then
    echo "OK   $FILE ($GOT bytes)"
    exit 0
  fi
  echo "resuming $FILE at $GOT / $SIZE"
fi

curl -L --fail -C - --retry 5 --retry-delay 3 --progress-bar "$BASE/$FILE" -o "$OUT"

GOT=$(stat -f%z "$OUT")
if [ "$GOT" != "$SIZE" ]; then
  echo "SIZE_MISMATCH $FILE ($GOT / $SIZE)" >&2
  exit 1
fi
echo "OK   $FILE ($GOT bytes)"
