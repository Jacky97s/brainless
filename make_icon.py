from PIL import Image, ImageDraw
import os, subprocess
S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
# 背景：圓角方形，上藍下粉的漸層
grad = Image.new("RGBA", (S, S))
gd = ImageDraw.Draw(grad)
top, bot = (72, 86, 232), (232, 90, 156)
for y in range(S):
    t = y / (S - 1)
    c = tuple(int(top[i] * (1 - t) + bot[i] * t) for i in range(3)) + (255,)
    gd.line([(0, y), (S, y)], fill=c)
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([64, 64, S - 64, S - 64], radius=220, fill=255)
img.paste(grad, (0, 0), mask)
# 聲波：五根白色圓角直條
d = ImageDraw.Draw(img)
heights = [0.28, 0.52, 0.78, 0.52, 0.28]
bw, gap = 88, 56
total = 5 * bw + 4 * gap
x0 = (S - total) // 2
for i, h in enumerate(heights):
    hh = int(S * 0.62 * h)
    x = x0 + i * (bw + gap)
    d.rounded_rectangle([x, S // 2 - hh // 2, x + bw, S // 2 + hh // 2], radius=bw // 2, fill=(255, 255, 255, 240))
os.makedirs("Resources/AppIcon.iconset", exist_ok=True)
for sz in [16, 32, 64, 128, 256, 512, 1024]:
    im = img.resize((sz, sz), Image.LANCZOS)
    im.save(f"Resources/AppIcon.iconset/icon_{sz}x{sz}.png")
    if sz <= 512:
        img.resize((sz * 2, sz * 2), Image.LANCZOS).save(f"Resources/AppIcon.iconset/icon_{sz}x{sz}@2x.png")
img.save("Resources/icon-1024.png")
subprocess.run(["iconutil", "-c", "icns", "Resources/AppIcon.iconset", "-o", "Resources/AppIcon.icns"], check=True)
print("icon ok")
