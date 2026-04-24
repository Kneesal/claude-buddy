#!/usr/bin/env python3
"""
Source-sprite generator for claude-buddy.

Produces `assets/species/<name>.png` — hand-drawn 64x64 pixel art in a kawaii
style, one per launch species. Deterministic: rerunning emits byte-identical
PNGs. License-clean: every pixel is placed by this script, committed with the
repo, no third-party art.

This is a contributor-time tool. End users never run it. The generated PNGs
are fed into `scripts/bake-sprites.sh` (chafa wrapper) which renders them to
Unicode sextant strings and writes back into `scripts/species/*.json`.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Tuple

from PIL import Image, ImageDraw

Color = Tuple[int, int, int, int]
Box = Tuple[int, int, int, int]

CANVAS = 64
ASSETS = Path(__file__).resolve().parent.parent.parent / "assets" / "species"


def new_canvas() -> tuple[Image.Image, ImageDraw.ImageDraw]:
    img = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    return img, ImageDraw.Draw(img)


def rect(d: ImageDraw.ImageDraw, box: Box, fill: Color, outline: Color | None = None) -> None:
    d.rectangle(box, fill=fill, outline=outline)


def pixel(d: ImageDraw.ImageDraw, x: int, y: int, fill: Color) -> None:
    d.rectangle((x, y, x, y), fill=fill)


def dot(d: ImageDraw.ImageDraw, cx: int, cy: int, r: int, fill: Color) -> None:
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=fill)


# ---------- species ----------

def draw_axolotl() -> Image.Image:
    # Pink cheerleader axolotl. Round head, frilly external gills, smile.
    img, d = new_canvas()
    body = (0xF6, 0xA8, 0xC4, 255)     # soft pink
    shade = (0xD9, 0x7E, 0xA0, 255)    # darker pink
    gill = (0xFF, 0xCC, 0xE0, 255)     # frilly pink
    outline = (0x5E, 0x2A, 0x3B, 255)
    blush = (0xFF, 0x90, 0xB8, 255)

    # Frilly gill tufts (three on each side) — drawn first so the head sits on top
    for cx in (6, 12, 18):
        dot(d, cx, 22, 4, gill)
    for cx in (46, 52, 58):
        dot(d, cx, 22, 4, gill)
    # Gill outline pass
    d.ellipse((2, 18, 10, 26), outline=outline)
    d.ellipse((8, 18, 16, 26), outline=outline)
    d.ellipse((14, 18, 22, 26), outline=outline)
    d.ellipse((42, 18, 50, 26), outline=outline)
    d.ellipse((48, 18, 56, 26), outline=outline)
    d.ellipse((54, 18, 62, 26), outline=outline)

    # Head / body blob (a tall rounded rectangle-ish shape)
    d.ellipse((12, 16, 52, 56), fill=body, outline=outline)
    # Body shadow (subtle bottom darkening)
    d.ellipse((18, 40, 46, 56), fill=shade, outline=None)
    d.ellipse((12, 16, 52, 56), outline=outline)

    # Smile (◡◡)
    d.arc((24, 32, 30, 40), start=0, end=180, fill=outline, width=1)
    d.arc((34, 32, 40, 40), start=0, end=180, fill=outline, width=1)
    # Small smile dot between
    d.arc((28, 40, 36, 46), start=0, end=180, fill=outline, width=1)

    # Cheek blush
    dot(d, 22, 40, 2, blush)
    dot(d, 42, 40, 2, blush)

    # Head top ridge highlight
    d.arc((16, 20, 48, 36), start=200, end=340, fill=(255, 240, 248, 255), width=1)
    return img


def draw_dragon() -> Image.Image:
    # Fierce green dragon, small horns, shoulder wings.
    img, d = new_canvas()
    body = (0x3E, 0x8E, 0x4A, 255)     # scale green
    belly = (0x86, 0xC9, 0x7A, 255)    # lighter green
    horn = (0xD9, 0xCE, 0x92, 255)     # cream
    outline = (0x1B, 0x3A, 0x1F, 255)
    eye_w = (255, 230, 160, 255)       # yellow sclera
    eye_d = outline

    # Wings (behind the body)
    d.polygon([(4, 26), (16, 18), (20, 36), (8, 34)], fill=body, outline=outline)
    d.polygon([(60, 26), (48, 18), (44, 36), (56, 34)], fill=body, outline=outline)
    # Wing ribs
    d.line([(12, 20), (12, 34)], fill=outline, width=1)
    d.line([(52, 20), (52, 34)], fill=outline, width=1)

    # Head / body (rounded blob)
    d.ellipse((16, 16, 48, 56), fill=body, outline=outline)
    # Belly
    d.ellipse((22, 32, 42, 56), fill=belly, outline=None)
    d.ellipse((16, 16, 48, 56), outline=outline)

    # Horns (two little triangles)
    d.polygon([(22, 18), (20, 10), (26, 16)], fill=horn, outline=outline)
    d.polygon([(42, 18), (44, 10), (38, 16)], fill=horn, outline=outline)

    # Fierce eyes — angled slits <_<
    # Left eye (angry slant)
    d.polygon([(22, 28), (28, 26), (28, 30), (22, 32)], fill=eye_w, outline=outline)
    pixel(d, 26, 28, eye_d); pixel(d, 26, 29, eye_d); pixel(d, 25, 28, eye_d)
    # Right eye
    d.polygon([(42, 26), (36, 28), (36, 32), (42, 30)], fill=eye_w, outline=outline)
    pixel(d, 38, 28, eye_d); pixel(d, 38, 29, eye_d); pixel(d, 39, 28, eye_d)

    # Toothy grin (downturned)
    d.line([(26, 42), (32, 44), (38, 42)], fill=outline, width=1)
    # Fangs
    pixel(d, 28, 43, (255, 255, 255, 255))
    pixel(d, 36, 43, (255, 255, 255, 255))

    # Nostrils
    pixel(d, 30, 36, outline); pixel(d, 34, 36, outline)
    return img


def draw_owl() -> Image.Image:
    # Stoic librarian owl with reading-glasses eyes and ear tufts.
    img, d = new_canvas()
    body = (0x8B, 0x5E, 0x3C, 255)     # tawny brown
    chest = (0xD9, 0xB0, 0x80, 255)    # lighter chest
    beak = (0xE8, 0xA5, 0x3A, 255)     # amber beak
    outline = (0x2B, 0x1B, 0x0E, 255)
    eye_w = (255, 250, 220, 255)
    eye_d = outline

    # Ear tufts (drawn first, behind head)
    d.polygon([(14, 14), (20, 6), (22, 18)], fill=body, outline=outline)
    d.polygon([(50, 14), (44, 6), (42, 18)], fill=body, outline=outline)

    # Body blob
    d.ellipse((12, 14, 52, 58), fill=body, outline=outline)
    # Chest patch
    d.ellipse((22, 30, 42, 56), fill=chest, outline=None)
    d.ellipse((12, 14, 52, 58), outline=outline)

    # Huge round reading-glasses eyes — two big circles with rims
    # Left eye
    d.ellipse((16, 22, 30, 36), fill=eye_w, outline=outline, width=1)
    # frame accent (reading glasses vibe — slightly thicker rim)
    d.ellipse((15, 21, 31, 37), outline=outline, width=1)
    dot(d, 23, 29, 2, eye_d)
    pixel(d, 22, 28, (255, 255, 255, 255))  # highlight
    # Right eye
    d.ellipse((34, 22, 48, 36), fill=eye_w, outline=outline, width=1)
    d.ellipse((33, 21, 49, 37), outline=outline, width=1)
    dot(d, 41, 29, 2, eye_d)
    pixel(d, 40, 28, (255, 255, 255, 255))
    # Bridge of the glasses
    d.line([(30, 29), (34, 29)], fill=outline, width=1)

    # Tiny beak
    d.polygon([(30, 38), (34, 38), (32, 42)], fill=beak, outline=outline)

    # Feather V on chest (small detail)
    d.line([(28, 46), (32, 50), (36, 46)], fill=outline, width=1)
    return img


def draw_ghost() -> Image.Image:
    # Whimsical spectral ghost. Rounded top, wavy tail.
    img, d = new_canvas()
    body = (0xE4, 0xEC, 0xF5, 255)     # pale blue-white
    body_shade = (0xB8, 0xC6, 0xD9, 255)
    outline = (0x3B, 0x4A, 0x5E, 255)
    eye_d = outline

    # Ghost silhouette: rounded dome at top, wavy bottom.
    # Start by drawing the upper dome as an ellipse
    top = (10, 8, 54, 48)
    d.ellipse(top, fill=body, outline=None)
    # Rectangle connecting dome to the wavy tail
    rect(d, (10, 28, 54, 50), body)
    # Wavy tail: three bumps
    bumps = [
        (10, 44, 24, 58),
        (22, 44, 42, 58),
        (40, 44, 54, 58),
    ]
    for b in bumps:
        d.ellipse(b, fill=body, outline=None)
    # Outline pass — trace the composite silhouette by drawing the outline
    # of the same shapes with no fill
    d.ellipse(top, outline=outline, width=1)
    for b in bumps:
        d.ellipse(b, outline=outline, width=1)
    # Vertical outline on the sides of the rectangle (between dome and bumps)
    d.line([(10, 28), (10, 50)], fill=outline, width=1)
    d.line([(54, 28), (54, 50)], fill=outline, width=1)

    # Shadow inside body
    d.ellipse((20, 38, 44, 48), fill=body_shade, outline=None)

    # Playful eyes (slightly asymmetric for personality)
    dot(d, 24, 28, 3, eye_d)
    dot(d, 40, 28, 3, eye_d)
    # Eye highlights
    pixel(d, 23, 27, (255, 255, 255, 255))
    pixel(d, 39, 27, (255, 255, 255, 255))

    # Open-smile mouth (o shape)
    d.ellipse((29, 34, 35, 40), fill=outline, outline=None)
    d.ellipse((30, 35, 34, 39), fill=(0xC0, 0x50, 0x70, 255), outline=None)

    # Little floating arm blobs on the sides
    dot(d, 8, 36, 3, body)
    d.ellipse((5, 33, 11, 39), outline=outline, width=1)
    dot(d, 56, 36, 3, body)
    d.ellipse((53, 33, 59, 39), outline=outline, width=1)
    return img


def draw_capybara() -> Image.Image:
    # Zen capybara. Stocky, half-lidded eyes.
    img, d = new_canvas()
    body = (0x8A, 0x61, 0x3C, 255)     # warm brown
    body_shade = (0x5E, 0x3F, 0x25, 255)
    snout = (0xB5, 0x8A, 0x5E, 255)
    outline = (0x2E, 0x1E, 0x10, 255)

    # Wide stocky body + head blob
    d.rounded_rectangle((8, 20, 56, 58), radius=14, fill=body, outline=outline, width=1)
    # Slight belly shade at the bottom
    d.rounded_rectangle((14, 44, 50, 56), radius=8, fill=body_shade, outline=None)
    d.rounded_rectangle((8, 20, 56, 58), radius=14, outline=outline, width=1)

    # Small rounded ears on top
    dot(d, 14, 20, 4, body)
    dot(d, 50, 20, 4, body)
    d.ellipse((10, 16, 18, 24), outline=outline)
    d.ellipse((46, 16, 54, 24), outline=outline)
    # Inner ear darker spots
    dot(d, 14, 20, 2, body_shade)
    dot(d, 50, 20, 2, body_shade)

    # Snout (lighter muzzle patch on the lower face)
    d.ellipse((22, 36, 42, 52), fill=snout, outline=outline, width=1)
    # Nostrils
    pixel(d, 30, 42, outline); pixel(d, 34, 42, outline)
    # Mouth
    d.line([(28, 48), (32, 50), (36, 48)], fill=outline, width=1)

    # Half-lidded zen eyes — horizontal lines, not dots
    d.line([(20, 30), (26, 30)], fill=outline, width=2)
    d.line([(38, 30), (44, 30)], fill=outline, width=2)
    # Tiny sleep mark above (optional personality)
    pixel(d, 22, 28, outline)
    pixel(d, 42, 28, outline)
    return img


# ---------- run ----------

SPECIES = {
    "axolotl": draw_axolotl,
    "dragon": draw_dragon,
    "owl": draw_owl,
    "ghost": draw_ghost,
    "capybara": draw_capybara,
}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Deterministic kawaii-portrait generator for claude-buddy. "
            "Writes one PNG per species to assets/species/. Contributor-time tool "
            "only — end users never run this."
        )
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Run every drawer but do not write PNGs (smoke-test). Exits 1 on any drawer error.",
    )
    args = parser.parse_args(argv)

    ASSETS.mkdir(parents=True, exist_ok=True)
    # Sorted so output order is deterministic across Python implementations.
    for name, drawer in sorted(SPECIES.items()):
        img = drawer()
        if img.size != (CANVAS, CANVAS) or img.mode != "RGBA":
            print(f"drawer {name!r} produced wrong shape: {img.size} {img.mode}", file=sys.stderr)
            return 1
        if args.check:
            print(f"ok  {name}.png ({img.size[0]}x{img.size[1]})", file=sys.stderr)
            continue
        out = ASSETS / f"{name}.png"
        img.save(out, format="PNG", optimize=True)
        print(f"wrote {out} ({img.size[0]}x{img.size[1]})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
