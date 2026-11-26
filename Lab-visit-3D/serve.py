#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Local dev server + CORS proxy for the BMS-Session HOSxP API (Lab 3D).
#
# Why this exists:
#   The HOSxP tunnel (*.tunnel.hosxp.net) does NOT send CORS headers on /api/sql,
#   so a page served from http://localhost:PORT cannot fetch it directly (the
#   browser blocks it), and opening index.html with file:// sends Origin: null
#   which the tunnel rejects too. This server forwards
#       /proxy?url=<https://...hosxp.net/...>
#   server-side and adds the CORS headers back.
#
#   index.html only routes through the proxy when it is NOT opened from file://
#   (see proxied() in index.html).
#
#   Usage: python serve.py [PORT] [--open] [--pause]
#   --open  = open the browser once the port is bound (start.bat passes it).
#   --pause = wait for Enter before closing after an error (shortcut: otherwise
#             the console window vanishes before the message can be read).
#   start.bat falls back to serve.ps1 (same job, PowerShell) when Python is missing.

import functools, os, socket, sys, urllib.request, urllib.parse, urllib.error, webbrowser
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

_args = [a for a in sys.argv[1:] if not a.startswith('--')]
PORT = int(_args[0]) if _args else 8804
OPEN = '--open' in sys.argv[1:]
PAUSE = '--pause' in sys.argv[1:]
FROZEN = getattr(sys, 'frozen', False)
BASE = os.path.dirname(os.path.abspath(sys.executable if FROZEN else __file__))
ROOT = os.path.join(BASE, 'www') if os.path.isdir(os.path.join(BASE, 'www')) else BASE
ALLOW_HOSTS = ('hosxp.net',)       # only proxy to HOSxP hosts (not an open proxy)
USER_AGENT = 'BMS-Lab3D/1.0'       # hosxp.net answers 403 HTML when no User-Agent is sent


class Handler(SimpleHTTPRequestHandler):
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
        return super().do_GET()

    def _proxy(self):
        qs = urllib.parse.urlparse(self.path).query
        target = urllib.parse.parse_qs(qs).get('url', [''])[0]
        if not target:
            self.send_error(400, 'missing url')
            return
        host = urllib.parse.urlparse(target).hostname or ''
        allowed = any(host == h or host.endswith('.' + h) for h in ALLOW_HOSTS)
        if not (target.startswith('https://') and allowed):
            self.send_error(403, 'target host not allowed')
            return

        req = urllib.request.Request(target, method='GET')
        auth = self.headers.get('Authorization')
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

        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
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


if __name__ == '__main__':
    url = 'http://localhost:%d/index.html' % PORT
    if not os.path.isfile(os.path.join(ROOT, 'index.html')):
        print('\nindex.html is missing in %s' % ROOT)
        leave(1)
    try:
        # '' = all addresses, so other PCs on the network can open http://<this-PC-IP>:PORT/
        httpd = Server(('', PORT), functools.partial(Handler, directory=ROOT))
    except OSError as e:
        print('\nCould not start the server on port %d : %s' % (PORT, e))
        print('Is this tool already running (another window)?')
        print('Then it is already working - just open %s' % url)
        leave(1)
    print('=' * 62)
    print('  BMS Lab 3D - local server + HOSxP API proxy (Python)')
    print('  This PC:    ' + url)
    for ip in lan_addresses():
        print('  Other PCs:  http://%s:%d/index.html' % (ip, PORT))
    print('  Press Ctrl+C to stop.')
    print('=' * 62)
    sys.stdout.flush()
    if OPEN:
        webbrowser.open(url)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print('\nServer stopped.')
