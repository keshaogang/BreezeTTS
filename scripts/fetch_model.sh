#!/bin/bash
# Robust resumable download for the Breeze TTS gguf weights.
# Usage: ./scripts/fetch_model.sh [q8_0|q4_k_m]
set -u

FILE_NAME="${1:-q8_0}"
case "$FILE_NAME" in
  q8_0)   GGUF="breeze-tts-2-q8_0.gguf" ;;
  q4_k_m) GGUF="breeze-tts-2-q4_k_m.gguf" ;;
  *) echo "unknown variant: $FILE_NAME"; exit 2 ;;
esac

DEST="$HOME/Library/Application Support/BreezeTTS/models"
mkdir -p "$DEST"
TARGET="$DEST/$GGUF"

MIRRORS=(
  "https://hf-mirror.com/HoppouAI/Breeze-TTS-2.cpp/resolve/main/$GGUF"
  "https://huggingface.co/HoppouAI/Breeze-TTS-2.cpp/resolve/main/$GGUF"
)

for attempt in $(seq 1 40); do
  SIZE=$(stat -f%z "$TARGET" 2>/dev/null || echo 0)
  echo "[fetch] attempt $attempt, have $SIZE bytes"
  for url in "${MIRRORS[@]}"; do
    curl -L --fail --retry 3 --retry-delay 2 --connect-timeout 20 \
         --speed-limit 200 --speed-time 30 -C - \
         "$url" -o "$TARGET" >>/tmp/breeze_fetch.log 2>&1
    rc=$?
    NEW=$(stat -f%z "$TARGET" 2>/dev/null || echo 0)
    echo "[fetch] rc=$rc size=$NEW"
    # A complete file downloads cleanly with rc=0.
    if [ $rc -eq 0 ] && [ "$NEW" -gt 1000000000 ]; then
      echo "[fetch] done: $TARGET ($NEW bytes)"
      exit 0
    fi
    # Two consecutive runs without any growth means this mirror is stuck.
    if [ "$NEW" -le "$SIZE" ]; then
      echo "[fetch] no progress on this mirror, rotating"
      break
    fi
  done
  sleep 2
done

echo "[fetch] gave up after 40 attempts"
exit 1
