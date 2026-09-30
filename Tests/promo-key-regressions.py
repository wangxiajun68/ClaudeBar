#!/usr/bin/env python3
"""Regression: island plate removal must preserve enclosed white lettering."""
from pathlib import Path
from importlib.util import spec_from_file_location, module_from_spec
from PIL import Image, ImageDraw

spec = spec_from_file_location('promo_key', Path(__file__).resolve().parents[1] / 'Tools/promo/key-island.py')
key_module = module_from_spec(spec)
spec.loader.exec_module(key_module)

for theme, plate in [('light', 242), ('dark', 22)]:
    image = Image.new('RGBA', (64, 64), (plate, plate, plate, 255))
    draw = ImageDraw.Draw(image)
    draw.rectangle((8, 8, 55, 55), fill=(0, 0, 0, 255))
    draw.rectangle((24, 24, 39, 39), fill=(245, 245, 245, 255))
    result = key_module.key(image, theme)
    assert result.getpixel((0, 0))[3] == 0, f'{theme}: outer plate remains'
    assert result.getpixel((16, 16))[3] == 255, f'{theme}: black body was deleted'
    assert result.getpixel((30, 30)) == (245, 245, 245, 255), f'{theme}: enclosed lettering was deleted'
print('Island key regression passed in light and dark themes')
