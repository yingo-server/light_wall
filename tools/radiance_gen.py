#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Radiance 全天墙面采光渲染（CI 用，x86_64 Linux）

调用链（全部通过 pyradiance，bytes 进 bytes 出）：
    gensky      → 按日期/经纬度生成天空 + 太阳
    oconv       → 场景编译成八叉树
    mkillum     → 把窗面换成二次光源（窗户采光的关键一步）
    rpict       → 渲染（-n 多进程）
    pfilt       → 曝光/滤波
    ra_tiff     → 输出图片

用法（CI 内）：
    pip install pyradiance
    python3 tools/radiance_gen.py --out-dir dist/radiance \
        --date 2025-12-21 --lat 39.9042 --lon 116.4074 --tz 8 \
        --window-az 180 --from 8 --to 17 --every-min 5 --size 1280x720
"""
import argparse
import datetime as dt
import json
import math
import os

import pyradiance as pr

# ────────────────────────── 场景几何 ──────────────────────────
# 房间：宽 4 m × 深 5 m × 高 2.9 m，窗在 +Y 方向的墙上（北墙），
# 相机站在房间内朝窗对面的墙看（也就是画面里是"受光墙"）。

def room_rad(width=4.0, depth=5.0, height=2.9,
             win_w=1.4, win_h=1.6, win_sill=0.9, win_offset=0.7):
    """生成房间 + 窗洞（墙面用 4 块多边形拼出窗洞）。"""
    x0, x1 = -width / 2, width / 2
    y0, y1 = 0.0, depth
    z0, z1 = 0.0, height

    # 窗在 y1 墙上（面向 +Y 室外），水平居中偏移
    wx0 = -win_w / 2 + win_offset
    wx1 = wx0 + win_w
    wz0 = win_sill
    wz1 = win_sill + win_h

    def poly(name, mat, pts):
        p = " ".join(f"{x:.3f} {y:.3f} {z:.3f}" for x, y, z in pts)
        return f'{mat} polygon {name}\n0\n0\n{len(pts) * 3}\n{p}\n'

    out = []
    out.append("void plastic wallmat\n0\n0\n5 0.72 0.70 0.66\n")   # 墙：暖白
    out.append("void plastic floormat\n0\n0\n5 0.30 0.28 0.26\n")  # 地
    out.append("void plastic ceilmat\n0\n0\n5 0.80 0.80 0.78\n")   # 顶

    # 地板 / 天花
    out.append(poly("floor", "floormat", [(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0)]))
    out.append(poly("ceiling", "ceilmat", [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)]))
    # 左墙 (x0) / 右墙 (x1)
    out.append(poly("left", "wallmat", [(x0, y0, z0), (x0, y1, z0), (x0, y1, z1), (x0, y0, z1)]))
    out.append(poly("right", "wallmat", [(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)]))
    # 观察墙 (y0) —— 相机正对它
    out.append(poly("obs", "wallmat", [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)]))

    # 窗墙 (y1)：四周四块拼出窗洞
    # Radiance 要求标识符全局唯一 —— 每段墙必须单独命名
    def seg(name, xa, xb, za, zb):
        return poly(name, "wallmat",
                    [(xa, y1, za), (xb, y1, za), (xb, y1, zb), (xa, y1, zb)])
    out.append(seg("winwall_l", x0, wx0, z0, z1))
    out.append(seg("winwall_r", wx1, x1, z0, z1))
    out.append(seg("winwall_b", wx0, wx1, z0, wz0))
    out.append(seg("winwall_t", wx0, wx1, wz1, z1))
    return "".join(out), (wx0, wx1, wz0, wz1, y1)


def window_rad(win, az):
    """窗洞面：给 mkillum 用的表面（朝室外）。"""
    wx0, wx1, wz0, wz1, y1 = win
    pts = [(wx0, y1, wz0), (wx1, y1, wz0), (wx1, y1, wz1), (wx0, y1, wz1)]
    p = " ".join(f"{x:.3f} {y:.3f} {z:.3f}" for x, y, z in pts)
    # 透明玻璃材质（透过率 0.88）
    return f"""void glass glazing
0
0
3 0.88 0.88 0.88
glazing polygon win
0
0
{len(pts) * 3}
{p}
"""


def _oconv_debug(text: bytes, out: str, tmpdir: str):
    """直接调用 oconv 并保留 stderr（pyradiance 的封装会吞掉报错）。"""
    import subprocess
    from pyradiance.anci import BINPATH
    rad = os.path.join(tmpdir, "scene.rad")
    with open(rad, "wb") as f:
        f.write(text)
    r = subprocess.run([str(BINPATH / "oconv"), "-w", rad],
                       capture_output=True)
    if r.returncode != 0:
        print("── oconv 失败 ──", flush=True)
        print("stderr:", r.stderr.decode(errors="replace")[:2000], flush=True)
        # 打印场景文本尾部（定位语法错误）
        txt = text.decode(errors="replace").splitlines()
        print("场景共", len(txt), "行；前 12 行：", flush=True)
        for line in txt[:12]:
            print("  |", line, flush=True)
    with open(out, "wb") as f:
        f.write(r.stdout)
    return r.returncode == 0


def build_scene(sky_bytes, room_txt, win_txt, tmpdir):
    """编译场景：天空 + 房间 → 八叉树，再用 mkillum 把窗面转成二次光源。"""
    base = os.path.join(tmpdir, "base.oct")
    if not _oconv_debug(sky_bytes + room_txt.encode(), base, tmpdir):
        raise RuntimeError("oconv 失败（见上方 stderr）")
    # mkillum：输入窗面，输出 illum 定义（标准窗户采光流程）
    illum = pr.mkillum(inp=win_txt.encode(), octree=base, nproc=4)
    final = os.path.join(tmpdir, "scene.oct")
    with open(final, "wb") as f:
        f.write(pr.oconv(stdin=(sky_bytes + illum), warning=False))
    return final


def render_one(sky_bytes, octree, out_png, w, h, cam, exposure=0.0, nproc=8):
    """渲染单帧：rpict → pfilt → png。"""
    view = [
        "-vtv", "180",                      # 视图类型：从相机看
        "-vp", f"{cam[0]:.3f} {cam[1]:.3f} {cam[2]:.3f}",  # 视点位
        "-vd", f"{cam[3]:.3f} {cam[4]:.3f} {cam[5]:.3f}",  # 视线方向
        "-vh", "90",                        # 水平视角
        "-vv", "55",
    ]
    params = ["-ab", "4", "-ad", "2048", "-as", "512", "-ar", "128",
              "-aa", "0.08", "-lr", "6", "-lw", "0.002", "-n", str(nproc)]
    hdr = pr.rpict(view, octree, xres=w, yres=h, params=params)
    hdr = pr.pfilt(hdr, xres=str(w), yres=str(h), exposure=exposure)
    tiff = pr.ra_tiff(hdr, out=out_png.replace(".png", ".tif"), lzw=True)
    return tiff


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--date", default="2025-12-21")
    ap.add_argument("--lat", type=float, default=39.9042)
    ap.add_argument("--lon", type=float, default=116.4074)
    ap.add_argument("--tz", type=int, default=8)
    ap.add_argument("--window-az", type=float, default=180.0)
    ap.add_argument("--from", dest="h0", type=float, default=7.0)
    ap.add_argument("--to", dest="h1", type=float, default=18.0)
    ap.add_argument("--every-min", type=int, default=30)
    ap.add_argument("--size", default="1280x720")
    ap.add_argument("--nproc", type=int, default=8)
    args = ap.parse_args()

    w, h = (int(v) for v in args.size.lower().split("x"))
    os.makedirs(args.out_dir, exist_ok=True)
    tmp = os.path.join(args.out_dir, ".tmp")
    os.makedirs(tmp, exist_ok=True)

    room_txt, win = room_rad()
    win_txt = window_rad(win, args.window_az)

    # 相机：站在房间内靠窗一侧，朝观察墙看
    cam = (0.0, 4.2, 1.55, 0.0, -1.0, 0.0)

    day = dt.date.fromisoformat(args.date)
    frames = []
    t = args.h0 * 60
    end = args.h1 * 60
    idx = 0
    while t <= end:
        hh, mm = divmod(int(t), 60)
        tm = dt.datetime(day.year, day.month, day.day, hh, mm)
        idx += 1
        out_png = os.path.join(args.out_dir, f"f{idx:04d}.png")
        # gensky：晴天带太阳（-ang 用高度/方位由 pyradiance 从经纬度算）
        sky = pr.gensky(dt=tm, latitude=args.lat, longitude=args.lon,
                        timezone=args.tz, sunny_with_sun=True)
        octree = build_scene(sky, room_txt, win_txt, tmp)
        try:
            render_one(sky, octree, out_png, w, h, cam, nproc=args.nproc)
            ok = os.path.exists(out_png.replace(".png", ".tif"))
            print(f"[{idx}] {hh:02d}:{mm:02d} -> {out_png} {'OK' if ok else 'FAIL'}", flush=True)
        except Exception as e:  # noqa: BLE001
            print(f"[{idx}] {hh:02d}:{mm:02d} 失败: {e}", flush=True)
        frames.append({"index": idx, "time": f"{hh:02d}:{mm:02d}"})
        t += args.every_min

    with open(os.path.join(args.out_dir, "timeline.json"), "w", encoding="utf-8") as f:
        json.dump({"frames": frames, "params": vars(args)}, f, ensure_ascii=False, indent=2)
    print(f"完成 {len(frames)} 帧")


if __name__ == "__main__":
    main()
