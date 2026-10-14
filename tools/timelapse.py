#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""全天延时渲染驱动：在 N 个时间节点上调用内核渲染器，输出帧序列 + 时间线。

用法：
    python3 tools/timelapse.py --engine ./render --bg wall.png \
        --out-dir dist/timelapse --frames 60 --size 960x540 \
        --date 2025-12-21 --lat 39.9042 --lon 116.4074 --window east \
        --mask mask.png --text "朝闻道"
"""
import argparse
import datetime as dt
import json
import os
import subprocess
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True, help="编译好的渲染器可执行文件")
    ap.add_argument("--bg", required=True, help="底图 PNG")
    ap.add_argument("--mask", default=None, help="文字 alpha 蒙版 PNG")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--frames", type=int, default=60)
    ap.add_argument("--size", default="960x540", help="宽x高")
    ap.add_argument("--date", default="2025-12-21")
    ap.add_argument("--lat", type=float, default=39.9042)
    ap.add_argument("--lon", type=float, default=116.4074)
    ap.add_argument("--window", default="east")
    ap.add_argument("--grid-rows", default="3")
    ap.add_argument("--grid-cols", default="2")
    ap.add_argument("--style", default="default")
    ap.add_argument("--seed", default="20251014")
    ap.add_argument("--text", default="朝闻道")
    ap.add_argument("--lat-spread", action="store_true",
                    help="按月份铺开（用 12 个月的代表日，展示季节变化）")
    ap.add_argument("--timeout", type=int, default=600, help="单帧超时（秒）")
    args = ap.parse_args()

    w, h = (int(v) for v in args.size.lower().split("x"))
    frames_dir = os.path.join(args.out_dir, "frames")
    os.makedirs(frames_dir, exist_ok=True)

    # 时间节点：默认在一天内均分（每 24 min 一个点，60 帧 → 一天）
    day = dt.date.fromisoformat(args.date)
    points = []
    for i in range(args.frames):
        minutes = int(round(i * 24 * 60 / args.frames))
        base = dt.datetime(day.year, day.month, day.day, 0, 0, 0)
        t = base + dt.timedelta(minutes=minutes)
        points.append(t)

    timeline = []
    fails = 0
    for idx, t in enumerate(points):
        out = os.path.join(frames_dir, f"f{idx:04d}.png")
        cmd = [
            args.engine,
            "--bg", args.bg,
            "--out", out,
            "--width", str(w),
            "--height", str(h),
            "--time", t.strftime("%Y-%m-%dT%H:%M:%S+08:00"),
            "--lat", str(args.lat),
            "--lon", str(args.lon),
            "--window", args.window,
            "--grid-rows", args.grid_rows,
            "--grid-cols", args.grid_cols,
            "--style", args.style,
            "--seed", args.seed,
        ]
        if args.mask:
            cmd += ["--text-alpha", args.mask]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True,
                               timeout=args.timeout)
            info = json.loads(r.stdout) if r.stdout.strip() else {}
        except Exception as e:  # noqa: BLE001
            info = {"error": str(e)}
        if "error" in info or not os.path.exists(out):
            fails += 1
            print(f"[{idx + 1}/{len(points)}] {t:%H:%M} 失败: {info.get('error', '未知')}")
        else:
            st = info.get("stats", {})
            print(f"[{idx + 1}/{len(points)}] {t:%H:%M} alt={info.get('sun_alt')} "
                  f"beam={info.get('beam')} vis={st.get('visible_ratio')} "
                  f"{info.get('ms')}ms")
        timeline.append({
            "index": idx,
            "time": t.strftime("%Y-%m-%dT%H:%M:00+08:00"),
            "file": os.path.basename(out),
            **{k: info.get(k) for k in ("sun_alt", "sun_az", "beam", "source", "ms")},
            "visible_ratio": (info.get("stats") or {}).get("visible_ratio"),
        })

    with open(os.path.join(args.out_dir, "timeline.json"), "w", encoding="utf-8") as f:
        json.dump({"frames": timeline, "text": args.text}, f,
                  ensure_ascii=False, indent=2)
    with open(os.path.join(args.out_dir, "timeline.tsv"), "w", encoding="utf-8") as f:
        f.write("idx\ttime\talt\tbeam\tvis\tms\n")
        for e in timeline:
            f.write(f"{e['index']}\t{e['time']}\t{e.get('sun_alt')}\t{e.get('beam')}"
                    f"\t{e.get('visible_ratio')}\t{e.get('ms')}\n")

    ok = len(points) - fails
    print(f"\n完成：{ok}/{len(points)} 帧成功，失败 {fails}")
    if fails > len(points) // 3:
        sys.exit(1)


if __name__ == "__main__":
    main()
