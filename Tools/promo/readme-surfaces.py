#!/usr/bin/env python3
"""Export README examples from the current isolated production-view renders."""
from pathlib import Path
import shutil
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'docs/promo'
OUT.mkdir(parents=True, exist_ok=True)
shutil.copy2(ROOT / '.build/popup-preview/popup-light.png', OUT / 'popup.png')

canvas = Image.new('RGB', (1760, 900), '#eef3f8')
draw = ImageDraw.Draw(canvas)
font = ImageFont.truetype('/System/Library/Fonts/STHeiti Medium.ttc', 30)
small = ImageFont.truetype('/System/Library/Fonts/STHeiti Medium.ttc', 23)
for x, width, source, title, note in [
    (48, 920, 'expanded-light.png', '刘海屏 · 展开详情', '会话、上下文与今日用量'),
    (1032, 680, 'external-expanded-light.png', '外接屏 · Focus deck', '独立面板，悬停展开'),
]:
    draw.text((x, 48), title, fill='#18252e', font=font)
    draw.text((x, 100), note, fill='#52616d', font=small)
    surface = Image.open(ROOT / '.build/island-preview' / source).convert('RGB')
    surface.thumbnail((width, 670), Image.Resampling.LANCZOS)
    canvas.paste(surface, (x + (width - surface.width) // 2, 180 + (670 - surface.height) // 2))
canvas.save(OUT / 'island.png')
print('Exported README popup and multi-display island examples')
