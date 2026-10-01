# Internal hardware illustration

`macbook-internals-illustration.png` is an independently generated conceptual hardware illustration, created with the built-in imagegen tool on 2026-09-26. It is a 1536 × 1024 PNG with alpha, in a simplified vector-like visual style, not an SVG or an exact model-specific technical drawing. No Basic Apple Guy artwork is included or redistributed.

The app decodes the image once and uses circular crops at (300, 315) and (1237, 315), radius 108, for the animated turbines. Only the detail panel uses the illustration and turbine crops. The overview card uses the native vector `fanblades.fill` SF Symbol and direct fan-control buttons.

Final refinement prompt (built-in imagegen): Simplify the exact laptop-internals illustration into a calm premium large technical app icon. Preserve the chassis footprint, fan centers and transparent background. Keep the slim silver enclosure, two centrifugal fans, broad cooling pipe, central processor, six battery cells and side speakers. Remove most tiny chips, solder dots, screws, gold accents, connectors and traces. Use flat cool graphite shapes, a few widely spaced circuit lines and 4–5 neutral gray tones. No text, labels or photographic texture.

# Greeting typefaces

The dashboard greeting can be written in any of the faces below (设置 → 天气与问候 → 问候字体; 寒蝉圆黑 · 粗体 is the Chinese default, Borel the English fallback). The Google Fonts Latin scripts and Chinese calligraphy faces are taken unmodified from the Google Fonts repository (https://github.com/google/fonts). ChillRound, ChillRoundGothic, Smiley Sans, LXGW ZhenKai, Yozai and LXGW Marker Gothic come from their authors' repositories (see `Fonts/SOURCES.md`). Every bundled font is unmodified and ships in `Fonts/` with its full licence beside it; copyright notices and reserved font names are in those files. The app draws the greeting from the glyph outlines, filled and, for monoline faces, evenly stroked for weight. The fonts are not installed system-wide and are not sold on their own.

| Face | File | Licence | Licence file |
| --- | --- | --- | --- |
| 寒蝉圆黑 · 粗体 | `Fonts/ChillRoundGothic-Bold.otf` | OFL 1.1 | `Fonts/chillroundgothic-OFL.txt` |
| 寒蝉圆黑 · 特粗 | `Fonts/ChillRoundGothic-Heavy.otf` | OFL 1.1 | `Fonts/chillroundgothic-OFL.txt` |
| 站酷快乐体 | `Fonts/ZCOOLKuaiLe-Regular.ttf` | OFL 1.1 | `Fonts/zcoolkuaile-OFL.txt` |
| 站酷庆科黄油体 | `Fonts/ZCOOLQingKeHuangYou-Regular.ttf` | OFL 1.1 | `Fonts/zcoolqingkehuangyou-OFL.txt` |
| 站酷小薇体 | `Fonts/ZCOOLXiaoWei-Regular.ttf` | OFL 1.1 | `Fonts/zcoolxiaowei-OFL.txt` |
| 马善政毛笔体 | `Fonts/MaShanZheng-Regular.ttf` | OFL 1.1 | `Fonts/mashanzheng-OFL.txt` |
| 得意黑 | `Fonts/SmileySans-Oblique.otf` | OFL 1.1 | `Fonts/smiley-sans-OFL.txt` |
| 志莽行书 | `Fonts/ZhiMangXing-Regular.ttf` | OFL 1.1 | `Fonts/zhimangxing-OFL.txt` |
| 龙藏体 | `Fonts/LongCang-Regular.ttf` | OFL 1.1 | `Fonts/longcang-OFL.txt` |
| 刘建毛草 | `Fonts/LiuJianMaoCao-Regular.ttf` | OFL 1.1 | `Fonts/liujianmaocao-OFL.txt` |
| Fredoka | `Fonts/Fredoka[wdth,wght].ttf` | OFL 1.1 | `Fonts/fredoka-OFL.txt` |
| Baloo 2 | `Fonts/Baloo2[wght].ttf` | OFL 1.1 | `Fonts/baloo2-OFL.txt` |
| Chewy | `Fonts/Chewy-Regular.ttf` | Apache 2.0 | `Fonts/chewy-LICENSE.txt` |
| Shrikhand | `Fonts/Shrikhand-Regular.ttf` | OFL 1.1 | `Fonts/shrikhand-OFL.txt` |
| Bungee | `Fonts/Bungee-Regular.ttf` | OFL 1.1 | `Fonts/bungee-OFL.txt` |
| Bungee Shade | `Fonts/BungeeShade-Regular.ttf` | OFL 1.1 | `Fonts/bungeeshade-OFL.txt` |
| Luckiest Guy | `Fonts/LuckiestGuy-Regular.ttf` | Apache 2.0 | `Fonts/luckiestguy-LICENSE.txt` |
| Lilita One | `Fonts/LilitaOne-Regular.ttf` | OFL 1.1 | `Fonts/lilitaone-OFL.txt` |
| Berkshire Swash | `Fonts/BerkshireSwash-Regular.ttf` | OFL 1.1 | `Fonts/berkshireswash-OFL.txt` |
| Oleo Script Bold | `Fonts/OleoScript-Bold.ttf` | OFL 1.1 | `Fonts/oleoscript-OFL.txt` |
| Righteous | `Fonts/Righteous-Regular.ttf` | OFL 1.1 | `Fonts/righteous-OFL.txt` |
| Rampart One | `Fonts/RampartOne-Regular.ttf` | OFL 1.1 | `Fonts/rampartone-OFL.txt` |
| Monoton | `Fonts/Monoton-Regular.ttf` | OFL 1.1 | `Fonts/monoton-OFL.txt` |
| Rubik Bubbles | `Fonts/RubikBubbles-Regular.ttf` | OFL 1.1 | `Fonts/rubikbubbles-OFL.txt` |
| Caveat Bold | `Fonts/Caveat[wght].ttf` | OFL 1.1 | `Fonts/caveat-OFL.txt` |
| 寒蝉全圆体 | `Fonts/ChillRoundF.ttf` | OFL 1.1 | `Fonts/chillround-OFL.txt` |
| 霞鹜臻楷 | `Fonts/LXGWZhenKaiGB-Regular.ttf` | OFL 1.1 | `Fonts/lxgwzhenkai-OFL.txt` |
| 悠哉字体 | `Fonts/Yozai-Medium.ttf` | OFL 1.1 | `Fonts/yozai-OFL.txt` |
| 霞鹜漫黑 | `Fonts/LXGWMarkerGothic-Regular.ttf` | OFL 1.1 | `Fonts/lxgwmarkergothic-OFL.txt` |
| Borel | `Fonts/Borel-Regular.ttf` | OFL 1.1 | `Fonts/borel-OFL.txt` |
| Pacifico | `Fonts/Pacifico-Regular.ttf` | OFL 1.1 | `Fonts/pacifico-OFL.txt` |
| Playwrite US Modern | `Fonts/PlaywriteUSModern[wght].ttf` | OFL 1.1 | `Fonts/playwriteusmodern-OFL.txt` |
| Playwrite US Trad | `Fonts/PlaywriteUSTrad[wght].ttf` | OFL 1.1 | `Fonts/playwriteustrad-OFL.txt` |
| Playwrite GB S | `Fonts/PlaywriteGBS[wght].ttf` | OFL 1.1 | `Fonts/playwritegbs-OFL.txt` |
| Playwrite NZ | `Fonts/PlaywriteNZ[wght].ttf` | OFL 1.1 | `Fonts/playwritenz-OFL.txt` |
| Dancing Script | `Fonts/DancingScript[wght].ttf` | OFL 1.1 | `Fonts/dancingscript-OFL.txt` |
| Yellowtail | `Fonts/Yellowtail-Regular.ttf` | Apache 2.0 | `Fonts/yellowtail-LICENSE.txt` |
| Satisfy | `Fonts/Satisfy-Regular.ttf` | Apache 2.0 | `Fonts/satisfy-LICENSE.txt` |
| Cookie | `Fonts/Cookie-Regular.ttf` | OFL 1.1 | `Fonts/cookie-OFL.txt` |
| Damion | `Fonts/Damion-Regular.ttf` | OFL 1.1 | `Fonts/damion-OFL.txt` |
| Grand Hotel | `Fonts/GrandHotel-Regular.ttf` | OFL 1.1 | `Fonts/grandhotel-OFL.txt` |
| Lobster | `Fonts/Lobster-Regular.ttf` | OFL 1.1 | `Fonts/lobster-OFL.txt` |
| Great Vibes | `Fonts/GreatVibes-Regular.ttf` | OFL 1.1 | `Fonts/greatvibes-OFL.txt` |
| Sacramento | `Fonts/Sacramento-Regular.ttf` | OFL 1.1 | `Fonts/sacramento-OFL.txt` |
| Parisienne | `Fonts/Parisienne-Regular.ttf` | OFL 1.1 | `Fonts/parisienne-OFL.txt` |
| Playball | `Fonts/Playball-Regular.ttf` | OFL 1.1 | `Fonts/playball-OFL.txt` |
| Kaushan Script | `Fonts/KaushanScript-Regular.ttf` | OFL 1.1 | `Fonts/kaushanscript-OFL.txt` |
| Oooh Baby | `Fonts/OoohBaby-Regular.ttf` | OFL 1.1 | `Fonts/ooohbaby-OFL.txt` |
| Grape Nuts | `Fonts/GrapeNuts-Regular.ttf` | OFL 1.1 | `Fonts/grapenuts-OFL.txt` |

SignPainter, Snell Roundhand, Savoye LET and Zapfino are the Mac's own fonts. They are looked up by name at run time and are not bundled or redistributed.

# Scientific color map

The usage calendar samples the viridis color map by Nathaniel J. Smith, Stefan van der Walt and Eric Firing. Its color data is released under CC0 / public-domain dedication. Palette source: https://github.com/BIDS/colormap/blob/master/colormaps.py. CC0: https://creativecommons.org/publicdomain/zero/1.0/. The app uses 64 uniformly sampled colors; no Matplotlib runtime is bundled.
