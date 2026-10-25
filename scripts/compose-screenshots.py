#!/usr/bin/env python3
"""Composes README / App Store screenshots from the raw view renders.

The raw renders come from the snapshot tests (sample data only):
    cd KvotaKit && KVOTA_SNAPSHOT_DIR=/tmp/raw swift test --filter SnapshotTests
then:
    python3 scripts/compose-screenshots.py /tmp/raw docs/screenshots

Everything around the app is generated here: an abstract wallpaper, a minimal menu
bar and a placeholder editor window with no real text, so no desktop items or
personal data can end up in the images. Requires Pillow.
"""
import pathlib
import random
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

W, H = 2880, 1800  # 1440×900 pt at 2x; also a valid Mac App Store screenshot size
MENU_BAR_H = 48

PALETTES = {
    "dark": {
        "top": (22, 25, 38),
        "bottom": (9, 10, 16),
        "blobs": [
            ((217, 119, 87), (0.12, 0.88), 0.55),
            ((97, 135, 250), (0.22, 0.12), 0.50),
            ((34, 168, 135), (0.88, 0.70), 0.45),
            ((128, 92, 214), (0.62, 0.30), 0.40),
        ],
        "bar_tint": (0, 0, 0, 80),
        "editor": {
            "bg": (29, 31, 39), "sidebar": (24, 26, 33), "title": (36, 38, 47),
            "border": (255, 255, 255, 30), "gutter": (90, 96, 116),
            "tokens": [(110, 120, 150), (198, 120, 221), (97, 175, 239), (152, 195, 121), (229, 192, 123)],
            "sidebar_item": (70, 75, 92), "selection": (55, 60, 78),
        },
    },
    "light": {
        "top": (236, 240, 248),
        "bottom": (214, 222, 236),
        "blobs": [
            ((246, 180, 150), (0.10, 0.90), 0.55),
            ((160, 185, 255), (0.25, 0.10), 0.55),
            ((150, 220, 195), (0.90, 0.72), 0.50),
            ((200, 175, 245), (0.62, 0.30), 0.45),
        ],
        "bar_tint": (255, 255, 255, 105),
        "editor": {
            "bg": (252, 252, 253), "sidebar": (242, 243, 247), "title": (236, 238, 242),
            "border": (0, 0, 0, 30), "gutter": (185, 190, 202),
            "tokens": [(120, 128, 150), (166, 38, 164), (64, 120, 242), (80, 161, 79), (193, 132, 1)],
            "sidebar_item": (205, 209, 220), "selection": (228, 232, 242),
        },
    },
}


# ---------------------------------------------------------------- helpers

def load(raw, name):
    path = raw / name
    if not path.exists():
        sys.exit(f"missing render: {path}")
    return Image.open(path).convert("RGBA")


def wallpaper(scheme, size=(W, H)):
    p = PALETTES[scheme]
    sw, sh = size[0] // 8, size[1] // 8
    base = Image.new("RGB", (sw, sh))
    draw = ImageDraw.Draw(base)
    for y in range(sh):
        t = y / max(1, sh - 1)
        c = tuple(int(p["top"][i] + (p["bottom"][i] - p["top"][i]) * t) for i in range(3))
        draw.line([(0, y), (sw, y)], fill=c)
    img = base.convert("RGBA")
    for color, (cx, cy), radius in p["blobs"]:
        layer = Image.new("RGBA", (sw, sh), (0, 0, 0, 0))
        r = radius * sh
        x, y = cx * sw, cy * sh
        ImageDraw.Draw(layer).ellipse([x - r * 1.4, y - r, x + r * 1.4, y + r], fill=color + (150,))
        img = Image.alpha_composite(img, layer.filter(ImageFilter.GaussianBlur(sh * 0.18)))
    return img.resize(size, Image.BICUBIC)


def rounded_mask(size, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=255)
    return mask


def shadow(canvas, img, pos, blur=28, dy=14, opacity=0.38):
    alpha = img.getchannel("A")
    pad = blur * 3
    layer = Image.new("L", (img.width + pad * 2, img.height + pad * 2), 0)
    layer.paste(alpha, (pad, pad))
    layer = layer.filter(ImageFilter.GaussianBlur(blur)).point(lambda v: int(v * opacity))
    black = Image.new("RGBA", layer.size, (0, 0, 0, 255))
    black.putalpha(layer)
    canvas.alpha_composite(black, (pos[0] - pad, pos[1] - pad + dy))


def vibrant(canvas, img, pos, blur=36):
    """Pastes a translucent render over a blurred copy of what's behind it, like macOS materials."""
    x, y = pos
    box = (x, y, x + img.width, y + img.height)
    margin = blur * 2
    big = (max(0, x - margin), max(0, y - margin), min(canvas.width, box[2] + margin), min(canvas.height, box[3] + margin))
    patch = canvas.crop(big).filter(ImageFilter.GaussianBlur(blur))
    patch = patch.crop((x - big[0], y - big[1], x - big[0] + img.width, y - big[1] + img.height))
    mask = img.getchannel("A").point(lambda v: 255 if v > 8 else 0)
    canvas.paste(patch, (x, y), mask)
    canvas.alpha_composite(img, (x, y))


def place(canvas, img, pos, translucent=True):
    shadow(canvas, img, pos)
    if translucent:
        vibrant(canvas, img, pos)
    else:
        canvas.alpha_composite(img, pos)


def editor_window(scheme, size):
    """A generic code editor with abstract bars instead of text."""
    e = PALETTES[scheme]["editor"]
    w, h = size
    img = Image.new("RGBA", size, e["bg"] + (255,))
    d = ImageDraw.Draw(img)
    title_h, sidebar_w = 60, int(w * 0.22)
    d.rectangle([0, 0, w, title_h], fill=e["title"])
    d.rectangle([0, title_h, sidebar_w, h], fill=e["sidebar"])
    for i, c in enumerate([(255, 95, 87), (254, 188, 46), (40, 200, 64)]):
        cx = 30 + i * 40
        d.ellipse([cx - 12, title_h / 2 - 12, cx + 12, title_h / 2 + 12], fill=c)
    # Tab strip and sidebar entries
    d.rounded_rectangle([sidebar_w + 24, 16, sidebar_w + 260, title_h - 14], radius=8, fill=e["bg"])
    rnd = random.Random(7)
    y = title_h + 36
    while y < h - 40:
        indent = 28 + rnd.choice([0, 0, 24, 48])
        width = rnd.randint(int(sidebar_w * 0.30), int(sidebar_w * 0.62))
        if y == title_h + 36 + 44 * 3:
            d.rounded_rectangle([12, y - 12, sidebar_w - 12, y + 24], radius=8, fill=e["selection"])
        d.rounded_rectangle([indent, y, min(sidebar_w - 20, indent + width), y + 12], radius=6, fill=e["sidebar_item"])
        y += 44
    # Code lines
    y = title_h + 40
    line = 1
    indent_level = 0
    while y < h - 40:
        d.rounded_rectangle([sidebar_w + 30, y, sidebar_w + 30 + (18 if line < 10 else 30), y + 12], radius=5, fill=e["gutter"])
        if rnd.random() < 0.12:
            pass  # blank line
        else:
            x = sidebar_w + 100 + indent_level * 44
            for _ in range(rnd.randint(1, 4)):
                seg = rnd.randint(40, 190)
                if x + seg > w - 60:
                    break
                d.rounded_rectangle([x, y, x + seg, y + 12], radius=6, fill=rnd.choice(e["tokens"]) + (220,))
                x += seg + 16
            step = rnd.random()
            if step < 0.25 and indent_level < 4:
                indent_level += 1
            elif step > 0.75 and indent_level > 0:
                indent_level -= 1
        y += 38
        line += 1
    mask = rounded_mask(size, 22)
    out = Image.new("RGBA", size, (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    ImageDraw.Draw(out).rounded_rectangle([0, 0, w - 1, h - 1], radius=22, outline=e["border"], width=2)
    return out


def menu_bar(canvas, scheme, item):
    strip = canvas.crop((0, 0, W, MENU_BAR_H)).filter(ImageFilter.GaussianBlur(30))
    canvas.paste(strip, (0, 0))
    canvas.alpha_composite(Image.new("RGBA", (W, MENU_BAR_H), PALETTES[scheme]["bar_tint"]), (0, 0))
    x = W - item.width - 18
    y = (MENU_BAR_H - item.height) // 2
    canvas.alpha_composite(item, (x, y))
    return x


def save_jpeg(img, path):
    img.convert("RGB").save(path, "JPEG", quality=90, optimize=True, progressive=True)


def trim_to_content(img, pad):
    bbox = img.getchannel("A").getbbox()
    if bbox:
        img = img.crop(bbox)
    out = Image.new("RGBA", (img.width + pad * 2, img.height + pad * 2), (0, 0, 0, 0))
    out.alpha_composite(img, (pad, pad))
    return out


# ---------------------------------------------------------------- scenes

def hero(raw, scheme, widget_style):
    canvas = wallpaper(scheme)
    editor = editor_window(scheme, (1680, 1220))
    ex, ey = 170, 290
    shadow(canvas, editor, (ex, ey), blur=40, dy=24, opacity=0.45)
    canvas.alpha_composite(editor, (ex, ey))

    item = load(raw, f"menubar-{scheme}.png")
    item_x = menu_bar(canvas, scheme, item)

    menu = load(raw, f"menu-{scheme}.png")
    mx = min(item_x + 4, W - menu.width - 20)
    place(canvas, menu, (mx, MENU_BAR_H + 10))

    widget = load(raw, f"widget-{widget_style}-{scheme}.png")
    if widget_style == "detailed":
        wx, wy = ex + editor.width - widget.width // 2 - 40, ey + 150
    else:
        wx, wy = ex + editor.width - widget.width - 60, ey + editor.height - widget.height - 70
    place(canvas, widget, (wx, wy))
    return canvas


def widgets_card(raw, scheme):
    compact = load(raw, f"widget-compact-{scheme}.png")
    detailed = load(raw, f"widget-detailed-{scheme}.png")
    gap, pad = 120, 110
    width = compact.width + detailed.width + gap + pad * 2
    height = max(compact.height, detailed.height) + pad * 2
    canvas = wallpaper(scheme, (width, height))
    place(canvas, compact, (pad, (height - compact.height) // 2))
    place(canvas, detailed, (pad + compact.width + gap, (height - detailed.height) // 2))
    out = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    out.paste(canvas, (0, 0), rounded_mask(canvas.size, 28))
    return out


def window_shot(raw, name):
    window = load(raw, name)
    pad = 90
    canvas = Image.new("RGBA", (window.width + pad * 2, window.height + pad * 2), (0, 0, 0, 0))
    shadow(canvas, window, (pad, pad), blur=36, dy=18, opacity=0.35)
    canvas.alpha_composite(window, (pad, pad))
    return canvas


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    raw, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    for scheme in ("dark", "light"):
        save_jpeg(hero(raw, scheme, "detailed" if scheme == "dark" else "compact"), out / f"hero-{scheme}.jpg")
        widgets_card(raw, scheme).save(out / f"widgets-{scheme}.png", optimize=True)
        window_shot(raw, f"settings-providers-{scheme}.png").save(out / f"settings-{scheme}.png", optimize=True)
        menu = trim_to_content(load(raw, f"menu-{scheme}.png"), 0)
        menu.save(out / f"menu-{scheme}.png", optimize=True)
    print("wrote", sorted(p.name for p in out.iterdir()))


if __name__ == "__main__":
    main()
