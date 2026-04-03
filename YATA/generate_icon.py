# /// script
# requires-python = ">=3.11"
# dependencies = ["Pillow"]
# ///

from PIL import Image, ImageDraw, ImageFilter
import random
import math

# Render at 4x for anti-aliasing, downscale at the end
RENDER = 4096
FINAL = 1024
img = Image.new("RGBA", (RENDER, RENDER), (0, 0, 0, 255))

# --- Background: layered gradient ---
bg = Image.new("RGBA", (RENDER, RENDER))
cx, cy = RENDER // 2, RENDER // 2

# Base: deep charcoal with subtle blue undertone
for y in range(RENDER):
    t = y / RENDER
    r = int(22 + t * 10)
    g = int(22 + t * 6)
    b = int(28 + t * 8)
    for x in range(RENDER):
        bg.putpixel((x, y), (r, g, b, 255))

# --- Large soft radial glow (ambient light from above-center) ---
glow_layer = Image.new("RGBA", (RENDER, RENDER), (0, 0, 0, 0))
glow_cx, glow_cy = cx, cy - 200
for radius in range(1600, 0, -2):
    t = 1 - radius / 1600
    alpha = int(22 * t ** 1.8)
    r = int(55 + 35 * t)
    g = int(50 + 25 * t)
    b = int(65 + 30 * t)
    draw_g = ImageDraw.Draw(glow_layer)
    draw_g.ellipse(
        [glow_cx - radius, glow_cy - radius, glow_cx + radius, glow_cy + radius],
        fill=(r, g, b, alpha),
    )
bg = Image.alpha_composite(bg, glow_layer)

# --- Subtle warm spot (off-center, adds depth) ---
warm = Image.new("RGBA", (RENDER, RENDER), (0, 0, 0, 0))
warm_draw = ImageDraw.Draw(warm)
wx, wy = cx - 400, cy - 300
for radius in range(600, 0, -2):
    t = 1 - radius / 600
    alpha = int(6 * t ** 2)
    warm_draw.ellipse(
        [wx - radius, wy - radius, wx + radius, wy + radius],
        fill=(140, 110, 80, alpha),
    )
bg = Image.alpha_composite(bg, warm)

# --- Fine grain texture ---
grain = Image.new("RGBA", (RENDER, RENDER), (0, 0, 0, 0))
random.seed(42)
for _ in range(int(RENDER * RENDER * 0.008)):
    x = random.randint(0, RENDER - 1)
    y = random.randint(0, RENDER - 1)
    v = random.randint(200, 255)
    a = random.randint(4, 14)
    grain.putpixel((x, y), (v, v, v, a))
# Slight blur on grain for subtlety
grain = grain.filter(ImageFilter.GaussianBlur(radius=0.5))
bg = Image.alpha_composite(bg, grain)

# --- Content: three checkmarks + lines ---
# Colors: richer but still muted — like tinted metallics
check_colors = [
    (110, 195, 140),  # sage green
    (215, 185, 95),   # warm gold
    (200, 110, 105),  # dusty rose
]

glow_colors = [
    (90, 220, 130),   # green bloom
    (240, 200, 80),   # gold bloom
    (230, 100, 90),   # rose bloom
]

# Vertical layout: centered, scaled up to fill icon
row_spacing = 680
first_row_y = cy - row_spacing
row_ys = [first_row_y, cy, first_row_y + row_spacing * 2]

# Horizontal: checkmark on left, line on right — wider spread
check_center_x = cx - 750
line_start_x = cx - 280
line_end_x = cx + 1050

stroke_w = 76  # checkmark stroke width
line_h = 38    # line thickness
round_r = line_h // 2


def draw_checkmark(target, center_x, center_y, color, glow_col, shadow=True):
    """Draw a single elegant checkmark with glow and shadow."""
    d = ImageDraw.Draw(target)
    # Checkmark geometry — scaled up, golden proportions
    s = 2.0  # scale factor
    p1 = (center_x - int(100*s), center_y - int(15*s))
    p2 = (center_x - int(20*s), center_y + int(75*s))
    p3 = (center_x + int(120*s), center_y - int(85*s))

    if shadow:
        # Drop shadow
        s_off = 12
        s_col = (0, 0, 0, 90)
        d.line([(p1[0]+s_off, p1[1]+s_off), (p2[0]+s_off, p2[1]+s_off)],
               fill=s_col, width=stroke_w + 8)
        d.line([(p2[0]+s_off, p2[1]+s_off), (p3[0]+s_off, p3[1]+s_off)],
               fill=s_col, width=stroke_w + 8)
        # Round joints
        d.ellipse([p2[0]+s_off - stroke_w//2 - 4, p2[1]+s_off - stroke_w//2 - 4,
                    p2[0]+s_off + stroke_w//2 + 4, p2[1]+s_off + stroke_w//2 + 4],
                   fill=s_col)

    # Glow bloom layer (drawn on separate image, blurred, composited)
    bloom = Image.new("RGBA", (RENDER, RENDER), (0, 0, 0, 0))
    bd = ImageDraw.Draw(bloom)
    bloom_col = glow_col + (120,)
    bd.line([p1, p2], fill=bloom_col, width=stroke_w + 120)
    bd.line([p2, p3], fill=bloom_col, width=stroke_w + 120)
    bd.ellipse([p2[0] - stroke_w//2 - 60, p2[1] - stroke_w//2 - 60,
                p2[0] + stroke_w//2 + 60, p2[1] + stroke_w//2 + 60],
               fill=bloom_col)
    bloom = bloom.filter(ImageFilter.GaussianBlur(radius=80))

    # Main stroke
    main_col = color + (255,)
    d.line([p1, p2], fill=main_col, width=stroke_w)
    d.line([p2, p3], fill=main_col, width=stroke_w)
    # Round the joint at p2
    d.ellipse([p2[0] - stroke_w//2, p2[1] - stroke_w//2,
               p2[0] + stroke_w//2, p2[1] + stroke_w//2],
              fill=main_col)
    # Round end caps
    for p in [p1, p3]:
        d.ellipse([p[0] - stroke_w//2, p[1] - stroke_w//2,
                    p[0] + stroke_w//2, p[1] + stroke_w//2],
                   fill=main_col)

    # Inner highlight (top-left light source)
    hl_col = tuple(min(255, c + 70) for c in color) + (180,)
    hl_w = max(6, stroke_w // 4)
    d.line([p1, p2], fill=hl_col, width=hl_w)
    d.line([p2, p3], fill=hl_col, width=hl_w)

    return bloom


def draw_line(target, y, start_x, end_x):
    """Draw a subtle rounded line with shadow."""
    d = ImageDraw.Draw(target)
    # Shadow
    s_off = 8
    d.rounded_rectangle(
        [start_x + s_off, y - line_h//2 + s_off, end_x + s_off, y + line_h//2 + s_off],
        radius=round_r, fill=(0, 0, 0, 60),
    )
    # Main line: subtle warm grey
    d.rounded_rectangle(
        [start_x, y - line_h//2, end_x, y + line_h//2],
        radius=round_r, fill=(100, 100, 110, 120),
    )
    # Highlight on top edge
    d.rounded_rectangle(
        [start_x + 4, y - line_h//2, end_x - 4, y - line_h//2 + 4],
        radius=2, fill=(160, 160, 170, 40),
    )


# Draw all elements
content = Image.new("RGBA", (RENDER, RENDER), (0, 0, 0, 0))
all_blooms = Image.new("RGBA", (RENDER, RENDER), (0, 0, 0, 0))

for i, row_y in enumerate(row_ys):
    draw_line(content, row_y, line_start_x, line_end_x)
    bloom = draw_checkmark(content, check_center_x, row_y, check_colors[i], glow_colors[i])
    all_blooms = Image.alpha_composite(all_blooms, bloom)

# Composite: bg + blooms + content
result = Image.alpha_composite(bg, all_blooms)
result = Image.alpha_composite(result, content)

# --- Edge vignette for depth ---
vignette = Image.new("RGBA", (RENDER, RENDER), (0, 0, 0, 0))
vig_draw = ImageDraw.Draw(vignette)
for border in range(300):
    alpha = int(70 * (1 - border / 300) ** 2.5)
    vig_draw.rectangle(
        [border, border, RENDER - 1 - border, RENDER - 1 - border],
        outline=(0, 0, 0, alpha),
    )
result = Image.alpha_composite(result, vignette)

# --- Downsample with high-quality Lanczos ---
result = result.convert("RGB")
result = result.resize((FINAL, FINAL), Image.LANCZOS)

output_path = "/Users/aravindhsampathkumar/ai_playground/yata/YATA/YATA/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
result.save(output_path, "PNG")
print(f"Icon saved to {output_path}")
