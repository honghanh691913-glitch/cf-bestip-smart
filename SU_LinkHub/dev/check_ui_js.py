#!/usr/bin/env python3
"""Syntax-check every inline <script> in src/su_linkhub/ui/*.html with `node --check`."""
import glob, os, re, subprocess, sys, tempfile
root = os.path.join(os.path.dirname(__file__), '..', 'src', 'su_linkhub', 'ui')
bad = 0
for path in sorted(glob.glob(os.path.join(root, '*.html'))):
    html = open(path, encoding='utf-8').read()
    for i, body in enumerate(re.findall(r'<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>', html, re.S)):
        with tempfile.NamedTemporaryFile('w', suffix='.js', delete=False, encoding='utf-8') as f:
            f.write(body)
        r = subprocess.run(['node', '--check', f.name], capture_output=True, text=True)
        os.unlink(f.name)
        if r.returncode:
            bad += 1
            print(f'FAIL {os.path.basename(path)} script#{i}:\n{r.stderr[:800]}')
print('ui js check:', 'FAILED' if bad else 'OK')
sys.exit(1 if bad else 0)
