from PIL import Image, ImageDraw, ImageFilter

S = 1024
M = 100              # transparent margin per Apple icon grid
R = 185              # squircle corner radius
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# --- background: dark terminal squircle with subtle vertical gradient
grad = Image.new("RGBA", (S, S))
gd = ImageDraw.Draw(grad)
top, bottom = (24, 30, 41), (13, 17, 23)
for y in range(M, S - M):
    t = (y - M) / (S - 2 * M)
    c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    gd.line([(M, y), (S - M, y)], fill=c + (255,))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([M, M, S - M, S - M], radius=R, fill=255)
img.paste(grad, (0, 0), mask)

# soft border highlight
d.rounded_rectangle([M, M, S - M, S - M], radius=R, outline=(255, 255, 255, 28), width=4)

# --- viewfinder corner brackets (white)
bw = 26                      # stroke width
bl = 150                     # arm length
inset = 195
wcol = (235, 240, 245, 255)
for cx, cy, dx, dy in [
    (inset, inset, 1, 1), (S - inset, inset, -1, 1),
    (inset, S - inset, 1, -1), (S - inset, S - inset, -1, -1),
]:
    d.line([(cx, cy), (cx + dx * bl, cy)], fill=wcol, width=bw)
    d.line([(cx, cy), (cx, cy + dy * bl)], fill=wcol, width=bw)

# --- terminal prompt "❯" chevron (green) lower-left area
pcol = (63, 185, 80, 255)
px, py, ps, pw = 290, 425, 85, 32
d.line([(px, py - ps), (px + ps, py)], fill=pcol, width=pw)
d.line([(px + ps, py), (px, py + ps)], fill=pcol, width=pw)
# cursor block
d.rectangle([px + ps + 55, py + ps - 30, px + ps + 55 + 100, py + ps + 2], fill=(235, 240, 245, 230))

# --- Monosnap-red tapered arrow, pointing upper-right
import math
ax0, ay0 = 330, 760   # tail
ax1, ay1 = 730, 430   # head
dx, dy = ax1 - ax0, ay1 - ay0
ln = math.hypot(dx, dy)
ux, uy = dx / ln, dy / ln
nx, ny = -uy, ux
head = 150
hw = 105
neck = hw * 0.34
tail = 18
bx, by = ax1 - ux * head, ay1 - uy * head
poly = [
    (ax0 + nx * tail, ay0 + ny * tail),
    (bx + nx * neck, by + ny * neck),
    (bx + nx * hw, by + ny * hw),
    (ax1, ay1),
    (bx - nx * hw, by - ny * hw),
    (bx - nx * neck, by - ny * neck),
    (ax0 - nx * tail, ay0 - ny * tail),
]
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).polygon([(x + 10, y + 14) for x, y in poly], fill=(0, 0, 0, 110))
img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(12)))
d.polygon(poly, fill=(237, 28, 36, 255))

img.save("/tmp/shellshot-icon-1024.png")
print("ok")
