#!/usr/bin/env python3
from __future__ import annotations
import json
import os
import time
from pathlib import Path
import ipaddress

ROOT = Path(__file__).resolve().parent
try:
    cfg = json.loads((ROOT / "config.json").read_text(encoding="utf-8"))
    cfst = ROOT / "cfst"
    if not (cfst.exists() and os.access(cfst, os.X_OK)):
        raise RuntimeError("cfst missing")
    files = cfg.get("range_files", {"ipv4":"ranges/ipv4.txt","ipv6":"ranges/ipv6.txt"})
    for fam, ver in (("ipv4", 4), ("ipv6", 6)):
        path = Path(files.get(fam, f"ranges/{fam}.txt"))
        if not path.is_absolute():
            path = ROOT / path
        count = 0
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            net = ipaddress.ip_network(line, strict=False)
            if net.version != ver:
                raise RuntimeError(f"wrong family in {path}: {line}")
            count += 1
        if count == 0:
            raise RuntimeError(f"empty range file: {path}")
    last = ROOT / "runtime" / "last-success.json"
    if last.exists():
        json.loads(last.read_text(encoding="utf-8"))
        age = time.time() - last.stat().st_mtime
        if age > 18 * 3600:
            raise RuntimeError(f"last success too old: {int(age/3600)}h")
    print("healthy")
except Exception as e:
    print(f"unhealthy: {e}")
    raise SystemExit(1)
