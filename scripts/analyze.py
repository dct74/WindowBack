#!/usr/bin/env python3
"""把 monitor.log（JSONL）整理成能读的观测报告。

用法:
    python3 scripts/analyze.py                 # 最近一天
    python3 scripts/analyze.py --all
    python3 scripts/analyze.py --ghosts-only
"""
import argparse
import json
import os
from datetime import datetime, timedelta

LOG = os.path.expanduser("~/Library/Logs/WindowBack/monitor.log")


def load(path):
    rows = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows


def ts(row):
    return datetime.fromisoformat(row["t"].replace("Z", "+00:00"))


def fmt_frame(w):
    return f"{w['w']:.0f}x{w['h']:.0f} @ {w['x']:.0f},{w['y']:.0f}"


def fmt_screens(screens):
    if not screens:
        return "无"
    return " + ".join(
        f"{'内' if s['builtin'] else '外'}{s['w']:.0f}x{s['h']:.0f}"
        f"@{s['x']:.0f},{s['y']:.0f}{'(睡眠)' if s['asleep'] else ''}"
        for s in screens
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--all", action="store_true", help="不限时间")
    ap.add_argument("--hours", type=float, default=24)
    ap.add_argument("--ghosts-only", action="store_true")
    args = ap.parse_args()

    rows = load(LOG)
    if not rows:
        print(f"没有日志: {LOG}")
        return

    if not args.all:
        cutoff = datetime.now().astimezone() - timedelta(hours=args.hours)
        rows = [r for r in rows if ts(r) >= cutoff]

    events = [r for r in rows if r["kind"] == "display" and r["topologyChanged"]]
    snapshots = [r for r in rows if r["kind"] == "snapshot"]

    print(f"日志: {LOG}")
    print(f"行数: {len(rows)}  拓扑事件: {len(events)}  快照: {len(snapshots)}\n")

    if not events:
        print("没有拓扑变化事件。确认 WindowBack 在变化期间一直运行。\n")

    for i, ev in enumerate(events):
        print(f"[{i + 1}] {ts(ev).astimezone():%Y-%m-%d %H:%M:%S}  "
              f"{', '.join(ev['flags'])}")
        print(f"    前: {fmt_screens(ev['previous'])}")
        print(f"    后: {fmt_screens(ev['current'])}"
              f"{'   ← 外屏→仅内屏' if ev.get('nowBuiltinOnly') else ''}")

        event_time = ts(ev)
        before = [s for s in snapshots if ts(s) < event_time]
        after = [s for s in snapshots if ts(s) >= event_time]
        if before:
            print(f"    变化前快照: {len(before[-1]['windows'])} 个窗口, "
                  f"{ts(before[-1]).astimezone():%H:%M:%S}")
        ghost_seen = {}
        for snap in after[:40]:
            for w in snap["windows"]:
                if w["offscreen"]:
                    key = (w["app"], w["title"])
                    ghost_seen.setdefault(key, (snap, w))
        if ghost_seen and not args.ghosts_only:
            print("    屏外窗口:")
            for (app, title), (snap, w) in ghost_seen.items():
                print(f"      {app} / {title or '(无标题)'}  {fmt_frame(w)}  "
                      f"可见 {w['visibleRatio']:.0%}  [来源 {w.get('source', '?')}]")
        if not ghost_seen:
            print("    屏外窗口: 无")
        print()

    latest = snapshots[-1] if snapshots else None
    if latest:
        ghosts = [w for w in latest["windows"] if w["offscreen"]]
        print(f"最近一次快照: {ts(latest).astimezone():%Y-%m-%d %H:%M:%S}  "
              f"窗口 {len(latest['windows'])}  屏外 {len(ghosts)}  "
              f"AX={'是' if latest.get('axTrusted') else '否'}")
        for w in ghosts:
            print(f"  {w['app']} / {w['title'] or '(无标题)'}  {fmt_frame(w)}")


if __name__ == "__main__":
    main()
