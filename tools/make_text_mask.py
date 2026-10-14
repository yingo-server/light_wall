#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成文字 alpha 蒙版（8 位灰度 PNG），供 lightwall_core 的叠字流程使用。

为什么放在外面：内核是纯 Dart、零依赖，不包含字体光栅化；真实 App 里
由 Flutter 的 TextPainter 生成蒙版，CI/批处理里由本脚本生成 —— 两者
产出的蒙版格式完全一致，后续的年代感与合成走同一份内核代码。

用法：
    python3 tools/make_text_mask.py --text "朝闻道" --out mask.png \
        --width 960 --height 540 --font-ratio 0.18
"""
import argparse
import os
import sys

from PIL import Image, ImageDraw, ImageFont

# 优先使用开源中文字体（CI 上通过 apt 安装 fonts-noto-cjk）
FONT_CANDIDATES = [
    "/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/noto/NotoSerifCJK-Regular.ttc",
    "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/opentype/noto/NotoSerifCJK-Bold.ttc",
    "C:/Windows/Fonts/simkai.ttf",
    "C:/Windows/Fonts/simsun.ttc",
    "C:/Windows/Fonts/msyh.ttc",
    "/System/Library/Fonts/Supplemental/Songti.ttc",
]


def pick_font(explicit=None):
    if explicit:
        if not os.path.exists(explicit):
            sys.exit(f"字体不存在: {explicit}")
        return explicit
    for p in FONT_CANDIDATES:
        if os.path.exists(p):
            return p
    sys.exit("找不到可用的中文字体，请用 --font 指定")


def split_lines(text):
    """半角逗号转全角并按标点断行；显式 \\n 优先。"""
    if "\n" in text:
        return [s for s in text.split("\n") if s]
    t = text.replace(",", "，")
    if "，" in t and len(t) > 3:
        parts = t.split("，")
        lines = []
        for i, p in enumerate(parts):
            if not p:
                continue
            lines.append(p + "，" if i < len(parts) - 1 else p)
        return lines
    return [t]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--width", type=int, default=960)
    ap.add_argument("--height", type=int, default=540)
    ap.add_argument("--font-ratio", type=float, default=0.18)
    ap.add_argument("--font", default=None)
    ap.add_argument("--anchor", default="center")
    ap.add_argument("--pos-x", type=float, default=50.0)
    ap.add_argument("--pos-y", type=float, default=50.0)
    ap.add_argument("--ssaa", type=int, default=2, help="超采样倍数（提高边缘质量）")
    args = ap.parse_args()

    font_path = pick_font(args.font)
    ss = max(1, args.ssaa)
    w, h = args.width * ss, args.height * ss
    img = Image.new("L", (w, h), 0)
    draw = ImageDraw.Draw(img)

    size = max(8, int(h * args.font_ratio))
    font = ImageFont.truetype(font_path, size, index=0)

    lines = split_lines(args.text)
    # 逐行测量
    metrics = []
    for line in lines:
        bbox = draw.textbbox((0, 0), line, font=font)
        metrics.append((bbox[2] - bbox[0], bbox[3] - bbox[1], bbox))
    line_h = int(size * 1.35)
    total_h = line_h * len(lines)
    cx = w * args.pos_x / 100.0
    cy = h * args.pos_y / 100.0
    y0 = cy - total_h / 2.0

    for i, line in enumerate(lines):
        lw, lh, bbox = metrics[i]
        x = cx - lw / 2.0 - bbox[0]
        y = y0 + i * line_h - bbox[1] + (line_h - lh) / 2.0
        draw.text((x, y), line, font=font, fill=255)

    if ss > 1:
        img = img.resize((args.width, args.height), Image.LANCZOS)

    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    img.save(args.out)
    dark = sum(1 for p in img.getdata() if p > 8)
    print(f"蒙版: {args.out}  {args.width}x{args.height}  字体={os.path.basename(font_path)} "
          f"字号={size // ss}px  覆盖率={dark / (args.width * args.height) * 100:.2f}%")


if __name__ == "__main__":
    main()
