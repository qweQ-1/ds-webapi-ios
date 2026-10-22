from PIL import Image, ImageDraw, ImageFont
import os

SIZE = 1024
OUT = "/var/minis/shared/DSWebAPI/DSWebAPI/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"

top = (77, 107, 254)     # #4D6BFE
bottom = (31, 41, 110)   # #1F296E

img = Image.new("RGB", (SIZE, SIZE), top)
draw = ImageDraw.Draw(img)

# 竖向渐变
for y in range(SIZE):
    t = y / (SIZE - 1)
    color = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    draw.line([(0, y), (SIZE, y)], fill=color)

white = (255, 255, 255)
soft = (222, 230, 255)


def arrow(draw_obj, x0, x1, y, thick, head, direction=1):
    """画一条水平箭头：direction=1 向右，-1 向左"""
    if direction == 1:
        shaft_x1 = x1 - head
        draw_obj.rounded_rectangle([x0, y - thick // 2, shaft_x1, y + thick // 2],
                                   radius=thick // 2, fill=white)
        draw_obj.polygon([(shaft_x1, y - head // 2 - 10), (x1, y), (shaft_x1, y + head // 2 + 10)], fill=white)
    else:
        shaft_x0 = x0 + head
        draw_obj.rounded_rectangle([shaft_x0, y - thick // 2, x1, y + thick // 2],
                                   radius=thick // 2, fill=white)
        draw_obj.polygon([(shaft_x0, y - head // 2 - 10), (x0, y), (shaft_x0, y + head // 2 + 10)], fill=white)


# 两条对向箭头：网页端 ⇄ API
arrow(draw, 250, 790, 370, 56, 150, 1)
arrow(draw, 250, 790, 500, 56, 150, -1)

# API 字样
font_path = "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf"
font = ImageFont.truetype(font_path, 210)
text = "API"
bbox = draw.textbbox((0, 0), text, font=font)
w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
draw.text(((SIZE - w) / 2 - bbox[0], 600 - bbox[1]), text, font=font, fill=white)

os.makedirs(os.path.dirname(OUT), exist_ok=True)
img.save(OUT, "PNG")
print("saved", OUT, os.path.getsize(OUT), "bytes")
