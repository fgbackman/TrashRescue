import math
from PIL import Image, ImageDraw, ImageFilter

S = 2048  # supersampled canvas for the 1024 app icon
k = S / 1024

def P(v):  # 1024-space -> canvas
    return v * k

# ---------- App (Dock) icon ----------
icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# soft drop shadow
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle([P(100), P(112), P(924), P(936)], radius=P(185), fill=(0, 0, 0, 110))
shadow = shadow.filter(ImageFilter.GaussianBlur(P(18)))
icon.alpha_composite(shadow)

# gradient squircle body
top, bot = (44, 190, 170), (22, 78, 150)
grad = Image.new("RGBA", (S, S))
gd = ImageDraw.Draw(grad)
for y in range(S):
    t = y / (S - 1)
    gd.line([(0, y), (S, y)], fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)) + (255,))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([P(100), P(100), P(924), P(924)], radius=P(185), fill=255)
icon.paste(grad, (0, 0), mask)

# subtle top highlight
hl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(hl).ellipse([P(-80), P(-520), P(1104), P(430)], fill=(255, 255, 255, 34))
hl_mask = Image.composite(hl, Image.new("RGBA", (S, S), (0, 0, 0, 0)), mask)
icon.alpha_composite(hl_mask)

d = ImageDraw.Draw(icon)
white = (255, 255, 255, 255)

# trash can: handle, lid, body
d.rounded_rectangle([P(452), P(250), P(572), P(300)], radius=P(18), outline=white, width=int(P(22)))
d.rounded_rectangle([P(300), P(290), P(724), P(340)], radius=P(22), fill=white)
d.polygon([(P(334), P(372)), (P(690), P(372)), (P(660), P(760)), (P(364), P(760))], fill=white)
d.rounded_rectangle([P(352), P(700), P(672), P(790)], radius=P(44), fill=white)
d.rectangle([P(334), P(372), P(690), P(400)], fill=white)

# restore arrow cut into the can (circular arrow, counter-clockwise)
arrow = (24, 96, 158, 255)
cx, cy, r, w = P(512), P(572), P(112), P(38)
start, end = 320, 230  # PIL angles: 0 = east, increase clockwise
d.arc([cx - r, cy - r, cx + r, cy + r], start=start, end=end, fill=arrow, width=int(w))
# arrowhead at the 'end' angle, pointing along the clockwise tangent
a = math.radians(end)
ex, ey = cx + (r - w / 2) * math.cos(a), cy + (r - w / 2) * math.sin(a)
tx, ty = -math.sin(a), math.cos(a)          # clockwise tangent
nx, ny = math.cos(a), math.sin(a)            # outward normal
L, H = P(78), P(70)
tip = (ex + tx * L * 0.85, ey + ty * L * 0.85)
b1 = (ex + nx * H - tx * L * 0.15, ey + ny * H - ty * L * 0.15)
b2 = (ex - nx * H - tx * L * 0.15, ey - ny * H - ty * L * 0.15)
d.polygon([tip, b1, b2], fill=arrow)

app = icon.resize((1024, 1024), Image.LANCZOS)
app.save("AppIcon-1024.png")
app.save("AppIcon.icns", sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])

# ---------- Menu-bar template icon (black + alpha) ----------
M = 720  # draw big, downsample to 36 / 18
m = M / 18
mb = Image.new("RGBA", (M, M), (0, 0, 0, 0))
md = ImageDraw.Draw(mb)
black = (0, 0, 0, 255)
sw = int(1.6 * m)
md.rounded_rectangle([7 * m, 1.2 * m, 11 * m, 3.4 * m], radius=0.8 * m, outline=black, width=sw)
md.rounded_rectangle([2.2 * m, 3.0 * m, 15.8 * m, 4.6 * m], radius=0.8 * m, fill=black)
md.line([(3.8 * m, 5.6 * m), (4.8 * m, 16.4 * m), (13.2 * m, 16.4 * m), (14.2 * m, 5.6 * m)], fill=black, width=sw, joint="curve")
md.ellipse([4.8 * m - sw / 2, 16.4 * m - sw / 2, 4.8 * m + sw / 2, 16.4 * m + sw / 2], fill=black)
md.ellipse([13.2 * m - sw / 2, 16.4 * m - sw / 2, 13.2 * m + sw / 2, 16.4 * m + sw / 2], fill=black)
# up arrow inside = "bring it back"
md.line([(9 * m, 14.2 * m), (9 * m, 8.2 * m)], fill=black, width=sw)
md.polygon([(9 * m, 6.4 * m), (6.4 * m, 9.4 * m), (11.6 * m, 9.4 * m)], fill=black)

mb.resize((36, 36), Image.LANCZOS).save("MenuBarIcon@2x.png")
mb.resize((18, 18), Image.LANCZOS).save("MenuBarIcon.png")

# preview sheet: dock icon + menu-bar icon on light and dark bars
prev = Image.new("RGBA", (900, 420), (236, 236, 240, 255))
prev.alpha_composite(app.resize((360, 360), Image.LANCZOS), (30, 30))
pd = ImageDraw.Draw(prev)
big = mb.resize((108, 108), Image.LANCZOS)
pd.rounded_rectangle([450, 60, 870, 190], radius=16, fill=(246, 246, 246, 255))
prev.alpha_composite(big, (606, 71))
pd.rounded_rectangle([450, 230, 870, 360], radius=16, fill=(40, 40, 44, 255))
inv = Image.new("RGBA", big.size, (255, 255, 255, 255))
inv.putalpha(big.getchannel("A"))
prev.alpha_composite(inv, (606, 241))
prev.save("icon-preview.png")

chk = Image.open("AppIcon.icns")
print("icns sizes:", sorted(chk.info.get("sizes", [])))
