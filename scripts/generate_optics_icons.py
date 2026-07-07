#!/usr/bin/env python3
"""Generate Optics SI icon assets from a source PNG.

Creates:
- 512x512 PNG
- 192x192 PNG
- multi-size ICO (256, 128, 64, 48, 32, 16)

Requires Pillow:
  pip install pillow
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw


def parse_color(value: str) -> tuple[int, int, int, int]:
    """Parse hex color strings (#RRGGBB or #RRGGBBAA) into RGBA tuples."""
    v = value.strip().lstrip("#")
    if len(v) == 6:
        return (int(v[0:2], 16), int(v[2:4], 16), int(v[4:6], 16), 255)
    if len(v) == 8:
        return (int(v[0:2], 16), int(v[2:4], 16), int(v[4:6], 16), int(v[6:8], 16))
    raise ValueError(f"Invalid color format: {value}")


def rounded_rect_mask(size: int, radius_ratio: float) -> Image.Image:
    """Return an L-mode rounded rectangle mask for a square image."""
    mask = Image.new("L", (size, size), 0)
    radius = max(0, min(size // 2, int(size * radius_ratio)))
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def padded_square(
    img: Image.Image,
    size: int,
    padding_ratio: float = 0.08,
    bg_color: tuple[int, int, int, int] = (255, 255, 255, 255),
    rounded_ratio: float = 0.18,
) -> Image.Image:
    """Center logo on a square icon with configurable padding/background/corners."""
    canvas = Image.new("RGBA", (size, size), bg_color)
    inner = int(size * (1.0 - padding_ratio * 2.0))
    icon = img.copy()
    # Resize to fit inner box while preserving aspect ratio. Unlike thumbnail(),
    # this allows upscaling so tighter padding actually affects output size.
    src_w, src_h = icon.size
    if src_w > 0 and src_h > 0:
        scale = min(inner / src_w, inner / src_h)
        new_w = max(1, int(round(src_w * scale)))
        new_h = max(1, int(round(src_h * scale)))
        icon = icon.resize((new_w, new_h), Image.Resampling.LANCZOS)
    x = (size - icon.width) // 2
    y = (size - icon.height) // 2
    canvas.alpha_composite(icon, (x, y))

    if rounded_ratio > 0:
        mask = rounded_rect_mask(size, rounded_ratio)
        rounded = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        rounded.paste(canvas, (0, 0), mask)
        return rounded
    return canvas


def trim_outer_margins(
    img: Image.Image,
    white_threshold: int = 245,
    alpha_threshold: int = 8,
) -> Image.Image:
    """Trim transparent/near-white outer margins from a logo image.

    Content pixel rule (primary pass):
    - alpha > alpha_threshold, and
    - at least one RGB channel is below white_threshold

    If that finds no pixels, falls back to alpha-only trimming.
    """
    rgba = img.convert("RGBA")
    px = rgba.load()
    w, h = rgba.size

    min_x, min_y = w, h
    max_x, max_y = -1, -1

    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a > alpha_threshold and (r < white_threshold or g < white_threshold or b < white_threshold):
                if x < min_x:
                    min_x = x
                if y < min_y:
                    min_y = y
                if x > max_x:
                    max_x = x
                if y > max_y:
                    max_y = y

    # Fallback: if source is mostly white logo on transparent/white background.
    if max_x < 0 or max_y < 0:
        min_x, min_y = w, h
        max_x, max_y = -1, -1
        for y in range(h):
            for x in range(w):
                _, _, _, a = px[x, y]
                if a > alpha_threshold:
                    if x < min_x:
                        min_x = x
                    if y < min_y:
                        min_y = y
                    if x > max_x:
                        max_x = x
                    if y > max_y:
                        max_y = y

    if max_x < 0 or max_y < 0:
        return rgba

    return rgba.crop((min_x, min_y, max_x + 1, max_y + 1))


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate PNG/ICO app icons from a PNG logo")
    parser.add_argument(
        "--source",
        default="docs/logo/optics_si_logo_v1.png",
        help="Path to source PNG logo",
    )
    parser.add_argument(
        "--out-dir",
        default="docs/logo",
        help="Directory for generated icon assets",
    )
    parser.add_argument(
        "--name-prefix",
        default="optics_si_icon",
        help="Base filename prefix for generated outputs",
    )
    parser.add_argument(
        "--padding",
        type=float,
        default=0.04,
        help="Default inner logo padding ratio on each side (default: 0.04)",
    )
    parser.add_argument(
        "--padding-512",
        type=float,
        default=None,
        help="Padding ratio for 512 icon (overrides --padding)",
    )
    parser.add_argument(
        "--padding-192",
        type=float,
        default=None,
        help="Padding ratio for 192 icon (overrides --padding)",
    )
    parser.add_argument(
        "--padding-ico",
        type=float,
        default=None,
        help="Padding ratio for ICO source (overrides --padding)",
    )
    parser.add_argument(
        "--background",
        default="#FFFFFF",
        help="Background color as hex (#RRGGBB or #RRGGBBAA), default white",
    )
    parser.add_argument(
        "--rounded",
        type=float,
        default=0.16,
        help="Rounded corner ratio (0.0-0.5). Use 0 for square corners.",
    )
    parser.add_argument(
        "--no-trim",
        action="store_true",
        help="Disable automatic trimming of transparent/white outer margins",
    )
    parser.add_argument(
        "--white-threshold",
        type=int,
        default=245,
        help="Threshold for treating pixels as white when trimming (0-255)",
    )
    args = parser.parse_args()

    src = Path(args.source)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    if not src.exists():
        raise FileNotFoundError(f"Source image not found: {src}")

    bg = parse_color(args.background)

    with Image.open(src) as img:
        base = img.convert("RGBA")
        if not args.no_trim:
            base = trim_outer_margins(base, white_threshold=args.white_threshold)

        pad_512 = args.padding if args.padding_512 is None else args.padding_512
        pad_192 = args.padding if args.padding_192 is None else args.padding_192
        pad_ico = args.padding if args.padding_ico is None else args.padding_ico

        png_512 = padded_square(base, 512, pad_512, bg, args.rounded)
        png_192 = padded_square(base, 192, pad_192, bg, args.rounded)

        path_512 = out_dir / f"{args.name_prefix}_512.png"
        path_192 = out_dir / f"{args.name_prefix}_192.png"
        path_ico = out_dir / f"{args.name_prefix}.ico"

        png_512.save(path_512, format="PNG")
        png_192.save(path_192, format="PNG")

        ico_source = padded_square(base, 512, pad_ico, bg, args.rounded)
        ico_source.save(
            path_ico,
            format="ICO",
            sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)],
        )

    print(f"Generated: {path_512}")
    print(f"Generated: {path_192}")
    print(f"Generated: {path_ico}")


if __name__ == "__main__":
    main()
