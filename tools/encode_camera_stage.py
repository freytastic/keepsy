#!/usr/bin/env python3
"""Build the onboarding WebP from the transparent 120 fps PNG sequence

Motion is sampled at 40 fps, followed by one settled hold frame

    python3 tools/encode_camera_stage.py [--frames DIR] [--width PX]
"""
from __future__ import annotations

import argparse
import glob
import os
import sys

try:
    from PIL import Image, ImageEnhance, _webp
except ImportError:  # pragma: no cover , developer tooling
    sys.exit("Pillow is required: pip install --user Pillow")

CAPTURE_FPS = 120

# Keep one cadence through all motion; a single settled render prevents shimmer
SEGMENTS = [
    (3.35, 40),
]
FINAL_HOLD_SECONDS = 0.15

DEFAULT_WIDTH = 1400
QUALITY = 72

# Fixed midpoint contrast keeps transparent pixels from skewing the phone grade
SATURATION = 1.12
CONTRAST = 1.04


def measure_bounds(paths: list[str], step: int = 6) -> tuple[int, int, int, int]:
    left, top, right, bottom = 10**9, 10**9, -1, -1
    for path in paths[::step]:
        with Image.open(path) as image:
            box = image.getchannel("A").getbbox()
        if box is None:
            continue
        left, top = min(left, box[0]), min(top, box[1])
        right, bottom = max(right, box[2]), max(bottom, box[3])
    return left, top, right, bottom


def plan() -> list[tuple[int, int]]:
    """Frame index -> duration in ms, walking the segment table."""
    picked: list[tuple[int, int]] = []
    start = 0.0
    for end, fps in SEGMENTS:
        stride = round(CAPTURE_FPS / fps)
        duration = round(1000 * stride / CAPTURE_FPS)
        index = round(start * CAPTURE_FPS)
        while index < round(end * CAPTURE_FPS):
            picked.append((index, duration))
            index += stride
        start = end
    # One settled frame preserves the 3.5 sec timeline without edge shimmer
    picked.append((
        round(SEGMENTS[-1][0] * CAPTURE_FPS),
        round(FINAL_HOLD_SECONDS * 1000),
    ))
    return picked


def grade(image: Image.Image, saturation: float, contrast: float) -> Image.Image:
    """Adjust RGB without changing alpha."""
    if saturation == 1.0 and contrast == 1.0:
        return image
    r, g, b, a = image.split()
    rgb = Image.merge("RGB", (r, g, b))
    if saturation != 1.0:
        rgb = ImageEnhance.Color(rgb).enhance(saturation)
    if contrast != 1.0:
        lut = [max(0, min(255, round(128 + (v - 128) * contrast))) for v in range(256)]
        rgb = rgb.point(lut * 3)
    r, g, b = rgb.split()
    return Image.merge("RGBA", (r, g, b, a))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames", default="../keepsy-mock-final/frames_hq")
    parser.add_argument("--out", default="frontend/lib/assets/onboarding/camera_stage.webp")
    parser.add_argument("--width", type=int, default=DEFAULT_WIDTH)
    parser.add_argument("--crop", default=None,
                        help="left,top,right,bottom; measured from the frames "
                             "when omitted")
    parser.add_argument("--quality", type=int, default=QUALITY)
    parser.add_argument("--saturation", type=float, default=SATURATION)
    parser.add_argument("--contrast", type=float, default=CONTRAST)
    parser.add_argument("--measure", action="store_true",
                        help="print the union bounding box and exit")
    args = parser.parse_args()

    paths = sorted(glob.glob(os.path.join(args.frames, "frame_*.png")))
    if not paths:
        sys.exit(f"no frame_*.png under {args.frames}")

    if args.measure:
        print("CROP =", measure_bounds(paths))
        return

    # The crop changes with capture resolution, so measure it from the frames
    crop = (tuple(int(v) for v in args.crop.split(","))
            if args.crop else measure_bounds(paths))
    print(f"crop {crop}")
    height = round((crop[3] - crop[1]) * args.width / (crop[2] - crop[0]))
    schedule = plan()
    picked = [(index, duration) for index, duration in schedule
              if index < len(paths)]

    # Stream frames into libwebp instead of retaining the full RGBA sequence
    encoder = _webp.WebPAnimEncoder(
        (args.width, height),
        0x00000000,  # transparent RGBA background, packed as AARRGGBB
        0,           # loop forever; Flutter deliberately stops on the last frame
        True,        # minimize_size
        3,           # lossy keyframe defaults used by Pillow
        5,
        True,        # allow_mixed
        False,       # verbose
    )
    timestamp = 0
    for frame_number, (index, duration) in enumerate(picked):
        with Image.open(paths[index]) as source:
            image = source.convert("RGBA").crop(crop)
        resized = image.resize((args.width, height), Image.LANCZOS)
        image.close()
        encoded = grade(resized, args.saturation, args.contrast)
        resized.close()
        encoder.add(
            encoded.getim(),
            timestamp,
            False,         # lossless
            args.quality,
            100,           # alpha quality
            6,             # method
        )
        encoded.close()
        timestamp += duration
        if frame_number % 20 == 0:
            print(f"  encoded {frame_number + 1}/{len(picked)}", flush=True)

    encoder.add(None, timestamp, False, args.quality, 100, 0)
    data = encoder.assemble("", "", "")
    if data is None:
        sys.exit("libwebp failed to assemble the animation")

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "wb") as output:
        output.write(data)

    played = timestamp / 1000
    size = os.path.getsize(args.out)
    print(f"{len(picked)} frames  {args.width}x{height}  {played:.2f}s  "
          f"{size / 1024 / 1024:.2f} MB -> {args.out}")
    print("Keep _kMasterWidth in camera_stage.dart equal to --width.")


if __name__ == "__main__":
    main()
