#!/usr/bin/env python3
import json, os, platform, shutil, stat, tarfile, tempfile, urllib.request
from pathlib import Path
ROOT = Path(__file__).resolve().parent
UA = "cf-bestip-smart-installer/1.1.0"

def get_json(url):
    req=urllib.request.Request(url,headers={"User-Agent":UA,"Accept":"application/vnd.github+json"})
    with urllib.request.urlopen(req,timeout=30) as r:return json.load(r)

def main():
    machine=platform.machine().lower()
    mapping={"x86_64":"amd64","amd64":"amd64","aarch64":"arm64","arm64":"arm64","armv7l":"armv7"}
    arch=mapping.get(machine)
    if not arch: raise SystemExit(f"Unsupported arch: {machine}")
    rel=get_json("https://api.github.com/repos/XIU2/CloudflareSpeedTest/releases/latest")
    names=[f"cfst_linux_{arch}.tar.gz",f"cfst_linux_{arch}.zip"]
    asset=next((a for a in rel.get("assets",[]) if a.get("name") in names),None)
    if not asset: raise SystemExit(f"No CFST linux asset for {arch}")
    url=asset["browser_download_url"]
    print("Downloading",url)
    with tempfile.TemporaryDirectory() as td:
        pkg=Path(td)/asset["name"]
        req=urllib.request.Request(url,headers={"User-Agent":UA})
        with urllib.request.urlopen(req,timeout=120) as r, pkg.open("wb") as f: shutil.copyfileobj(r,f)
        if pkg.suffix==".zip":
            import zipfile
            with zipfile.ZipFile(pkg) as z:z.extractall(td)
        else:
            with tarfile.open(pkg,"r:gz") as t:t.extractall(td)
        found=None
        for p in Path(td).rglob("cfst"):
            if p.is_file(): found=p; break
        if not found: raise SystemExit("cfst binary not found in release")
        dst=ROOT/"cfst"
        shutil.copy2(found,dst)
        dst.chmod(dst.stat().st_mode|stat.S_IXUSR|stat.S_IXGRP|stat.S_IXOTH)
    print("Installed",dst)
if __name__=="__main__":main()
