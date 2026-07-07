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

from PIL import Image


def padded_square(img: Image.Image, size: int, padding_ratio: float = 0.1) -> Image.Image:
    """Center the logo on a transparent square so it does not touch edges."""
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    inner = int(size * (1.0 - padding_ratio * 2.0))
    icon = img.copy()
    icon.thumbnail((inner, inner), Image.Resampling.LANCZOS)
    x = (size - icon.width) // 2
    y = (size - icon.height) // 2
    canvas.alpha_composite(icon, (x, y))
    return canvas


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
        default=0.1,
        help="Transparent border ratio on each side (default: 0.1)",
    )
    args = parser.parse_args()

    src = Path(args.source)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    if not src.exists():
        raise FileNotFoundError(f"Source image not found: {src}")

    with Image.open(src) as img:
        base = img.convert("RGBA")
        png_512 = padded_square(base, 512, args.padding)
        png_192 = padded_square(base, 192, args.padding)

        path_512 = out_dir / f"{args.name_prefix}_512.png"
        path_192 = out_dir / f"{args.name_prefix}_192.png"
        path_ico = out_dir / f"{args.name_prefix}.ico"

        png_512.save(path_512, format="PNG")
        png_192.save(path_192, format="PNG")

        ico_source = padded_square(base, 512, args.padding)
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
