# -*- coding: utf-8 -*-
"""Write update/manifest.json = every file tracked by git in BMS-3D-Home with its size and SHA-256.

update-display.ps1 (run on a display PC) downloads this list from the dev PC's start.bat server,
then fetches only the files that are new or different on that PC.

Run again after changing files:   python update/make-manifest.py
Only files tracked by git are listed, so ignored things (deploy scripts with internal IPs,
setup zips, local tools) are never offered to the display PCs.
"""
import hashlib, io, json, os, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP_NAMES = {'.gitignore'}

files = subprocess.run(['git', '-C', ROOT, 'ls-files', '-z'], capture_output=True, check=True).stdout.decode('utf-8').split('\0')
out = []
for p in sorted(f for f in files if f):
    if os.path.basename(p) in SKIP_NAMES or p.startswith('update/'):
        continue
    full = os.path.join(ROOT, *p.split('/'))
    if not os.path.isfile(full):
        print('skip (missing on disk):', p, file=sys.stderr)
        continue
    data = open(full, 'rb').read()
    out.append({'p': p, 'n': len(data), 'h': hashlib.sha256(data).hexdigest().upper()})

doc = {'generated': time.strftime('%Y-%m-%d %H:%M:%S'), 'count': len(out), 'files': out}
dst = os.path.join(ROOT, 'update', 'manifest.json')
io.open(dst, 'w', encoding='utf-8').write(json.dumps(doc, ensure_ascii=False, indent=1))
print('wrote %s (%d files, %.1f MB)' % (dst, len(out), sum(f['n'] for f in out) / 1048576))
