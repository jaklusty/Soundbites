#!/usr/bin/env python3
"""Make every platform icon from one 1024x1024 PNG (transparent outside the rounded square).

    python3 scripts/make-icons.py design/logo/soundbites-icon-1024.png

Writes macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{16..1024}.png,
windows/runner/resources/app_icon.ico and assets/icon/icon.png (shown inside the app).
Needs Pillow (python3 -m pip install --user pillow).
"""
import sys
from pathlib import Path
from PIL import Image

src = Path(sys.argv[1])
root = Path(__file__).resolve().parent.parent
im = Image.open(src).convert('RGBA')
if im.size != (1024, 1024):
    sys.exit(f'{src} is {im.size}, expected 1024x1024')

mac = root / 'macos/Runner/Assets.xcassets/AppIcon.appiconset'
for size in (16, 32, 64, 128, 256, 512, 1024):
    im.resize((size, size), Image.LANCZOS).save(mac / f'app_icon_{size}.png')

# Windows: the icon fills the square (no transparent margin), so crop the macOS grid's 824 box.
win = im.crop((100, 100, 924, 924))
win.save(root / 'windows/runner/resources/app_icon.ico', sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)])

im.save(root / 'assets/icon/icon.png')
print('icons written from', src)
