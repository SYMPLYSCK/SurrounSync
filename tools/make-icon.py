"""Builds installer/SurrounSync.ico and installer/SurrounSync.png from the badge art.

    python tools/make-icon.py [art.png]           (needs Pillow; without an argument uses installer/icon-art.png)
    python tools/make-icon.py --square art.png    square art (e.g. the graffiti logo): rounded corners, no badge cut
"""
import os
import sys
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.join(HERE, "..", "installer")
ART = os.path.join(INSTALLER, "icon-art.png")
SIZES = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]


def cut_badge(im):
    """The badge sits on black: find its ring on the centre lines, mask a circle just outside it, crop to it."""
    im = im.convert("RGBA")
    w, h = im.size
    cx, cy = w // 2, h // 2

    def first_lit(pixels):
        for i, p in enumerate(pixels):
            if sum(p[:3]) > 150:
                return i
        return 0

    row = [im.getpixel((x, cy)) for x in range(w)]
    col = [im.getpixel((cx, y)) for y in range(h)]
    left, right = first_lit(row), w - 1 - first_lit(row[::-1])
    top, bottom = first_lit(col), h - 1 - first_lit(col[::-1])
    mx, my = (left + right) / 2, (top + bottom) / 2
    r = max(right - left, bottom - top) / 2 + 3
    k = 4
    mask = Image.new("L", (w * k, h * k), 0)
    ImageDraw.Draw(mask).ellipse(((mx - r) * k, (my - r) * k, (mx + r) * k, (my + r) * k), fill=255)
    im.putalpha(mask.resize((w, h), Image.LANCZOS))
    return im.crop((int(mx - r), int(my - r), int(mx + r) + 1, int(my + r) + 1))


def round_square(im, radius=0.12):
    """Square art: centre-crop to a square and round its corners."""
    im = im.convert("RGBA")
    w, h = im.size
    n = min(w, h)
    im = im.crop(((w - n) // 2, (h - n) // 2, (w - n) // 2 + n, (h - n) // 2 + n))
    k = 4
    mask = Image.new("L", (n * k, n * k), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, n * k - 1, n * k - 1), radius=int(n * k * radius), fill=255)
    im.putalpha(mask.resize((n, n), Image.LANCZOS))
    return im


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--square":
        badge = round_square(Image.open(sys.argv[2])).resize((512, 512), Image.LANCZOS)
        badge.save(ART)
        print("wrote", os.path.normpath(ART))
    elif len(sys.argv) > 1:
        badge = cut_badge(Image.open(sys.argv[1])).resize((512, 512), Image.LANCZOS)
        badge.save(ART)
        print("wrote", os.path.normpath(ART))
    else:
        badge = Image.open(ART).convert("RGBA")
    out = os.path.join(INSTALLER, "SurrounSync.ico")
    small = badge.resize((256, 256), Image.LANCZOS)
    small.save(out, sizes=SIZES)
    print("wrote", os.path.normpath(out))
    logo = os.path.join(INSTALLER, "SurrounSync.png")
    small.save(logo)
    print("wrote", os.path.normpath(logo))


if __name__ == "__main__":
    main()
