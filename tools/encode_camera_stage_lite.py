#!/usr/bin/env python3
"""Derive the lite animation, settled still and probe from the shipped master

Usage:
  python3 tools/encode_camera_stage_lite.py [--width PX] [--fps N]
"""
from __future__ import annotations

import argparse
import os
import sys
import time

try:
    from PIL import Image, _webp
except ImportError:  # pragma: no cover
    sys.exit("Pillow is required: pip install --user Pillow")

MASTER = "client/lib/assets/onboarding/camera_stage.webp"
LITE_OUT = "client/lib/assets/onboarding/camera_stage_lite.webp"
STILL_OUT = "client/lib/assets/onboarding/camera_stage_still.webp"
PROBE_OUT = "client/lib/assets/onboarding/camera_stage_probe.webp"

# Probe master frames 119-123 to sample late decode cost
PROBE_START = 119
PROBE_FRAMES = 5
MASTER_QUALITY = 72

DEFAULT_WIDTH = 720
DEFAULT_FPS = 30
QUALITY = 78
STILL_QUALITY = 90


def read_master(path: str) -> tuple[list[Image.Image], list[int]]:
    """Return frames and start times including the final end time"""
    dec = _webp.WebPAnimDecoder(open(path, "rb").read())
    (width, height), _, _, count, mode = dec.get_info()
    frames, starts = [], [0]
    for _ in range(count):
        data, end = dec.get_next()
        frames.append(Image.frombuffer(mode, (width, height), data, "raw",
                                       mode, 0, 1).copy())
        starts.append(end)
    return frames, starts


def resample(starts: list[int], fps: int) -> list[tuple[int, int]]:
    """Preserve motion and final hold durations when changing frame rate"""
    motion_end = starts[-2]  # the last master frame is the settled hold
    picked: list[tuple[int, int]] = []
    k = 0
    while round(k * 1000 / fps) < motion_end:
        t = round(k * 1000 / fps)
        end = min(round((k + 1) * 1000 / fps), motion_end)
        index = max(i for i in range(len(starts) - 1) if starts[i] <= t)
        picked.append((index, end - t))
        k += 1
    picked.append((len(starts) - 2, starts[-1] - motion_end))
    return picked


def encode(frames, picked, width, quality) -> bytes:
    height = round(frames[0].height * width / frames[0].width)
    # minimize_size disables periodic keyframes
    encoder = _webp.WebPAnimEncoder((width, height), 0x00000000, 0, True,
                                    3, 5, True, False)
    timestamp = 0
    for index, duration in picked:
        image = frames[index].resize((width, height), Image.LANCZOS)
        encoder.add(image.getim(), timestamp, False, quality, 100, 6)
        timestamp += duration
    encoder.add(None, timestamp, False, quality, 100, 0)
    return encoder.assemble("", "", "")


def decode_ms(data: bytes, rounds: int = 3) -> float:
    """Host decode timing for relative comparisons only"""
    best = []
    for _ in range(rounds):
        dec = _webp.WebPAnimDecoder(data)
        count = dec.get_info()[3]
        start = time.perf_counter()
        for _ in range(count):
            dec.get_next()
        best.append((time.perf_counter() - start) * 1000 / count)
    return sorted(best)[len(best) // 2]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--master", default=MASTER)
    parser.add_argument("--out", default=LITE_OUT)
    parser.add_argument("--still", default=STILL_OUT)
    parser.add_argument("--probe", default=PROBE_OUT)
    parser.add_argument("--width", type=int, default=DEFAULT_WIDTH)
    parser.add_argument("--fps", type=int, default=DEFAULT_FPS)
    parser.add_argument("--quality", type=int, default=QUALITY)
    args = parser.parse_args()

    frames, starts = read_master(args.master)
    picked = resample(starts, args.fps)
    data = encode(frames, picked, args.width, args.quality)
    with open(args.out, "wb") as output:
        output.write(data)
    played = sum(duration for _, duration in picked) / 1000
    print(f"{len(picked)} frames  {args.width}px  {args.fps} fps  "
          f"{played:.2f}s  {len(data) / 1024:.0f} KB  "
          f"decode {decode_ms(data):.2f} ms/frame here -> {args.out}")
    print(f"master decode {decode_ms(open(args.master, 'rb').read()):.2f} "
          "ms/frame here")

    frames[-1].save(args.still, "WEBP", quality=STILL_QUALITY, method=6)
    print(f"still {frames[-1].width}px  "
          f"{os.path.getsize(args.still) / 1024:.0f} KB -> {args.still}")
    master_width = frames[0].width
    probe = [(i, 25) for i in range(PROBE_START, PROBE_START + PROBE_FRAMES)]
    data = encode(frames, probe, master_width, MASTER_QUALITY)
    with open(args.probe, "wb") as output:
        output.write(data)
    print(f"probe {PROBE_FRAMES} frames from {PROBE_START}  "
          f"{len(data) / 1024:.0f} KB -> {args.probe}")
    print("Keep _kLiteWidth in camera_stage.dart equal to --width.")


if __name__ == "__main__":
    main()
