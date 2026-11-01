#!/bin/bash
# Finish the ranged download without ever deleting a temp file (the sandbox
# blocks bulk deletes). Each part is topped up by appending curl's stdout, then
# all parts are concatenated into the final gguf.
set -u

URL="https://hf-mirror.com/HoppouAI/Breeze-TTS-2.cpp/resolve/main/breeze-tts-2-q8_0.gguf"
TOTAL=3568844480
PARTS=6
DEST="$HOME/Library/Application Support/BreezeTTS/models"
NAME="breeze-tts-2-q8_0.gguf"
SPAN=$((TOTAL / PARTS))

for i in $(seq 0 $((PARTS - 1))); do
  START=$((i * SPAN))
  if [ "$i" -eq $((PARTS - 1)) ]; then
    END=$((TOTAL - 1))
  else
    END=$((START + SPAN - 1))
  fi
  WANT=$((END - START + 1))
  PART="$DEST/.$NAME.part$i"

  for attempt in $(seq 1 30); do
    HAVE=$(stat -f%z "$PART" 2>/dev/null || echo 0)
    if [ "$HAVE" -ge "$WANT" ]; then
      echo "[part $i] complete $HAVE/$WANT"
      break
    fi
    FROM=$((START + HAVE))
    echo "[part $i] attempt $attempt: $HAVE/$WANT, fetching $FROM-$END"
    curl -sL --fail --connect-timeout 15 --max-time 300 \
         -r "$FROM-$END" "$URL" >> "$PART" || echo "[part $i] chunk ended rc=$?"
  done
done

# Verify every part before assembling.
TOTALBYTES=0
for i in $(seq 0 $((PARTS - 1))); do
  PART="$DEST/.$NAME.part$i"
  SIZE=$(stat -f%z "$PART" 2>/dev/null || echo 0)
  TOTALBYTES=$((TOTALBYTES + SIZE))
  echo "part $i = $SIZE"
done

if [ "$TOTALBYTES" -ne "$TOTAL" ]; then
  echo "size mismatch: $TOTALBYTES vs $TOTAL"
  exit 1
fi

cat "$DEST"/."$NAME".part0 "$DEST"/."$NAME".part1 "$DEST"/."$NAME".part2 \
    "$DEST"/."$NAME".part3 "$DEST"/."$NAME".part4 "$DEST"/."$NAME".part5 \
    > "$DEST/$NAME.assembling"
mv "$DEST/$NAME.assembling" "$DEST/$NAME"
echo "done: $(stat -f%z "$DEST/$NAME") bytes"
