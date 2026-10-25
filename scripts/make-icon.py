#!/usr/bin/env python3
"""Draws Kvota's app icon (a three-part quota gauge on a dark squircle) and writes the
macOS AppIcon set. Requires Pillow: pip install pillow"""
import json
import math
import pathlib

from PIL import Image, ImageDraw, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "App/Resources/Assets.xcassets/AppIcon.appiconset"
SCALE = 4  # draw big, downsample for smooth edges
S = 1024 * SCALE


def squircle_mask(size, inset, radius):
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([inset, inset, size - inset, size - inset], radius=radius, fill=255)
    return mask


def vertical_gradient(size, top, bottom):
    img = Image.new("RGB", (size, size), top)
    px = img.load()
    for y in range(size):
        t = y / (size - 1)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(size):
            px[x, y] = c
    return img


def arc(draw, center, radius, width, start, end, color):
    cx, cy = center
    box = [cx - radius, cy - radius, cx + radius, cy + radius]
    draw.arc(box, start=start, end=end, fill=color, width=width)
    # round caps
    for angle in (start, end):
        a = math.radians(angle)
        r_mid = radius - width / 2
        x = cx + r_mid * math.cos(a)
        y = cy + r_mid * math.sin(a)
        draw.ellipse([x - width / 2, y - width / 2, x + width / 2, y + width / 2], fill=color)


def main():
    inset = 100 * SCALE
    body = S - 2 * inset
    radius = int(body * 0.225)

    # Background: ink gradient inside the macOS squircle, with a soft drop shadow.
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow = squircle_mask(S, inset, radius).filter(ImageFilter.GaussianBlur(14 * SCALE))
    shadow_layer = Image.new("RGBA", (S, S), (0, 0, 0, 110))
    canvas.paste(shadow_layer, (0, 10 * SCALE), shadow)

    small = 256
    grad = vertical_gradient(small, (40, 44, 58), (18, 20, 27)).resize((S, S), Image.BICUBIC)
    canvas.paste(grad, (0, 0), squircle_mask(S, inset, radius))

    # Subtle top highlight.
    hl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(hl).rounded_rectangle(
        [inset, inset, S - inset, S - inset], radius=radius, outline=(255, 255, 255, 28), width=3 * SCALE
    )
    canvas = Image.alpha_composite(canvas, hl)

    # A gauge in three segments (Claude, Codex, Gemini) with a needle.
    draw = ImageDraw.Draw(canvas)
    center = (S / 2, S / 2 + 70 * SCALE)
    width = int(84 * SCALE)
    radius = int(318 * SCALE)
    # Visible extents 150-222, 234-306, 318-390 degrees; the round caps add the rest.
    cap = math.degrees((width / 2) / (radius - width / 2))
    segments = [
        ((217, 119, 87), 150, 222),
        ((34, 168, 135), 234, 306),
        ((97, 135, 250), 318, 390),
    ]
    for color, a, b in segments:
        arc(draw, center, radius, width, a + cap, b - cap, color + (255,))

    # Needle pointing into the middle segment, with a hub.
    angle = math.radians(286)
    cx, cy = center
    tip = (cx + (radius - width - 34 * SCALE) * math.cos(angle), cy + (radius - width - 34 * SCALE) * math.sin(angle))
    base_half = 26 * SCALE
    perp = angle + math.pi / 2
    base_l = (cx + base_half * math.cos(perp), cy + base_half * math.sin(perp))
    base_r = (cx - base_half * math.cos(perp), cy - base_half * math.sin(perp))
    draw.polygon([tip, base_l, base_r], fill=(240, 242, 247, 255))
    hub = 62 * SCALE
    draw.ellipse([cx - hub, cy - hub, cx + hub, cy + hub], fill=(240, 242, 247, 255))
    inner = 26 * SCALE
    draw.ellipse([cx - inner, cy - inner, cx + inner, cy + inner], fill=(30, 33, 44, 255))

    final = canvas.resize((1024, 1024), Image.LANCZOS)

    OUT.mkdir(parents=True, exist_ok=True)
    images = []
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = size * scale
            name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            final.resize((px, px), Image.LANCZOS).save(OUT / name)
            images.append({"idiom": "mac", "size": f"{size}x{size}", "scale": f"{scale}x", "filename": name})
    (OUT / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    final.save(ROOT / "docs/icon.png")
    print("wrote", OUT)


if __name__ == "__main__":
    main()
