# Screech app icon: a phosphor-green "screech" trace (a chirp sweeping into FSK steps) on a dark CRT glass.
from PIL import Image, ImageDraw, ImageFilter
import math, sys
S = 1024
img = Image.new('RGB', (S, S), (3, 10, 5))
d = ImageDraw.Draw(img)
# CRT vignette
for r in range(0, 700, 4):
    c = int(18 * (1 - r / 700))
    d.ellipse([S/2 - 700 + r, S/2 - 700 + r, S/2 + 700 - r, S/2 + 700 - r], outline=(c // 2, c + 4, c // 2 + 2))
# grid
for i in range(1, 8):
    x = i * S // 8
    d.line([(x, 120), (x, S - 120)], fill=(10, 38, 18), width=3)
    d.line([(120, x), (S - 120, x)], fill=(10, 38, 18), width=3)
# trace: answer tone → chirp → hopping FSK square steps
pts = []; ph = 0.0
for i in range(0, 900):
    x = 62 + i
    t = i / 900
    if t < 0.55:
        f = 7 + 30 * max(0, t - 0.22)            # cycles per unit width: steady tone, then a rising chirp
        ph += f / 900
        y = 512 + (150 + 140 * max(0, t - 0.22) / 0.33) * math.sin(2 * math.pi * ph)
    else:
        step = int((t - 0.55) * 40)
        y = 512 + (-1) ** step * (120 + 90 * ((step * 7) % 3))
    pts.append((x, y))
glow = Image.new('RGB', (S, S), (0, 0, 0)); g = ImageDraw.Draw(glow)
g.line(pts, fill=(60, 255, 110), width=40, joint='curve')
glow = glow.filter(ImageFilter.GaussianBlur(28))
img = Image.blend(img, Image.composite(glow, img, glow.convert('L')), 0.9)
d = ImageDraw.Draw(img)
d.line(pts, fill=(140, 255, 170), width=16, joint='curve')
d.line(pts, fill=(230, 255, 235), width=5, joint='curve')
# scanlines
for y in range(0, S, 6): d.line([(0, y), (S, y)], fill=(0, 0, 0), width=1)
img.save(sys.argv[1])
