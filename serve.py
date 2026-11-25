#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BMS 3D Home - เซิร์ฟเวอร์ไฟล์ในเครื่องสำหรับหน้าเลือกแอป 3 มิติ

  python serve.py [พอร์ต] [--open]

เสิร์ฟเฉพาะไฟล์ในโฟลเดอร์นี้ (index.html + assets) ไม่มี proxy ไม่ต่อฐานข้อมูล
หน้านี้เป็นแค่หน้าเลือก ตัวแอปจริงเปิดเซิร์ฟเวอร์ของตัวเองคนละพอร์ต
"""
import functools
import http.server
import os
import socket
import socketserver
import sys
import webbrowser

ROOT = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PORT = 8805

# คอนโซลของแต่ละเครื่องใช้ code page ต่างกัน — กันไม่ให้ข้อความไทยทำให้เซิร์ฟเวอร์ล้มตั้งแต่ยังไม่เริ่ม
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(errors='replace')
    except Exception:
        pass


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        # หน้าเว็บแก้บ่อย กันเบราว์เซอร์จำของเก่า
        if self.path.endswith(('.html', '/')):
            self.send_header('Cache-Control', 'no-store')
        super().end_headers()

    def log_message(self, fmt, *args):
        if '"GET /' in (fmt % args) and ' 200 ' not in (fmt % args):
            sys.stderr.write('  %s\n' % (fmt % args))


def lan_ips():
    out = []
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if not ip.startswith('127.') and not ip.startswith('169.254.') and ip not in out:
                out.append(ip)
    except Exception:
        pass
    return out


def main():
    port = DEFAULT_PORT
    args = sys.argv[1:]
    for a in args:
        if a.isdigit():
            port = int(a)
    url = 'http://localhost:%d/index.html' % port

    handler = functools.partial(Handler, directory=ROOT)
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    try:
        httpd = socketserver.ThreadingTCPServer(('0.0.0.0', port), handler)
    except OSError as e:
        print('[ERROR] เปิดพอร์ต %d ไม่ได้ : %s' % (port, e))
        print('        อาจมีโปรแกรมอื่นใช้พอร์ตนี้อยู่ แก้พอร์ตได้ที่บรรทัด set PORT= ใน start.bat')
        return 1

    print('=' * 62)
    print('  BMS 3D Home - หน้าเลือกแอปแสดงผล 3 มิติ')
    print('=' * 62)
    print('  เครื่องนี้      : %s' % url)
    for ip in lan_ips():
        print('  เครื่องอื่นในวง : http://%s:%d/index.html' % (ip, port))
    print('  ปิดหน้าต่างนี้ (หรือ Ctrl+C) เพื่อหยุดเซิร์ฟเวอร์')
    print('=' * 62)

    if '--open' in args:
        webbrowser.open(url)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
