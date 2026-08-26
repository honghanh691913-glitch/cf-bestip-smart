#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Simple in-container fixed-time scheduler for cf-bestip-smart."""
from __future__ import annotations
import datetime as dt
import os
import random
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PYTHON = sys.executable
ORCH = ROOT / "bestip_orchestrator.py"
CONFIG = ROOT / "config.json"


def env_bool(name: str, default: bool) -> bool:
    v = os.getenv(name)
    if v is None:
        return default
    return v.strip().lower() in {"1", "true", "yes", "y", "on"}


def parse_hours() -> list[int]:
    raw = os.getenv("SCHEDULE_HOURS", "0,6,12,18")
    out = []
    for part in raw.split(","):
        part = part.strip()
        if not part:
            continue
        h = int(part)
        if not 0 <= h <= 23:
            raise ValueError(f"invalid hour: {h}")
        out.append(h)
    return sorted(set(out)) or [0, 6, 12, 18]


def next_slot(now: dt.datetime, hours: list[int], minute: int) -> dt.datetime:
    for add_day in range(0, 3):
        day = (now + dt.timedelta(days=add_day)).date()
        for h in hours:
            candidate = dt.datetime.combine(day, dt.time(h, minute), tzinfo=now.tzinfo)
            if candidate > now + dt.timedelta(seconds=5):
                return candidate
    raise RuntimeError("cannot calculate next schedule")


def run_once() -> int:
    cmd = [PYTHON, str(ORCH), "--config", str(CONFIG), "--run-now"]
    print("[scheduler] run:", " ".join(cmd), flush=True)
    p = subprocess.run(cmd, cwd=str(ROOT))
    print(f"[scheduler] exit={p.returncode}", flush=True)
    return p.returncode


def main() -> int:
    hours = parse_hours()
    minute = int(os.getenv("SCHEDULE_MINUTE", "5"))
    jitter = max(0, int(os.getenv("RANDOM_DELAY_SECONDS", "120")))
    run_on_start = env_bool("RUN_ON_START", True)
    print(f"[scheduler] hours={hours}, minute={minute:02d}, jitter<= {jitter}s, run_on_start={run_on_start}", flush=True)

    if run_on_start:
        run_once()

    while True:
        now = dt.datetime.now().astimezone()
        target = next_slot(now, hours, minute)
        delay = (target - now).total_seconds()
        print(f"[scheduler] next={target.isoformat(timespec='seconds')} sleep={int(delay)}s", flush=True)
        time.sleep(max(1, delay))
        if jitter:
            j = random.randint(0, jitter)
            print(f"[scheduler] randomized delay={j}s", flush=True)
            time.sleep(j)
        run_once()


if __name__ == "__main__":
    raise SystemExit(main())
