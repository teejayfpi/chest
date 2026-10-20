#!/usr/bin/env python3
"""Generates the Chest brand assets.

Produces the Android launcher icons (legacy, adaptive, and monochrome) plus the
in-app logo, wordmark and splash mark, so every asset derives from one source of
truth instead of drifting apart.

The mark is a hexagonal strongbox seen head-on: a beveled lid over a body with a
keyhole, on a dark obsidian field. A hex reads as "sealed container" without
borrowing the padlock cliche, and the bevel plus keyhole stay legible down to
48 px.

Run from the repository root:  python3 tool/generate_brand_assets.py
"""

from __future__ import annotations

import math
import pathlib

from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent

# --------------------------------------------------------------------------
# Brand palette
# --------------------------------------------------------------------------
OBSIDIAN = (7, 10, 18, 255)
OBSIDIAN_LIGHT = (18, 25, 42, 255)
SLATE = (54, 70, 104, 255)
GOLD = (240, 185, 78, 255)
GOLD_DEEP = (198, 140, 40, 255)
GOLD_PALE = (255, 224, 160, 255)
CYAN = (94, 214, 214, 255)
WHITE = (255, 255, 255, 255)

FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT_REGULAR = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

# Supersample factor: everything is drawn large and reduced with LANCZOS, which
# is what keeps the hex edges and the keyhole clean at launcher sizes.
SS = 4


def hexagon(cx: float, cy: float, r: float) -> list[tuple[float, float]]:
    """Pointy-top hexagon centred on (cx, cy) with circumradius r."""
    return [
        (cx + r * math.cos(math.radians(90 + 60 * i)),
         cy + r * math.sin(math.radians(90 + 60 * i)))
        for i in range(6)
    ]


def vertical_gradient(size: int, top: tuple, bottom: tuple) -> Image.Image:
    """Linear vertical gradient image."""
    grad = Image.new("RGBA", (1, size))
    for y in range(size):
        t = y / max(1, size - 1)
        grad.putpixel(
            (0, y),
            tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(4)),
        )
    return grad.resize((size, size), Image.BILINEAR)


def radial_glow(size: int, color: tuple, strength: float) -> Image.Image:
    """Soft centre glow, used to lift the mark off the background."""
    s = size * SS
    glow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(glow)
    steps = 64
    for i in range(steps, 0, -1):
        t = i / steps
        r = (s / 2) * t
        a = int(strength * 255 * (1 - t) ** 2)
        d.ellipse(
            [s / 2 - r, s / 2 - r, s / 2 + r, s / 2 + r],
            fill=(color[0], color[1], color[2], a),
        )
    return glow.resize((size, size), Image.LANCZOS)


def draw_strongbox(draw: ImageDraw.ImageDraw, size: int, *, mono: bool = False) -> None:
    """Draws the hex strongbox mark onto an SS-scaled canvas of `size` px."""
    s = size * SS
    cx = cy = s / 2

    body = SLATE if not mono else WHITE
    lid = (68, 86, 124, 255) if not mono else WHITE
    accent = GOLD if not mono else WHITE
    accent_pale = GOLD_PALE if not mono else WHITE

    outer_r = s * 0.46
    bevel = s * 0.030

    # Outer shell, then an inset inner face to create the bevel. The gold rim is
    # what keeps the silhouette readable at launcher sizes.
    draw.polygon(hexagon(cx, cy, outer_r), fill=body)
    rim = hexagon(cx, cy, outer_r)
    draw.line(rim + [rim[0]], fill=accent, width=max(2, int(s * 0.024)),
              joint="curve")
    draw.polygon(hexagon(cx, cy, outer_r - bevel), fill=lid)

    # Lid seam across the upper third of the box.
    seam_y = cy - outer_r * 0.18
    draw.line(
        [(cx - outer_r * 0.86, seam_y), (cx + outer_r * 0.86, seam_y)],
        fill=accent,
        width=max(2, int(s * 0.022)),
    )

    # Hinges straddling the seam.
    hinge_w = s * 0.030
    hinge_h = s * 0.055
    for sign in (-1, 1):
        hx = cx + sign * outer_r * 0.60
        draw.rounded_rectangle(
            [hx - hinge_w / 2, seam_y - hinge_h * 0.72,
             hx + hinge_w / 2, seam_y + hinge_h * 0.28],
            radius=hinge_w * 0.35,
            fill=accent_pale,
        )

    # Keyhole: circle plus tapered stem.
    kh_cy = cy + outer_r * 0.16
    kh_r = s * 0.072
    draw.ellipse([cx - kh_r, kh_cy - kh_r, cx + kh_r, kh_cy + kh_r], fill=accent)
    stem_top = kh_cy + kh_r * 0.35
    stem_bottom = kh_cy + outer_r * 0.34
    stem_w_top = kh_r * 0.80
    stem_w_bottom = kh_r * 0.52
    draw.polygon(
        [
            (cx - stem_w_top / 2, stem_top),
            (cx + stem_w_top / 2, stem_top),
            (cx + stem_w_bottom / 2, stem_bottom),
            (cx - stem_w_bottom / 2, stem_bottom),
        ],
        fill=accent,
    )

    # Ring around the keyhole: the "sealed" cue.
    ring_r = outer_r * 0.30
    draw.ellipse(
        [cx - ring_r, kh_cy - ring_r, cx + ring_r, kh_cy + ring_r],
        outline=accent,
        width=max(2, int(s * 0.016)),
    )


def build_icon(size: int, *, padding_frac: float = 0.0,
               background: bool = True) -> Image.Image:
    """Builds the square launcher icon at `size` px."""
    s = size * SS
    canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    if background:
        canvas.alpha_composite(vertical_gradient(s, OBSIDIAN_LIGHT, OBSIDIAN))
        canvas.alpha_composite(radial_glow(s, GOLD_DEEP, 0.16))

    pad = int(s * padding_frac)
    inner = s - pad * 2
    layer = Image.new("RGBA", (inner, inner), (0, 0, 0, 0))
    draw_strongbox(ImageDraw.Draw(layer), inner // SS)
    canvas.alpha_composite(layer, (pad, pad))

    return canvas.resize((size, size), Image.LANCZOS)


def build_adaptive_layer(size: int, *, mono: bool) -> Image.Image:
    """Adaptive-icon foreground or monochrome layer.

    Android crops adaptive icons to the inner 66% of the canvas and may animate
    them, so the mark is drawn inside that safe zone with transparent margins
    rather than filling the square.
    """
    s = size * SS
    canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    mark_px = int(s * 0.60)
    mark = Image.new("RGBA", (mark_px, mark_px), (0, 0, 0, 0))
    draw_strongbox(ImageDraw.Draw(mark), mark_px // SS, mono=mono)
    canvas.alpha_composite(mark, ((s - mark_px) // 2, (s - mark_px) // 2))
    return canvas.resize((size, size), Image.LANCZOS)


def build_adaptive_background(size: int) -> Image.Image:
    """Adaptive-icon background layer."""
    s = size * SS
    canvas = vertical_gradient(s, OBSIDIAN_LIGHT, OBSIDIAN)
    canvas.alpha_composite(radial_glow(s, GOLD_DEEP, 0.20))
    return canvas.resize((size, size), Image.LANCZOS)


def build_logo(width: int = 1024) -> Image.Image:
    """Horizontal lockup: mark, CHEST wordmark, rule and letterspaced tagline."""
    height = width // 3
    canvas = Image.new("RGBA", (width, height), (0, 0, 0, 0))

    mark_size = int(height * 0.86)
    canvas.alpha_composite(build_icon(mark_size, padding_frac=0.02),
                           (int(height * 0.06), (height - mark_size) // 2))

    text_x = int(height * 0.06) + mark_size + int(height * 0.22)
    draw = ImageDraw.Draw(canvas)
    draw.text((text_x, int(height * 0.20)), "CHEST",
              font=ImageFont.truetype(FONT_BOLD, int(height * 0.46)), fill=GOLD_PALE)

    rule_y = int(height * 0.60)
    draw.line([(text_x, rule_y), (text_x + int(height * 0.42), rule_y)],
              fill=GOLD_DEEP, width=max(1, int(height * 0.014)))

    draw.text((text_x + int(height * 0.02), int(height * 0.64)),
              "S E A L E D   B Y   D E S I G N",
              font=ImageFont.truetype(FONT_REGULAR, int(height * 0.115)),
              fill=CYAN)
    return canvas


def build_splash(size: int = 768) -> Image.Image:
    """Splash mark: the icon centred on a dark field."""
    canvas = Image.new("RGBA", (size, size), OBSIDIAN)
    inner = int(size * 0.52)
    canvas.alpha_composite(build_icon(inner), ((size - inner) // 2, (size - inner) // 2))
    return canvas


def save(image: Image.Image, path: pathlib.Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)
    print(f"  wrote {path.relative_to(ROOT)}  ({image.width}x{image.height})")


def main() -> None:
    print("Generating Chest brand assets")
    res = ROOT / "android" / "app" / "src" / "main" / "res"

    # Legacy launcher icons, following the Android density buckets: the 48 dp
    # baseline scales to 48/72/96/144/192 px.
    for bucket, px in {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }.items():
        save(build_icon(px), res / bucket / "ic_launcher.png")
        save(build_icon(px), res / bucket / "ic_launcher_round.png")

    # Adaptive icon layers, at the 108 dp baseline.
    for bucket, px in {
        "mipmap-mdpi": 108,
        "mipmap-hdpi": 162,
        "mipmap-xhdpi": 216,
        "mipmap-xxhdpi": 324,
        "mipmap-xxxhdpi": 432,
    }.items():
        save(build_adaptive_layer(px, mono=False),
             res / bucket / "ic_launcher_foreground.png")
        save(build_adaptive_layer(px, mono=True),
             res / bucket / "ic_launcher_monochrome.png")
        if bucket == "mipmap-xxxhdpi":
            save(build_adaptive_background(px),
                 res / bucket / "ic_launcher_background.png")

    save(build_icon(512), ROOT / "store" / "play_store_icon_512.png")


    branding = ROOT / "assets" / "branding"
    save(build_logo(1024), branding / "chest_logo.png")
    save(build_icon(512), branding / "chest_mark.png")
    save(build_splash(768), branding / "chest_splash.png")
    print("Done")


if __name__ == "__main__":
    main()
