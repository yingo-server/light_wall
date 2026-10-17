#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""全天延时渲染驱动：在 N 个时间节点上调用内核渲染器，输出帧序列 + 时间线。

帧数与时长二选一（都给时以帧数为准）：
    · --frames 600                      → 直接 600 帧，均分 24 h
    · --duration 300 --fps 2            → 300 s × 2 fps = 600 帧
时间节点在 24 小时内**等间隔抽样**（含 0:00，不含次日 0:00），与视频合成帧率
无关——合成时用 --fps 把 N 帧压到目标时长。

丙类可选参数（--cloud / --wet-ground / --indoor-light / --city-glow /
--absolute-lux / --visibility）原样透传给渲染内核，默认全关（行为同 v1.2.4）。

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
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True, help="编译好的渲染器可执行文件")
    ap.add_argument("--bg", required=True, help="底图 PNG")
    ap.add_argument("--mask", default=None, help="文字 alpha 蒙版 PNG")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--frames", type=int, default=0,
                    help="帧数（>0 时直接用；=0 时按 duration×fps 换算）")
    ap.add_argument("--duration", type=float, default=60.0,
                    help="目标视频时长（秒），用于自动换算帧数")
    ap.add_argument("--fps", type=float, default=1.0,
                    help="合成帧率（帧/秒），用于自动换算帧数")
    ap.add_argument("--size", default="960x540", help="宽x高")
    ap.add_argument("--date", default="2025-12-21")
    ap.add_argument("--lat", type=float, default=39.9042)
    ap.add_argument("--lon", type=float, default=116.4074)
    ap.add_argument("--tz", default="+08:00", help="时区（ISO 偏移，如 +08:00）")
    ap.add_argument("--window", default="east")
    ap.add_argument("--grid-rows", default="3")
    ap.add_argument("--grid-cols", default="2")
    ap.add_argument("--style", default="default")
    ap.add_argument("--seed", default="20251014")
    ap.add_argument("--text", default="朝闻道")
    ap.add_argument("--lat-spread", action="store_true",
                    help="按月份铺开（用 12 个月的代表日，展示季节变化）")
    ap.add_argument("--timeout", type=int, default=600, help="单帧超时（秒）")
    ap.add_argument("--jobs", type=int, default=1, help="并行渲染进程数")
    ap.add_argument("--verbose", action="store_true", help="逐帧完整命令行与内核 stdout")
    # ── 丙类可选（默认关，透传内核）──
    ap.add_argument("--cloud", type=float, default=0.0, help="云量 0~1")
    ap.add_argument("--wet-ground", action="store_true", help="雨湿地面（配合云量）")
    ap.add_argument("--indoor-light", type=float, default=0.0, help="室内灯相对强度")
    ap.add_argument("--city-glow", type=float, default=0.0, help="城市光污染（市区≈2）")
    ap.add_argument("--absolute-lux", default="",
                    help="绝对量纲标定（设定后停用自动曝光）")
    ap.add_argument("--visibility", type=float, default=20000.0, help="大气能见度（米）")
    args = ap.parse_args()

    frames = args.frames
    if frames <= 0:
        frames = max(2, int(round(args.duration * args.fps)))
    w, h = (int(v) for v in args.size.lower().split("x"))
    frames_dir = os.path.join(args.out_dir, "frames")
    os.makedirs(frames_dir, exist_ok=True)

    print(f"计划：{frames} 帧 · 目标时长 {frames / args.fps:.1f} s @ {args.fps} fps · "
          f"{w}x{h} · {args.date} · 窗 {args.window}", flush=True)

    # 时间节点：在一天内等间隔抽样（含 0:00，不含次日 0:00）。
    day = dt.date.fromisoformat(args.date)
    base = dt.datetime(day.year, day.month, day.day, 0, 0, 0)
    points = [base + dt.timedelta(minutes=24 * 60 * i / frames)
              for i in range(frames)]

    timeline = []
    fails = 0
    t0 = time.time()
    jobs = max(1, args.jobs)
    from concurrent.futures import ThreadPoolExecutor

    # 内核透传参数（丙类）
    extra = ["--lat", str(args.lat), "--lon", str(args.lon)]
    if args.cloud > 0:
        extra += ["--cloud", str(args.cloud)]
    if args.wet_ground:
        extra += ["--wet-ground", "true"]
    if args.indoor_light > 0:
        extra += ["--indoor-light", str(args.indoor_light)]
    if args.city_glow > 0:
        extra += ["--city-glow", str(args.city_glow)]
    if str(args.absolute_lux).strip():
        extra += ["--absolute-lux", str(args.absolute_lux).strip()]
    if abs(args.visibility - 20000.0) > 1e-9:
        extra += ["--visibility", str(args.visibility)]

    def render_one(idx, t):
        out = os.path.join(frames_dir, f"f{idx:04d}.png")
        cmd = [
            args.engine,
            "--bg", args.bg,
            "--out", out,
            "--width", str(w),
            "--height", str(h),
            "--time", t.strftime("%Y-%m-%dT%H:%M:%S") + args.tz,
            "--window", args.window,
            "--grid-rows", args.grid_rows,
            "--grid-cols", args.grid_cols,
            "--style", args.style,
            "--seed", args.seed,
        ] + extra
        if args.mask:
            cmd += ["--text-alpha", args.mask]
        if args.verbose:
            print(f"  $ {' '.join(cmd)}", flush=True)
        try:
            r = subprocess.run(cmd, capture_output=True, text=True,
                               timeout=args.timeout)
            info = json.loads(r.stdout) if r.stdout.strip() else {}
            if args.verbose and r.stderr.strip():
                print(f"  [stderr] {r.stderr.strip()[:500]}", flush=True)
        except Exception as e:  # noqa: BLE001
            info = {"error": str(e)}
        ok = ("error" not in info) and os.path.exists(out)
        if ok:
            st = info.get("stats", {})
            print(f"[{idx + 1}/{frames}] {t:%H:%M} alt={info.get('sun_alt')} "
                  f"beam={info.get('beam')} vis={st.get('visible_ratio')} "
                  f"{info.get('ms')}ms", flush=True)
        else:
            print(f"[{idx + 1}/{frames}] {t:%H:%M} 失败: "
                  f"{info.get('error', '未知')}", flush=True)
        entry = {
            "index": idx,
            "time": t.strftime("%Y-%m-%dT%H:%M:%S") + args.tz,
            "file": os.path.basename(out),
            **{k: info.get(k) for k in ("sun_alt", "sun_az", "beam", "source", "ms")},
            "visible_ratio": (info.get("stats") or {}).get("visible_ratio"),
        }
        return entry, ok

    done = 0
    # ── 并行模型：8 线程爬坡 ──────────────────────────────────────
    # 首帧立即起 1 线程；此后每 30 s 补 1 线程直至 8（--jobs）；任何
    # 线程完成立即从队列取下一帧补位（完成的瞬间吞吐不掉）。
    # 用 as_completed 而非 map：map 会等整批提交按序产出，完成后补位
    # 由线程池天然保证；爬坡用 submitted 计数 + 时间窗控制。
    import threading
    import queue as _queue
    from concurrent.futures import ThreadPoolExecutor, as_completed

    task_q = _queue.Queue()
    for item in list(enumerate(points)):
        task_q.put(item)

    ramp_interval = 30.0
    t_start = time.time()
    lock = threading.Lock()
    stats_counter = {"done": 0, "fail": 0}

    def worker():
        while True:
            try:
                idx, t = task_q.get_nowait()
            except _queue.Empty:
                return
            entry, ok = render_one(idx, t)
            with lock:
                stats_counter["done"] += 1
                if not ok:
                    stats_counter["fail"] += 1
                d = stats_counter["done"]
                if d % 60 == 0:
                    el = time.time() - t_start
                    print(f"进度 {d}/{frames} · 已用 {el:.0f}s · "
                          f"均 {el / d:.1f}s/帧", flush=True)
            task_q.task_done()

    def spawn_limited(n):
        """补齐到 n 个存活线程（不超过 --jobs）。"""
        while len(workers) < min(n, jobs):
            th = threading.Thread(target=worker, daemon=True)
            th.start()
            workers.append(th)

    workers = []
    spawn_limited(1)  # 首帧立即启动
    next_ramp = t_start + ramp_interval
    # 主线程负责爬坡与等待；全部任务出队且线程收尾即退出
    while True:
        time.sleep(0.5)
        now = time.time()
        if now >= next_ramp and not task_q.empty():
            spawn_limited(len(workers) + 1)
            next_ramp = now + ramp_interval
        if task_q.empty() and all(not th.is_alive() for th in workers):
            break
    for th in workers:
        th.join(timeout=5)
    fails = stats_counter["fail"]
    timeline.sort(key=lambda e: e["index"])

    with open(os.path.join(args.out_dir, "timeline.json"), "w", encoding="utf-8") as f:
        json.dump({"frames": timeline, "text": args.text,
                   "params": {k: getattr(args, k) for k in
                              ("frames", "fps", "duration", "size", "date", "window",
                               "cloud", "wet_ground", "indoor_light", "city_glow",
                               "absolute_lux", "visibility", "tz", "lat", "lon")}},
                  f, ensure_ascii=False, indent=2)
    with open(os.path.join(args.out_dir, "timeline.tsv"), "w", encoding="utf-8") as f:
        f.write("idx\ttime\talt\tbeam\tvis\tms\n")
        for e in timeline:
            f.write(f"{e['index']}\t{e['time']}\t{e.get('sun_alt')}\t{e.get('beam')}"
                    f"\t{e.get('visible_ratio')}\t{e.get('ms')}\n")

    ok = frames - fails
    print(f"\n完成：{ok}/{frames} 帧成功，失败 {fails} · 总耗时 {time.time() - t0:.0f}s")
    if fails > frames // 3:
        sys.exit(1)


if __name__ == "__main__":
    main()
