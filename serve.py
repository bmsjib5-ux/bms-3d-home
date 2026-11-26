#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Local server for the whole BMS 3D set: the launcher page and the 3D apps
# on ONE port, plus the CORS proxy for the BMS-Session HOSxP API.
#
#   /index.html                        the launcher (choose an app)
#   /patient-journey-3d/live.html      outpatient realtime 3D
#   /Lab-visit-3D/index.html           blood-draw room 3D
#   /doctor-queue-3d/index.html        doctor exam-room queue 3D
#   /er-triage-3d/index.html           emergency room (ER) 3D
#   /proxy?url=...                     HOSxP API proxy used by the apps
#
# Why this exists:
#   The HOSxP tunnel (*.tunnel.hosxp.net) does NOT send CORS headers on /api/sql,
#   so a page served from http://localhost:PORT cannot fetch it directly (the
#   browser blocks it), and opening the file with file:// sends Origin: null
#   which the tunnel rejects too. This server forwards
#       /proxy?url=<https://...hosxp.net/...>
#   server-side and adds the CORS headers back.
#
#   Both apps route through the proxy when opened over http
#   (see proxied() in each app).

#   Usage: python serve.py [PORT] [--open] [--pause] [--info]
#   --open  = open the browser once the port is bound (start.bat passes it).
#   --pause = wait for Enter before closing after an error (Start-menu shortcut:
#             otherwise the console window vanishes before the message can be read).
#   --info  = do not start a server: print the addresses of this PC and whether
#             a server already answers on PORT, then exit.
#   start.bat falls back to serve.ps1 (same job, PowerShell) when Python is missing.

import functools, hashlib, json, os, socket, sys, threading, time, webbrowser
import urllib.request, urllib.parse, urllib.error
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

_args = [a for a in sys.argv[1:] if not a.startswith('--')]
PORT = int(_args[0]) if _args else 8805
OPEN = '--open' in sys.argv[1:]
PAUSE = '--pause' in sys.argv[1:]
INFO = '--info' in sys.argv[1:]
FROZEN = getattr(sys, 'frozen', False)
# serve the program folder, whatever the current directory is
BASE = os.path.dirname(os.path.abspath(sys.executable if FROZEN else __file__))
ROOT = os.path.join(BASE, 'www') if os.path.isdir(os.path.join(BASE, 'www')) else BASE
ALLOW_HOSTS = ('hosxp.net',)        # only proxy to HOSxP hosts (not an open proxy)
                                   # bare hosxp.net (PasteJSON) + any *.hosxp.net tunnel
USER_AGENT = 'BMS-PatientJourney3D/1.0'  # hosxp.net answers 403 HTML when no User-Agent is sent

# ---- shared /api/sql cache -------------------------------------------------
# Every screen sends the same SQL text (same day, same keyset pages), so when
# many PCs open http://<this-PC>:PORT/live.html the database sees roughly the
# load of ONE screen: a result is reused for CACHE_SEC seconds, and requests
# that arrive while the same query is still running wait for that one answer
# instead of sending it again.
#   - key = full target URL + Authorization header: a different BMS session
#     never gets another session's answer
#   - only successful answers (HTTP 200 and MessageCode 200) are kept; errors,
#     "busy" answers and PasteJSON look-ups always go to the server
#   - set BMS_3D_CACHE_SEC=0 to turn it off
try:
    CACHE_SEC = max(0.0, float(os.environ.get('BMS_3D_CACHE_SEC', os.environ.get('BMS_PJ3D_CACHE_SEC', '15'))))
except ValueError:
    CACHE_SEC = 15.0
CACHE_MAX_BYTES = 64 * 1024 * 1024
_cache = {}                      # key -> {'t': time, 'ev': Event, 'res': (code, ctype, body) | None}
_cache_lock = threading.Lock()
_stats = {'hit': 0, 'miss': 0, 'wait': 0}


def _cacheable(target):
    return CACHE_SEC > 0 and urllib.parse.urlparse(target).path.rstrip('/').endswith('/api/sql')


def _good(code, body):
    if code != 200:
        return False
    try:
        return json.loads(body.decode('utf-8')).get('MessageCode') == 200
    except Exception:
        return False


def _prune(now):
    """drop expired entries; if still too big, drop the oldest (lock held)"""
    for k in [k for k, e in _cache.items() if e['res'] is not None and now - e['t'] > CACHE_SEC]:
        del _cache[k]
    total = sum(len(e['res'][2]) for e in _cache.values() if e['res'] is not None)
    if total > CACHE_MAX_BYTES:
        for k, e in sorted(((k, e) for k, e in _cache.items() if e['res'] is not None), key=lambda x: x[1]['t']):
            total -= len(e['res'][2])
            del _cache[k]
            if total <= CACHE_MAX_BYTES:
                break


class Handler(SimpleHTTPRequestHandler):
    def end_headers(self):
        # the pages are edited in place; without this a screen can keep showing
        # yesterday's file after an update until someone presses Ctrl+F5
        if self.path.split('?')[0].endswith(('.html', '/')):
            self.send_header('Cache-Control', 'no-store')
        SimpleHTTPRequestHandler.end_headers(self)

    def _cors(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Headers', 'Authorization, Accept, Content-Type')
        self.send_header('Access-Control-Allow-Methods', 'GET, OPTIONS')

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        if self.path.startswith('/proxy?') or self.path.startswith('/proxy/'):
            return self._proxy()
        if self.path == '/cache-stats':      # how many SQL answers were shared (no data, counts only)
            with _cache_lock:
                s = dict(_stats, entries=len(_cache), ttl_sec=CACHE_SEC)
            return self._send(200, 'application/json', json.dumps(s).encode('utf-8'))
        return super().do_GET()

    def _proxy(self):
        qs = urllib.parse.urlparse(self.path).query
        target = urllib.parse.parse_qs(qs).get('url', [''])[0]
        if not target:
            self.send_error(400, 'missing url')
            return
        host = urllib.parse.urlparse(target).hostname or ''
        ok = any(host == h or host.endswith('.' + h) for h in ALLOW_HOSTS)
        if not (target.startswith('https://') and ok):
            self.send_error(403, 'target host not allowed')
            return

        auth = self.headers.get('Authorization') or ''
        if not _cacheable(target):
            return self._send(*self._fetch(target, auth), cache=None)

        key = hashlib.sha256((target + '\n' + auth).encode('utf-8')).hexdigest()
        while True:
            with _cache_lock:
                now = time.time()
                e = _cache.get(key)
                if e is not None and e['res'] is not None and now - e['t'] <= CACHE_SEC:
                    _stats['hit'] += 1
                    return self._send(*e['res'], cache='HIT')
                if e is None or e['res'] is not None:
                    # nobody is fetching this query: this request does it
                    _prune(now)
                    mine = {'t': now, 'ev': threading.Event(), 'res': None}
                    _cache[key] = mine
                    _stats['miss'] += 1
                    break
                ev = e['ev']                 # same query already running: wait for its answer
                _stats['wait'] += 1
            if not ev.wait(70):
                return self._send(*self._fetch(target, auth), cache=None)
            # loop: take the answer from the cache (or fetch if it was not kept)

        res = (502, 'text/plain; charset=utf-8', b'proxy error')
        try:
            res = self._fetch(target, auth)
        finally:
            with _cache_lock:
                if _good(res[0], res[2]):
                    mine['res'] = res
                    mine['t'] = time.time()
                elif _cache.get(key) is mine:
                    del _cache[key]          # never keep errors / busy answers
            mine['ev'].set()
        self._send(*res, cache='MISS')

    def _fetch(self, target, auth):
        req = urllib.request.Request(target, method='GET')
        if auth:
            req.add_header('Authorization', auth)
        req.add_header('Accept', 'application/json')
        req.add_header('User-Agent', USER_AGENT)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                body = r.read()
                ctype = r.headers.get('Content-Type', 'application/json')
                code = r.getcode()
        except urllib.error.HTTPError as e:
            # pass the real body back so the page can show the SQL error text (400/409)
            body = e.read()
            ctype = e.headers.get('Content-Type', 'text/plain')
            code = e.code
        except Exception as e:
            body = ('proxy error: ' + str(e)).encode('utf-8')
            ctype = 'text/plain; charset=utf-8'
            code = 502
        return code, ctype, body

    def _send(self, code, ctype, body, cache=None):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        if cache:
            self.send_header('X-Cache', cache)
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # keep the console quiet


class Server(ThreadingHTTPServer):
    # On Windows SO_REUSEADDR lets a second copy bind the same port silently;
    # without it a second start.bat gets a clear "port in use" error instead.
    allow_reuse_address = os.name != 'nt'


def lan_addresses():
    """IPv4 addresses other PCs can use to reach this one."""
    ips = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if not ip.startswith(('127.', '169.254.')):
                ips.add(ip)
    except OSError:
        pass
    return sorted(ips)


def leave(code):
    if PAUSE:
        try:
            input('\nPress Enter to close this window...')
        except (EOFError, KeyboardInterrupt):
            pass
    sys.exit(code)


def show_info():
    """--info: where is the tool reachable, and is a server answering right now?"""
    import time
    url = 'http://localhost:%d/' % PORT
    running = False
    for _ in range(8):              # right after setup the exe may still be starting up
        try:
            with urllib.request.urlopen(url + 'live.html', timeout=5) as r:
                running = r.getcode() == 200
        except Exception:
            running = False
        if running:
            break
        time.sleep(1)
    print('=' * 62)
    print('  BMS 3D - server on port %d : %s' % (PORT, 'RUNNING' if running else 'NOT RUNNING'))
    print('-' * 62)
    print('  This PC:    %sindex.html     (launcher)' % url)
    for ip in lan_addresses():
        print('  Other PCs:  http://%s:%d/index.html' % (ip, PORT))
    if not running:
        print('-' * 62)
        print('  The server is not answering. Run start.bat in this folder.')
    print('=' * 62)
    leave(0 if running else 1)


if __name__ == '__main__':
    if INFO:
        show_info()
    url = 'http://localhost:%d/index.html' % PORT
    if not os.path.isfile(os.path.join(ROOT, 'index.html')):
        print('\nindex.html is missing in %s' % ROOT)
        leave(1)
    try:
        # '' = all addresses, so other PCs on the network can open http://<this-PC-IP>:PORT/
        httpd = Server(('', PORT), functools.partial(Handler, directory=ROOT))
    except OSError as e:
        print('\nCould not start the server on port %d : %s' % (PORT, e))
        print('Is this tool already running (another window, or the automatic start)?')
        print('Then it is already working - just open %s' % url)
        leave(1)
    print('=' * 62)
    print('  BMS 3D - launcher + all 3D apps on one port (Python)')
    print('  This PC:    ' + url)
    for ip in lan_addresses():
        print('  Other PCs:  http://%s:%d/index.html' % (ip, PORT))
    print('  Apps:       %spatient-journey-3d/live.html' % url[:-10])
    print('              %sLab-visit-3D/index.html' % url[:-10])
    print('              %sdoctor-queue-3d/index.html' % url[:-10])
    print('              %ser-triage-3d/index.html' % url[:-10])
    print('  (other PCs cannot connect? run Enable-LAN.bat once to open the firewall)')
    if CACHE_SEC > 0:
        print('  SQL cache: screens share each answer for %g s  (stats: /cache-stats)' % CACHE_SEC)
    else:
        print('  SQL cache: off (BMS_3D_CACHE_SEC=0)')
    print('  Press Ctrl+C to stop.')
    print('=' * 62)
    sys.stdout.flush()
    if OPEN:
        webbrowser.open(url)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print('\nServer stopped.')
