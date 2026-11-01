#!/usr/bin/env python3
"""Parallel, resumable downloader for the Breeze TTS weights.

hf-mirror pins each connection to a different edge node and a single connection
averages well under 2 MB/s, which turns a 3.3 GB file into an hour. Splitting
the file into byte ranges and fetching them concurrently fixes that. Every
worker keeps whatever arrived before a connection drop, so a flaky network
still makes monotonic progress.
"""
import os
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

URL = "https://hf-mirror.com/HoppouAI/Breeze-TTS-2.cpp/resolve/main/breeze-tts-2-q8_0.gguf"
TOTAL = 3568844480
DEST = os.path.expanduser("~/Library/Application Support/BreezeTTS/models")
NAME = os.environ.get("BREEZE_MODEL_FILE", "breeze-tts-2-q8_0.gguf")
TOTAL = int(os.environ.get("BREEZE_MODEL_BYTES", TOTAL))
URL = ("https://hf-mirror.com/HoppouAI/Breeze-TTS-2.cpp/resolve/main/"
       + os.environ.get("BREEZE_MODEL_URL_PATH", NAME))
TARGET = os.path.join(DEST, NAME)
PARTS = 6
CHUNK_SECONDS = 90


def part_path(i: int) -> str:
    return os.path.join(DEST, f".{NAME}.part{i}")


def fetch(i: int, start: int, end: int) -> bool:
    want = end - start + 1
    path = part_path(i)
    tmp = path + ".tmp"

    def absorb_tmp() -> None:
        """Fold any leftover temp bytes into the part file."""
        if os.path.exists(tmp):
            if os.path.getsize(tmp) > 0:
                with open(tmp, "rb") as src, open(path, "ab") as dst:
                    shutil.copyfileobj(src, dst, 1 << 20)
            os.remove(tmp)

    for attempt in range(1, 41):
        absorb_tmp()
        have = os.path.getsize(path) if os.path.exists(path) else 0
        if have >= want:
            return True
        if have > want:
            os.remove(path)
            have = 0

        cmd = [
            "curl", "-L", "--fail", "--silent", "--show-error",
            "--connect-timeout", "15", "--max-time", str(CHUNK_SECONDS),
            "-r", f"{start + have}-{end}", "-o", tmp, URL,
        ]
        rc = subprocess.call(cmd, stderr=subprocess.DEVNULL)

        # Whatever landed in the temp file is a valid continuation of the part:
        # keep it even when curl aborted mid-stream.
        absorb_tmp()

        now = os.path.getsize(path) if os.path.exists(path) else 0
        if now >= want:
            print(f"[part {i}] done {want} bytes", flush=True)
            return True
        if now == have and rc != 0:
            time.sleep(min(15, attempt * 2))
    return False


def main() -> int:
    os.makedirs(DEST, exist_ok=True)
    if os.path.exists(TARGET) and os.path.getsize(TARGET) == TOTAL:
        print("already complete", flush=True)
        return 0

    # Recover bytes from a previous run that was killed mid-chunk.
    for i in range(PARTS):
        part = part_path(i)
        tmp = part + ".tmp"
        if os.path.exists(tmp):
            if os.path.getsize(tmp) > 0:
                with open(tmp, "rb") as src, open(part, "ab") as dst:
                    shutil.copyfileobj(src, dst, 1 << 20)
            os.remove(tmp)
            print(f"[part {i}] recovered {os.path.getsize(part)} bytes", flush=True)

    span = TOTAL // PARTS
    jobs = []
    for i in range(PARTS):
        start = i * span
        end = TOTAL - 1 if i == PARTS - 1 else start + span - 1
        jobs.append((i, start, end))

    with ThreadPoolExecutor(max_workers=PARTS) as pool:
        results = list(pool.map(lambda job: fetch(*job), jobs))

    if not all(results):
        print("some parts failed", flush=True)
        return 1

    with open(TARGET + ".assembling", "wb") as out:
        for i, _, _ in jobs:
            with open(part_path(i), "rb") as src:
                shutil.copyfileobj(src, out, 4 << 20)
    os.replace(TARGET + ".assembling", TARGET)
    for i, _, _ in jobs:
        os.remove(part_path(i))

    size = os.path.getsize(TARGET)
    print(f"done: {TARGET} {size} bytes (expected {TOTAL})", flush=True)
    return 0 if size == TOTAL else 1


if __name__ == "__main__":
    sys.exit(main())
