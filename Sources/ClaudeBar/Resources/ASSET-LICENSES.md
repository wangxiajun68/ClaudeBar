# Internal hardware illustration

`macbook-internals-illustration.png` is an independently generated conceptual hardware illustration, created with the built-in imagegen tool on 2026-09-26. It is a 1536 × 1024 PNG with alpha, in a simplified vector-like visual style, not an SVG or an exact model-specific technical drawing. No Basic Apple Guy artwork is included or redistributed.

The app decodes the image once and uses circular crops at (300, 315) and (1237, 315), radius 108, for the animated turbines. Only the detail panel uses the illustration and turbine crops. The overview card uses the native vector `fanblades.fill` SF Symbol and direct fan-control buttons.

Final refinement prompt (built-in imagegen): Simplify the exact laptop-internals illustration into a calm premium large technical app icon. Preserve the chassis footprint, fan centers and transparent background. Keep the slim silver enclosure, two centrifugal fans, broad cooling pipe, central processor, six battery cells and side speakers. Remove most tiny chips, solder dots, screws, gold accents, connectors and traces. Use flat cool graphite shapes, a few widely spaced circuit lines and 4–5 neutral gray tones. No text, labels or photographic texture.

# Greeting typefaces

The dashboard greeting can be written in any of the faces below (设置 → 问候字体; Borel is the default). Each font file is taken unmodified from the Google Fonts repository (https://github.com/google/fonts) and ships in `Fonts/` with its full licence beside it; copyright notices and reserved font names are in those files. The app draws the greeting from the glyph outlines, filled and, for monoline faces, evenly stroked for weight. The fonts are not installed system-wide and are not sold on their own.

| Face | File | Licence | Licence file |
| --- | --- | --- | --- |
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
