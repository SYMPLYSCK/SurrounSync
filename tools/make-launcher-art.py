"""Builds the SurrounDead Mod Launcher's pictures for SurrounSync from the badge art (needs Pillow):

    python tools/make-launcher-art.py

launcher/icon.png    128x128, the setup's icon (installer/SurrounSync.png)
launcher/banner.png  1280x400, the badge art in the middle on a blurred, darkened copy of itself

version.json links them by their raw GitHub address (tools/make-modzip.py), so they're read from master: commit them
before the release. The launcher takes PNG or JPG up to 2 MB and darkens the banner's bottom ~15% for the mod's name.
"""
import os
import sys

from PIL import Image, ImageEnhance, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
OUT = os.path.join(REPO, "launcher")
MAX_BYTES = 2 * 1024 * 1024


def save(im, name):
    path = os.path.join(OUT, name)
    im.save(path, optimize=True)
    size = os.path.getsize(path)
    if size > MAX_BYTES:
        sys.exit("%s is %d bytes, over the launcher's 2 MB" % (path, size))
    print("%s %dx%d %d KB" % (path, im.width, im.height, size // 1024))


def main():
    os.makedirs(OUT, exist_ok=True)
    icon = Image.open(os.path.join(REPO, "installer", "SurrounSync.png")).convert("RGBA")
    save(icon.resize((128, 128), Image.LANCZOS), "icon.png")

    art = Image.open(os.path.join(REPO, "installer", "icon-art.png")).convert("RGB")
    w, h = 1280, 400
    back = art.resize((w, w), Image.LANCZOS).crop((0, (w - h) // 2, w, (w + h) // 2))
    back = ImageEnhance.Brightness(back.filter(ImageFilter.GaussianBlur(18))).enhance(0.45)
    front = art.resize((h, h), Image.LANCZOS)
    back.paste(front, ((w - h) // 2, 0))
    save(back, "banner.png")


if __name__ == "__main__":
    main()
