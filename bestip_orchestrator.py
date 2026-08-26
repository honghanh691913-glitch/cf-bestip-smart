#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Cloudflare BestIP Smart Orchestrator v1.3.0

A thin orchestration/publishing layer around XIU2/CloudflareSpeedTest.
- Candidate CIDRs are file-only: NRT/WEST IPv4/IPv6 TXT files.
- No official-range fallback and no hidden full-range scan.
- Per-CIDR split/random probing: 4 IPs x up to 3 rounds.
- Builds an eligible candidate pool (default 255) per pool/family.
- Final benchmarks up to 200 candidates and selects Top N (default 5).
- Colo-aware include/exclude filtering.
- IPv4/IPv6 output, GitHub atomic publish, worker-friendly files.

Python stdlib only.
"""
from __future__ import annotations

import argparse
import base64
import csv
import fcntl
import datetime as dt
import hashlib
import ipaddress
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple

VERSION = "1.3.0"
UA = f"cf-bestip-smart/{VERSION}"
ROOT = Path(__file__).resolve().parent

DEFAULT_COLO_LABELS = {
    "NRT": "Tokyo / 东京", "KIX": "Osaka / 大阪", "HKG": "Hong Kong / 香港",
    "ICN": "Seoul / 首尔", "TPE": "Taipei / 台北", "SIN": "Singapore / 新加坡",
    "BKK": "Bangkok / 曼谷", "MNL": "Manila / 马尼拉", "KUL": "Kuala Lumpur / 吉隆坡",
    "CGK": "Jakarta / 雅加达", "SGN": "Ho Chi Minh City / 胡志明市", "HAN": "Hanoi / 河内",
    "BOM": "Mumbai / 孟买", "DEL": "Delhi / 德里", "MAA": "Chennai / 金奈",
    "BLR": "Bengaluru / 班加罗尔", "SYD": "Sydney / 悉尼", "MEL": "Melbourne / 墨尔本",
    "BNE": "Brisbane / 布里斯班", "AKL": "Auckland / 奥克兰", "GUM": "Guam / 关岛",
    "LAX": "Los Angeles / 洛杉矶", "SJC": "San Jose / 圣何塞", "SEA": "Seattle / 西雅图",
    "PHX": "Phoenix / 凤凰城", "LAS": "Las Vegas / 拉斯维加斯", "PDX": "Portland / 波特兰",
    "DEN": "Denver / 丹佛", "SLC": "Salt Lake City / 盐湖城", "SAN": "San Diego / 圣迭戈",
    "DFW": "Dallas / 达拉斯", "IAH": "Houston / 休斯敦", "ORD": "Chicago / 芝加哥",
    "MSP": "Minneapolis / 明尼阿波利斯", "MCI": "Kansas City / 堪萨斯城",
    "IAD": "Washington DC / 华盛顿", "EWR": "Newark-New York / 纽约都会区",
    "JFK": "New York / 纽约", "BOS": "Boston / 波士顿", "ATL": "Atlanta / 亚特兰大",
    "MIA": "Miami / 迈阿密", "YYZ": "Toronto / 多伦多", "YVR": "Vancouver / 温哥华",
}

DEFAULT_COLO_GROUPS = {
    "apac": ["NRT", "KIX", "HKG", "ICN", "TPE", "SIN", "BKK", "MNL", "KUL", "CGK", "SGN", "HAN", "BOM", "DEL", "MAA", "BLR", "SYD", "MEL", "BNE", "AKL", "GUM"],
    "us_west": ["LAX", "SJC", "SEA", "PHX", "LAS", "PDX", "DEN", "SLC", "SAN"],
    "us_central": ["DFW", "IAH", "ORD", "MSP", "MCI"],
    "us_east": ["IAD", "EWR", "JFK", "BOS", "ATL", "MIA"],
}


class ConfigError(RuntimeError):
    pass


@dataclass
class Result:
    ip: str
    sent: int = 0
    received: int = 0
    loss: float = 1.0
    latency_ms: float = 99999.0
    speed_mbps: float = 0.0
    colo: str = ""
    cidr: str = ""
    family: str = ""
    pool: str = ""
    city: str = ""
    score: float = 0.0


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).astimezone().isoformat(timespec="seconds")


def load_json(path: Path) -> Dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as e:
        raise ConfigError(f"读取配置失败 {path}: {e}")


def save_json(path: Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def load_cidr_file(path_value: str, family: str) -> List[str]:
    path = Path(path_value)
    if not path.is_absolute():
        path = ROOT / path
    if not path.exists():
        raise ConfigError(f"CIDR 文件不存在: {path}")
    want_ver = 4 if family == "ipv4" else 6
    out: List[str] = []
    seen: Set[str] = set()
    for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        try:
            net = ipaddress.ip_network(line, strict=False)
        except Exception as e:
            raise ConfigError(f"CIDR 文件 {path}:{line_no} 无效: {line} ({e})")
        if net.version != want_ver:
            raise ConfigError(f"CIDR 文件 {path}:{line_no} 地址族错误: {line}")
        text = str(net)
        if text not in seen:
            seen.add(text)
            out.append(text)
    if not out:
        raise ConfigError(f"CIDR 文件为空: {path}")
    return out


def expand_groups(names: Sequence[str], groups: Dict[str, List[str]]) -> Set[str]:
    out: Set[str] = set()
    for name in names or []:
        out.update(x.upper() for x in groups.get(name, []))
    return out


def pool_colos(pool_cfg: Dict[str, Any], cfg: Dict[str, Any]) -> Tuple[Set[str], Set[str]]:
    groups = dict(DEFAULT_COLO_GROUPS)
    groups.update(cfg.get("colo_groups", {}))
    include = {x.upper() for x in pool_cfg.get("include_colos", [])}
    include |= expand_groups(pool_cfg.get("include_colo_groups", []), groups)
    exclude = {x.upper() for x in pool_cfg.get("exclude_colos", [])}
    exclude |= expand_groups(pool_cfg.get("exclude_colo_groups", []), groups)
    return include, exclude


def colo_eligible(colo: str, pool_cfg: Dict[str, Any], cfg: Dict[str, Any]) -> bool:
    c = (colo or "").upper()
    include, exclude = pool_colos(pool_cfg, cfg)
    if not c:
        return bool(pool_cfg.get("allow_unknown_colo", False)) and not include
    if c in exclude:
        return False
    if include and c not in include:
        return False
    return True


def cidrs_for(pool_cfg: Dict[str, Any], family: str, cfg: Dict[str, Any]) -> List[str]:
    """Return CIDRs for one pool/family.

    v1.3.0 deliberately supports file-only candidate sources.  This prevents a
    missing/empty regional file from silently falling back to Cloudflare's
    global ranges and turning a targeted test into a full-range scan.
    """
    fam = pool_cfg.get(family, {})
    source = str(fam.get("source", "file")).strip().lower()
    if source != "file":
        raise ConfigError(
            f"{pool_cfg.get('label', 'pool')}/{family} source={source!r} 不允许；"
            "最终版只允许 source=file，禁止官方全集回退"
        )

    default_file = cfg.get("range_files", {}).get(family, f"ranges/{family}.txt")
    file_value = str(fam.get("file") or default_file).strip()
    if not file_value:
        raise ConfigError(f"{pool_cfg.get('label', 'pool')}/{family} 未配置 CIDR 文件")

    ranges = load_cidr_file(file_value, family)
    out: List[str] = []
    seen: Set[str] = set()
    want_ver = 4 if family == "ipv4" else 6
    for raw in ranges:
        net = ipaddress.ip_network(raw, strict=False)
        if net.version != want_ver:
            raise ConfigError(f"{family} 配置中出现错误地址族: {raw}")
        text = str(net)
        if text not in seen:
            seen.add(text)
            out.append(text)
    return out

def random_ip_from_net(net: ipaddress._BaseNetwork, rng: random.Random, tried: Set[str]) -> Optional[str]:
    lo = int(net.network_address)
    hi = int(net.broadcast_address)
    if net.version == 4 and net.num_addresses > 2 and net.prefixlen <= 30:
        lo += 1
        hi -= 1
    if lo > hi:
        return None
    span = hi - lo + 1
    attempts = min(100, max(10, span if span < 100 else 100))
    for _ in range(attempts):
        val = lo + rng.randrange(span)
        ip = str(ipaddress.ip_address(val))
        if ip not in tried:
            tried.add(ip)
            return ip
    if span <= 4096:
        start = rng.randrange(span)
        for off in range(span):
            ip = str(ipaddress.ip_address(lo + ((start + off) % span)))
            if ip not in tried:
                tried.add(ip)
                return ip
    return None


def sample_from_net(net: ipaddress._BaseNetwork, n: int, rng: random.Random, tried: Set[str]) -> List[str]:
    out = []
    for _ in range(n):
        ip = random_ip_from_net(net, rng, tried)
        if not ip:
            break
        out.append(ip)
    return out


def parse_loss(v: str) -> float:
    s = (v or "").strip().replace("%", "")
    try:
        x = float(s)
    except Exception:
        return 1.0
    if "%" in (v or "") or x > 1.0:
        x /= 100.0
    return max(0.0, min(1.0, x))


def parse_float(v: str, default: float = 0.0) -> float:
    try:
        return float(str(v).strip())
    except Exception:
        return default


def parse_int(v: str, default: int = 0) -> int:
    try:
        return int(float(str(v).strip()))
    except Exception:
        return default


def parse_cfst_csv(path: Path) -> List[Result]:
    if not path.exists() or path.stat().st_size == 0:
        return []
    rows: List[Result] = []
    with path.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.reader(f)
        all_rows = list(reader)
    if not all_rows:
        return []
    # CFST canonical order: IP, sent, recv, loss, latency, speed, colo
    start = 1 if all_rows and all_rows[0] and ("IP" in all_rows[0][0].upper() or "地址" in all_rows[0][0]) else 0
    for row in all_rows[start:]:
        if len(row) < 5:
            continue
        ip = row[0].strip().strip("[]")
        try:
            ipaddress.ip_address(ip)
        except Exception:
            continue
        rows.append(Result(
            ip=ip,
            sent=parse_int(row[1] if len(row) > 1 else "0"),
            received=parse_int(row[2] if len(row) > 2 else "0"),
            loss=parse_loss(row[3] if len(row) > 3 else "1"),
            latency_ms=parse_float(row[4] if len(row) > 4 else "99999", 99999.0),
            speed_mbps=parse_float(row[5] if len(row) > 5 else "0", 0.0),
            colo=(row[6].strip().upper() if len(row) > 6 else ""),
        ))
    return rows


def cfst_binary(cfg: Dict[str, Any]) -> str:
    p = cfg.get("cfst", {}).get("binary", "./cfst")
    path = Path(p)
    if not path.is_absolute():
        path = ROOT / path
    if not path.exists():
        raise ConfigError(f"找不到 CFST: {path}。先运行 ./install.sh 或配置 cfst.binary")
    return str(path)


def run_cfst(ips: Sequence[str], cfg: Dict[str, Any], final: bool, workdir: Path, tag: str) -> List[Result]:
    if not ips:
        return []
    c = cfg.get("cfst", {})
    cand = workdir / f"{tag}.txt"
    out = workdir / f"{tag}.csv"
    cand.write_text("\n".join(ips) + "\n", encoding="utf-8")
    cmd = [
        cfst_binary(cfg), "-f", str(cand), "-o", str(out), "-p", "0",
        "-httping", "-url", str(c.get("test_url", "https://speed.cloudflare.com/__down?bytes=100000000")),
        "-tp", str(int(c.get("port", 443))),
        "-n", str(int(c.get("threads", 200))),
        "-t", str(int(c.get("ping_count_final" if final else "ping_count_quick", 6 if final else 4))),
        "-tl", str(float(c.get("latency_max_ms", 350))),
        "-tlr", str(float(c.get("packet_loss_max", 0.20))),
    ]
    if final:
        cmd += ["-dn", str(min(len(ips), int(c.get("final_download_candidates", 200)))),
                "-dt", str(int(c.get("download_seconds", 5)))]
    else:
        cmd += ["-dd"]
    if bool(c.get("debug", False)):
        cmd += ["-debug"]
    env = os.environ.copy()
    # Prevent accidental local proxy pollution unless user explicitly opts in.
    if c.get("clear_proxy_env", True):
        for key in list(env):
            if key.lower() in {"http_proxy", "https_proxy", "all_proxy", "no_proxy"}:
                env.pop(key, None)
    timeout = int(c.get("process_timeout_seconds", 1800 if final else 600))
    print("[CFST]", " ".join(cmd))
    try:
        p = subprocess.run(cmd, cwd=str(ROOT), env=env, stdout=None, stderr=None, timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f"[WARN] CFST 超时: {tag}")
        return []
    if p.returncode != 0:
        print(f"[WARN] CFST 返回码 {p.returncode}: {tag}")
    return parse_cfst_csv(out)


def attach_meta(results: Iterable[Result], owner: Dict[str, str], pool: str, family: str, cfg: Dict[str, Any]) -> List[Result]:
    labels = dict(DEFAULT_COLO_LABELS)
    labels.update(cfg.get("colo_labels", {}))
    out = []
    for r in results:
        r.cidr = owner.get(r.ip, "")
        r.pool = pool
        r.family = family
        r.city = labels.get(r.colo, r.colo or "Unknown")
        out.append(r)
    return out


def passes_thresholds(r: Result, cfg: Dict[str, Any]) -> bool:
    c = cfg.get("cfst", {})
    if r.loss > float(c.get("packet_loss_max", 0.20)):
        return False
    if r.latency_ms > float(c.get("latency_max_ms", 350)):
        return False
    return True


def rank_results(results: Sequence[Result], cfg: Dict[str, Any]) -> List[Result]:
    c = cfg.get("selection", {})
    speed_floor = float(c.get("min_speed_mbps", 0.0))
    valid = [r for r in results if passes_thresholds(r, cfg) and r.speed_mbps >= speed_floor]
    # Stability first, then throughput, then latency. Score is display-only.
    for r in valid:
        r.score = round((r.speed_mbps * 2.0) - (r.latency_ms / 25.0) - (r.loss * 100.0), 3)
    valid.sort(key=lambda r: (r.loss, -r.speed_mbps, r.latency_ms, r.ip))
    return valid


def discover_candidates(pool_name: str, family: str, pool_cfg: Dict[str, Any], cfg: Dict[str, Any], workdir: Path, rng: random.Random) -> Tuple[List[Result], Dict[str, Any]]:
    discovery = cfg.get("discovery", {})
    target = int(discovery.get("candidate_target", 255))
    probe_n = int(discovery.get("probe_per_segment", 4))
    probe_rounds = int(discovery.get("probe_rounds", 3))
    fill_n = int(discovery.get("fill_per_active_segment", 8))
    max_fill_rounds = int(discovery.get("max_fill_rounds", 100))

    cidrs = cidrs_for(pool_cfg, family, cfg)
    nets = [ipaddress.ip_network(x, strict=False) for x in cidrs]
    tried: Dict[str, Set[str]] = {str(n): set() for n in nets}
    global_tried: Set[str] = set()
    active: Set[str] = set()
    pending: Set[str] = {str(n) for n in nets}
    collected: Dict[str, Result] = {}
    segment_stats: Dict[str, Dict[str, Any]] = {str(n): {"active": False, "attempted": 0, "eligible": 0} for n in nets}

    # Admission: each CIDR gets 4 random samples per round, at most 3 rounds.
    for round_no in range(1, probe_rounds + 1):
        if not pending:
            break
        candidates: List[str] = []
        owner: Dict[str, str] = {}
        for cidr in sorted(pending):
            net = ipaddress.ip_network(cidr, strict=False)
            raw_picks = sample_from_net(net, probe_n * 3, rng, tried[cidr])
            picks = []
            for ip in raw_picks:
                if ip in global_tried:
                    continue
                global_tried.add(ip)
                picks.append(ip)
                if len(picks) >= probe_n:
                    break
            segment_stats[cidr]["attempted"] += len(picks)
            for ip in picks:
                candidates.append(ip)
                owner[ip] = cidr
        if not candidates:
            break
        results = attach_meta(run_cfst(candidates, cfg, False, workdir, f"{pool_name}-{family}-admit-{round_no}"), owner, pool_name, family, cfg)
        success_this: Set[str] = set()
        for r in results:
            if passes_thresholds(r, cfg) and colo_eligible(r.colo, pool_cfg, cfg):
                collected[r.ip] = r
                success_this.add(r.cidr)
                segment_stats[r.cidr]["eligible"] += 1
        for cidr in success_this:
            active.add(cidr)
            segment_stats[cidr]["active"] = True
        pending -= success_this
        print(f"[{pool_name}/{family}] 段探测 {round_no}/{probe_rounds}: 活跃段={len(active)}, 待确认段={len(pending)}, 合格IP={len(collected)}")

    # Any CIDR that failed all admission rounds is dropped here.
    if not active:
        return [], {"cidrs": cidrs, "cidr_count": len(cidrs), "segments": segment_stats, "active_segments": 0, "candidate_count": 0}

    # Fill candidate pool from active CIDRs only. Non-eligible colo never counts toward target.
    fill_round = 0
    while len(collected) < target and fill_round < max_fill_rounds:
        fill_round += 1
        candidates = []
        owner = {}
        for cidr in sorted(active):
            net = ipaddress.ip_network(cidr, strict=False)
            raw_picks = sample_from_net(net, fill_n * 3, rng, tried[cidr])
            picks = []
            for ip in raw_picks:
                if ip in global_tried:
                    continue
                global_tried.add(ip)
                picks.append(ip)
                if len(picks) >= fill_n:
                    break
            segment_stats[cidr]["attempted"] += len(picks)
            for ip in picks:
                candidates.append(ip)
                owner[ip] = cidr
        if not candidates:
            break
        results = attach_meta(run_cfst(candidates, cfg, False, workdir, f"{pool_name}-{family}-fill-{fill_round}"), owner, pool_name, family, cfg)
        before = len(collected)
        for r in results:
            if passes_thresholds(r, cfg) and colo_eligible(r.colo, pool_cfg, cfg):
                collected[r.ip] = r
                segment_stats[r.cidr]["eligible"] += 1
                if len(collected) >= target:
                    break
        print(f"[{pool_name}/{family}] 补池 {fill_round}: +{len(collected)-before}, {len(collected)}/{target}")
        # Avoid hammering endpoints if no new candidate is found repeatedly.
        if len(collected) == before and fill_round % 5 == 0:
            time.sleep(float(discovery.get("backoff_seconds", 1.0)))

    quick_rank = sorted(collected.values(), key=lambda r: (r.loss, r.latency_ms, r.ip))
    return quick_rank[:target], {
        "cidrs": cidrs,
        "cidr_count": len(cidrs),
        "segments": segment_stats,
        "active_segments": len(active),
        "candidate_count": min(len(quick_rank), target),
        "target": target,
        "fill_rounds": fill_round,
    }


def final_benchmark(pool_name: str, family: str, pool_cfg: Dict[str, Any], candidates: Sequence[Result], cfg: Dict[str, Any], workdir: Path) -> List[Result]:
    max_n = int(cfg.get("cfst", {}).get("final_download_candidates", 200))
    selected = list(candidates[:max_n])
    owner = {r.ip: r.cidr for r in candidates}
    results = attach_meta(run_cfst([r.ip for r in selected], cfg, True, workdir, f"{pool_name}-{family}-final"), owner, pool_name, family, cfg)
    eligible = [r for r in results if colo_eligible(r.colo, pool_cfg, cfg)]
    ranked = rank_results(eligible, cfg)

    top_n = int(cfg.get("selection", {}).get("top_n", 5))
    if len(ranked) < top_n and len(candidates) > max_n:
        # Fallback tranche if the first 200 were insufficient after final colo/quality filtering.
        rest = list(candidates[max_n:])
        extra = attach_meta(run_cfst([r.ip for r in rest], cfg, True, workdir, f"{pool_name}-{family}-final-extra"), owner, pool_name, family, cfg)
        extra = [r for r in extra if colo_eligible(r.colo, pool_cfg, cfg)]
        ranked = rank_results(ranked + extra, cfg)
    return ranked


def txt_line(r: Result, port: int) -> str:
    host = f"[{r.ip}]" if ":" in r.ip else r.ip
    tag_speed = f"{r.speed_mbps:.2f}MBps"
    return f"{host}:{port}#{r.pool.upper()}-{r.colo or 'UNK'}-{tag_speed}"


def csv_text(results: Sequence[Result], updated_at: str, port: int) -> str:
    import io
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(["IP", "Port", "IPVersion", "Pool", "Colo", "City", "CIDR", "PacketLoss", "LatencyMs", "SpeedMBps", "Score", "UpdatedAt"])
    for r in results:
        w.writerow([r.ip, port, 6 if ":" in r.ip else 4, r.pool, r.colo, r.city, r.cidr, f"{r.loss:.4f}", f"{r.latency_ms:.2f}", f"{r.speed_mbps:.2f}", f"{r.score:.3f}", updated_at])
    return buf.getvalue()


def build_outputs(all_ranked: Dict[Tuple[str, str], List[Result]], meta: Dict[str, Any], cfg: Dict[str, Any], updated_at: str) -> Dict[str, bytes]:
    port = int(cfg.get("cfst", {}).get("port", 443))
    top_n = int(cfg.get("selection", {}).get("top_n", 5))
    files: Dict[str, bytes] = {}
    all_top: List[Result] = []
    for pool in ["apac", "west"]:
        for family in ["ipv4", "ipv6"]:
            ranked = all_ranked.get((pool, family), [])
            top = ranked[:top_n]
            all_top.extend(top)
            base = f"output/{pool}/{family}"
            files[f"{base}.txt"] = (("\n".join(txt_line(r, port) for r in top) + "\n") if top else "").encode()
            files[f"{base}.csv"] = csv_text(top, updated_at, port).encode()
            files[f"{base}-pool.csv"] = csv_text(ranked, updated_at, port).encode()

    files["output/all/best20.txt"] = (("\n".join(txt_line(r, port) for r in all_top) + "\n") if all_top else "").encode()
    files["output/all/best20.csv"] = csv_text(all_top, updated_at, port).encode()
    status = {
        "ok": True,
        "project": "cf-bestip-smart",
        "version": VERSION,
        "updated_at": updated_at,
        "selection": {"top_n_each": top_n, "total": len(all_top), "port": port},
        "candidate_source": "file_only",
        "pools": meta,
    }
    files["status.json"] = (json.dumps(status, ensure_ascii=False, indent=2) + "\n").encode()
    return files


def write_local_outputs(files: Dict[str, bytes], root: Path) -> None:
    for rel, data in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)


def gh_request(method: str, url: str, token: str, data: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    body = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(url, data=body, method=method, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": UA,
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"GitHub API {method} {url} -> {e.code}: {detail[:800]}")


def github_atomic_publish(files: Dict[str, bytes], cfg: Dict[str, Any], message: str) -> str:
    gh = cfg.get("github", {})
    owner = os.environ.get("GITHUB_OWNER", gh.get("owner", "")).strip()
    repo = os.environ.get("GITHUB_REPO", gh.get("repo", "")).strip()
    branch = os.environ.get("GITHUB_BRANCH", gh.get("branch", "main")).strip() or "main"
    token_env = gh.get("token_env", "GITHUB_TOKEN")
    token = os.environ.get(token_env, "").strip()
    if not owner or not repo:
        raise ConfigError("github.owner / github.repo 未配置")
    if not token:
        raise ConfigError(f"环境变量 {token_env} 未设置")
    api = "https://api.github.com"

    ref = gh_request("GET", f"{api}/repos/{owner}/{repo}/git/ref/heads/{urllib.parse.quote(branch, safe='')}", token)
    parent_sha = ref["object"]["sha"]
    commit = gh_request("GET", f"{api}/repos/{owner}/{repo}/git/commits/{parent_sha}", token)
    base_tree = commit["tree"]["sha"]

    entries = []
    for path, content in sorted(files.items()):
        blob = gh_request("POST", f"{api}/repos/{owner}/{repo}/git/blobs", token, {
            "content": base64.b64encode(content).decode(), "encoding": "base64"
        })
        entries.append({"path": path, "mode": "100644", "type": "blob", "sha": blob["sha"]})

    tree = gh_request("POST", f"{api}/repos/{owner}/{repo}/git/trees", token, {"base_tree": base_tree, "tree": entries})
    if tree.get("sha") == base_tree:
        print("[INFO] GitHub 结果与上一版完全一致，不创建重复 commit")
        return parent_sha
    new_commit = gh_request("POST", f"{api}/repos/{owner}/{repo}/git/commits", token, {
        "message": message, "tree": tree["sha"], "parents": [parent_sha]
    })
    gh_request("PATCH", f"{api}/repos/{owner}/{repo}/git/refs/heads/{urllib.parse.quote(branch, safe='')}", token, {
        "sha": new_commit["sha"], "force": False
    })
    return new_commit["sha"]


def validate_config(cfg: Dict[str, Any]) -> None:
    if str(cfg.get("candidate_source", "file_only")).strip().lower() != "file_only":
        raise ConfigError("candidate_source 必须为 file_only；最终版禁止官方全集回退")
    for name in ["apac", "west"]:
        if name not in cfg.get("pools", {}):
            raise ConfigError(f"缺少 pools.{name}")
    # 预先验证所有启用池的 CIDR 来源，避免跑到一半才发现文件错误。
    for name in ["apac", "west"]:
        pcfg = cfg["pools"][name]
        if not bool(pcfg.get("enabled", True)):
            continue
        for family in ["ipv4", "ipv6"]:
            cidrs_for(pcfg, family, cfg)
    top_n = int(cfg.get("selection", {}).get("top_n", 5))
    target = int(cfg.get("discovery", {}).get("candidate_target", 255))
    final_n = int(cfg.get("cfst", {}).get("final_download_candidates", 200))
    if top_n < 1 or target < top_n or final_n < top_n:
        raise ConfigError("top_n / candidate_target / final_download_candidates 配置不合理")


def run_once(cfg: Dict[str, Any], dry_run: bool = False) -> int:
    validate_config(cfg)
    seed = cfg.get("discovery", {}).get("random_seed")
    rng = random.Random(seed if seed not in (None, "") else int.from_bytes(os.urandom(16), "big"))
    updated_at = now_iso()
    ranked_map: Dict[Tuple[str, str], List[Result]] = {}
    meta: Dict[str, Any] = {}
    top_n = int(cfg.get("selection", {}).get("top_n", 5))
    require_all = bool(cfg.get("publish", {}).get("require_all_pools", True))

    runtime_root = ROOT / "runtime"
    runtime_root.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="bestip-", dir=str(runtime_root)) as td:
        workdir = Path(td)
        enabled_pools = [p for p in ["apac", "west"] if bool(cfg["pools"][p].get("enabled", True))]
        for pool_name in enabled_pools:
            pool_cfg = cfg["pools"][pool_name]
            meta[pool_name] = {}
            for family in ["ipv4", "ipv6"]:
                print(f"\n=== {pool_name.upper()} / {family.upper()} ===")
                candidates, dmeta = discover_candidates(pool_name, family, pool_cfg, cfg, workdir, rng)
                ranked = final_benchmark(pool_name, family, pool_cfg, candidates, cfg, workdir) if candidates else []
                ranked_map[(pool_name, family)] = ranked
                meta[pool_name][family] = {
                    **dmeta,
                    "final_eligible": len(ranked),
                    "published": min(len(ranked), top_n),
                    "top_colos": [r.colo for r in ranked[:top_n]],
                }
                print(f"[{pool_name}/{family}] 最终合格={len(ranked)}，Top={min(len(ranked), top_n)}")

        missing = [(p, f) for p in enabled_pools for f in ["ipv4", "ipv6"] if len(ranked_map.get((p, f), [])) < top_n]
        if missing and require_all:
            print("\n[ABORT] 以下池不足 Top N，本轮不发布，GitHub 保留上一版:")
            for p, f in missing:
                print(f"  - {p}/{f}: {len(ranked_map.get((p, f), []))}/{top_n}")
            failure = {"ok": False, "version": VERSION, "updated_at": updated_at, "reason": "insufficient_results", "missing": missing, "pools": meta}
            save_json(ROOT / "runtime" / "last-failure.json", failure)
            return 2

        files = build_outputs(ranked_map, meta, cfg, updated_at)
        stage = ROOT / "generated"
        stage.mkdir(parents=True, exist_ok=True)
        # generated may be a Docker bind mount: clear children, never delete mount root.
        for child in list(stage.iterdir()):
            if child.is_dir() and not child.is_symlink():
                shutil.rmtree(child)
            else:
                child.unlink(missing_ok=True)
        write_local_outputs(files, stage)
        print(f"\n[OK] 本地结果已生成: {stage}")

        gh_cfg = cfg.get("github", {})
        published = False
        commit_sha = ""
        publish_env = os.environ.get("GITHUB_PUBLISH_ENABLED")
        if publish_env is None:
            github_enabled = bool(gh_cfg.get("enabled", False))
        else:
            github_enabled = publish_env.strip().lower() in {"1", "true", "yes", "y", "on"}
        if dry_run or not github_enabled:
            print("[INFO] 未发布 GitHub（dry-run 或 GitHub 发布未启用）")
        else:
            token_env = gh_cfg.get("token_env", "GITHUB_TOKEN")
            if not os.environ.get(token_env, "").strip() and bool(gh_cfg.get("skip_if_token_missing", True)):
                print(f"[WARN] {token_env} 未设置：本地结果已生成，本轮跳过 GitHub 发布")
            else:
                commit_sha = github_atomic_publish(files, cfg, f"BestIP auto update {updated_at}")
                published = True
                print(f"[OK] GitHub 原子提交完成: {commit_sha}")
        save_json(ROOT / "runtime" / "last-success.json", {
            "ok": True, "version": VERSION, "updated_at": updated_at,
            "published": published, "commit": commit_sha, "file_count": len(files)
        })
        return 0


def self_test() -> int:
    assert parse_loss("0.05") == 0.05
    assert abs(parse_loss("5%") - 0.05) < 1e-9
    r4 = Result(ip="104.16.1.1", speed_mbps=12.3, pool="apac", colo="NRT")
    r6 = Result(ip="2606:4700::1", speed_mbps=12.3, pool="west", colo="LAX")
    assert txt_line(r4, 443).startswith("104.16.1.1:443#")
    assert txt_line(r6, 443).startswith("[2606:4700::1]:443#")
    cfg = {"colo_groups": DEFAULT_COLO_GROUPS}
    assert colo_eligible("NRT", {"include_colos": ["NRT"]}, cfg)
    assert not colo_eligible("HKG", {"include_colos": ["NRT"]}, cfg)
    assert not colo_eligible("NRT", {"exclude_colo_groups": ["apac"]}, cfg)
    rng = random.Random(1)
    tried: Set[str] = set()
    ips = sample_from_net(ipaddress.ip_network("192.0.2.0/24"), 255, rng, tried)
    assert len(ips) == 254  # network/broadcast excluded
    tried6: Set[str] = set()
    ips6 = sample_from_net(ipaddress.ip_network("2001:db8::/120"), 255, rng, tried6)
    assert len(ips6) == 255
    print("self-test: PASS")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Cloudflare BestIP Orchestrator")
    ap.add_argument("--config", default=str(ROOT / "config.json"))
    ap.add_argument("--dry-run", action="store_true", help="测速并生成本地文件，但不发布 GitHub")
    ap.add_argument("--run-now", action="store_true", help="兼容快捷命令；立即运行一轮（默认行为本来就是立即运行）")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--version", action="store_true")
    ap.add_argument("--lock-file", default=os.environ.get("BESTIP_LOCK_FILE", "/tmp/cf-bestip-smart.lock"))
    args = ap.parse_args()
    if args.version:
        print(VERSION)
        return 0
    if args.self_test:
        return self_test()
    try:
        lock_path = Path(args.lock_file)
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        with lock_path.open("a+") as lock_fp:
            try:
                fcntl.flock(lock_fp.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print(f"[INFO] 已有一轮测速正在运行，跳过本次: {lock_path}")
                return 75
            cfg = load_json(Path(args.config))
            return run_once(cfg, dry_run=args.dry_run)
    except KeyboardInterrupt:
        print("\n已取消")
        return 130
    except Exception as e:
        print(f"[ERROR] {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
