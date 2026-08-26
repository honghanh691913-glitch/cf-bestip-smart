#!/usr/bin/env python3
from __future__ import annotations
import ipaddress
import json
import os
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent

def resolve(value: str) -> Path:
    p = Path(value)
    return p if p.is_absolute() else ROOT / p

try:
    cfg = json.loads((ROOT / "config.json").read_text(encoding="utf-8"))
    if str(cfg.get("candidate_source", "file_only")).lower() != "file_only":
        raise RuntimeError("candidate_source must be file_only")

    cfst = ROOT / "cfst"
    if not (cfst.exists() and os.access(cfst, os.X_OK)):
        raise RuntimeError("cfst missing")

    enabled = 0
    for pool_name, pool in cfg.get("pools", {}).items():
        if not bool(pool.get("enabled", True)):
            continue
        enabled += 1
        for fam, ver in (("ipv4", 4), ("ipv6", 6)):
            fam_cfg = pool.get(fam, {})
            if str(fam_cfg.get("source", "file")).lower() != "file":
                raise RuntimeError(f"{pool_name}/{fam}: source must be file")
            value = fam_cfg.get("file")
            if not value:
                raise RuntimeError(f"{pool_name}/{fam}: missing file")
            path = resolve(str(value))
            if not path.is_file():
                raise RuntimeError(f"missing range file: {path}")
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

    if enabled == 0:
        raise RuntimeError("no enabled pool")

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
