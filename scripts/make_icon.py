#!/usr/bin/env python3
"""从一张透明底的单色字形 PNG 生成 macOS 应用图标和菜单栏模板图。

用法:
    python3 scripts/make_icon.py <源图.png>

产出:
    Resources/AppIcon.icns        应用图标（白底圆角 + 黑色字形）
    Resources/MenuBarIcon.png     18pt 菜单栏模板图
    Resources/MenuBarIcon@2x.png
"""
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

CANVAS = 1024
# macOS 图标内容区：四周留 100px
PLATE = CANVAS - 200
RADIUS = int(PLATE * 0.2237)
SUPERSAMPLE = 4


def _dt1d(f: np.ndarray) -> np.ndarray:
    """一维平方距离变换（Felzenszwalb & Huttenlocher）。"""
    n = len(f)
    d = np.empty(n)
    v = np.zeros(n, dtype=int)
    z = np.zeros(n + 1)
    k = 0
    v[0] = 0
    z[0] = -np.inf
    z[1] = np.inf
    for q in range(1, n):
        s = ((f[q] + q * q) - (f[v[k]] + v[k] * v[k])) / (2 * q - 2 * v[k])
        while s <= z[k]:
            k -= 1
            s = ((f[q] + q * q) - (f[v[k]] + v[k] * v[k])) / (2 * q - 2 * v[k])
        k += 1
        v[k] = q
        z[k] = s
        z[k + 1] = np.inf
    k = 0
    for q in range(n):
        while z[k + 1] < q:
            k += 1
        d[q] = (q - v[k]) ** 2 + f[v[k]]
    return d


def distance_transform(mask: np.ndarray) -> np.ndarray:
    """前景到最近背景的欧氏距离。"""
    inf = 1e12
    f = np.where(mask, inf, 0.0).astype(np.float64)
    for y in range(f.shape[0]):
        f[y] = _dt1d(f[y])
    for x in range(f.shape[1]):
        f[:, x] = _dt1d(f[:, x])
    return np.sqrt(f)


def _run_lengths(mask: np.ndarray) -> list:
    out = []
    for row in mask:
        count = 0
        for value in row:
            if value:
                count += 1
            elif count:
                out.append(count)
                count = 0
        if count:
            out.append(count)
    return out


def stroke_width(mask: np.ndarray) -> float:
    """笔画宽度 = 横竖游程里最常见的那一档（字形里有实心块，距离变换会被它带偏）。"""
    if not mask.any():
        return 0.0
    lengths = _run_lengths(mask) + _run_lengths(np.ascontiguousarray(mask.T))
    lengths = [value for value in lengths if value >= 2]
    if not lengths:
        return 0.0
    counts = np.bincount(np.array(lengths, dtype=int))
    return float(np.argmax(counts))


def thin_strokes(glyph: Image.Image, scale: float, supersample: int = 4) -> Image.Image:
    """把笔画整体变细到 scale 倍：每条边向内收 (1-scale)/2 个线宽。"""
    if scale >= 1.0:
        return glyph
    big = glyph.resize((glyph.width * supersample, glyph.height * supersample), Image.LANCZOS)
    alpha = np.array(big.split()[3])
    # 字形贴边时，图像外不算背景，距离变换会只从一侧侵蚀。补一圈背景再算。
    pad = supersample * 2
    mask = np.pad(alpha > 8, pad, constant_values=False)
    width = stroke_width(mask)
    shrink = width * (1 - scale) / 2
    print(f"  笔画宽度 {width / supersample:.2f}px，每条边内收 {shrink / supersample:.2f}px")
    distance = distance_transform(mask)
    thinned = distance > shrink

    # 让 50% 不透明度正好落在内收边界上，避免抗锯齿尾巴把笔画又撑粗
    soft = np.clip((distance - shrink + 0.5) * 255, 0, 255)
    soft = soft[pad:-pad, pad:-pad]
    mask = mask[pad:-pad, pad:-pad]

    pixels = np.array(big.copy())
    pixels[..., 3] = np.where(mask, np.minimum(pixels[..., 3], soft), 0).astype(np.uint8)
    out = Image.fromarray(pixels, "RGBA")
    out = out.resize(glyph.size, Image.LANCZOS)
    print(f"  变细后笔画宽度 {stroke_width(np.array(out.split()[3]) > 8):.2f}px")
    return out


def load_glyph(path: str) -> Image.Image:
    glyph = Image.open(path).convert("RGBA")
    bbox = glyph.split()[3].getbbox()
    if bbox:
        glyph = glyph.crop(bbox)
    return glyph


def make_app_icon(glyph: Image.Image) -> Image.Image:
    s = SUPERSAMPLE
    size = CANVAS * s
    plate = PLATE * s
    radius = RADIUS * s
    offset = 100 * s

    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # 底部一点投影，让圆角方块有厚度
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [offset, offset + 8 * s, offset + plate, offset + plate + 8 * s],
        radius=radius, fill=(0, 0, 0, 60))
    img = Image.alpha_composite(img, shadow.filter(ImageFilter.GaussianBlur(10 * s)))
    draw = ImageDraw.Draw(img)

    # 白底圆角方块
    draw.rounded_rectangle([offset, offset, offset + plate, offset + plate],
                           radius=radius, fill=(250, 250, 252, 255),
                           outline=(214, 214, 220, 255), width=2 * s)

    # 字形缩放到内容区的 46%，居中偏上一点
    target_w = int(plate * 0.46)
    ratio = target_w / glyph.width
    target_h = int(glyph.height * ratio)
    scaled = glyph.resize((target_w, target_h), Image.LANCZOS)

    gx = offset + (plate - target_w) // 2
    gy = offset + (plate - target_h) // 2
    img.paste(scaled, (gx, gy), scaled)

    return img.resize((CANVAS, CANVAS), Image.LANCZOS)


def make_menu_icon(glyph: Image.Image) -> dict:
    out = {}
    for scale, name in ((1, "MenuBarIcon.png"), (2, "MenuBarIcon@2x.png")):
        height = 16 * scale
        width = max(1, round(glyph.width * height / glyph.height))
        out[name] = glyph.resize((width, height), Image.LANCZOS)
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    source = sys.argv[1]
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    resources = os.path.join(root, "Resources")
    os.makedirs(resources, exist_ok=True)

    scale = 2 / 3
    if "--stroke-scale" in sys.argv:
        scale = float(sys.argv[sys.argv.index("--stroke-scale") + 1])
    print(f"笔画缩放到 {scale:.3f}")
    glyph = thin_strokes(load_glyph(source), scale)
    icon = make_app_icon(glyph)
    icon.save(os.path.join(resources, "AppIcon-1024.png"))

    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        for base in (16, 32, 128, 256, 512):
            for scale, suffix in ((1, ""), (2, "@2x")):
                size = base * scale
                name = f"icon_{base}x{base}{suffix}.png"
                icon.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, name))
        icns = os.path.join(resources, "AppIcon.icns")
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
        print("写入", icns)

    for name, image in make_menu_icon(glyph).items():
        path = os.path.join(resources, name)
        image.save(path)
        print("写入", path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
