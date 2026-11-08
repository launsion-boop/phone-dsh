#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Temporary private-LAN HTTP fixture for the iPhone→BLE→ESP32→HTTP hardware gate.
No home devices are contacted. Reboot is authenticated and limited to the pinned USB chip.
"""
import argparse
import hmac
import json
from pathlib import Path
import secrets
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

parser = argparse.ArgumentParser()
parser.add_argument('--bind', required=True)
parser.add_argument('--port', type=int, default=18767)
parser.add_argument('--serial-port', required=True)
parser.add_argument('--device-mac', required=True)
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args()
args.out.mkdir(parents=True, exist_ok=True)
token = secrets.token_hex(24)
(args.out / 'fixture-token').write_text(token)
(args.out / 'fixture-token').chmod(0o600)
lock = threading.Lock()
state = {'actuations': {}, 'slow_requests': 0, 'redirect_requests': 0, 'redirect_targets': 0, 'reboots': 0}


def save():
    (args.out / 'fixture-state.json').write_text(json.dumps(state, indent=2) + '\n')


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *values):
        print('%s %s' % (self.address_string(), fmt % values), flush=True)

    def reply(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def authorized(self):
        if not hmac.compare_digest(self.headers.get('X-PDSH-Fixture', ''), token):
            self.reply(403, {'error': 'fixture token required'})
            return False
        return True

    def do_GET(self):
        if not self.authorized():
            return
        parsed = urlparse(self.path)
        if parsed.path == '/state':
            run = parse_qs(parsed.query).get('run', [''])[0]
            with lock:
                self.reply(200, {'actuations': state['actuations'].get(run, 0), 'slow_requests': state['slow_requests'], 'redirect_targets': state['redirect_targets'], 'reboots': state['reboots']})
        elif parsed.path == '/large':
            body = b'L' * 2048
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif parsed.path == '/redirect':
            with lock:
                state['redirect_requests'] += 1
                save()
            self.send_response(302)
            self.send_header('Location', '/redirect-target')
            self.send_header('Content-Length', '0')
            self.end_headers()
        elif parsed.path == '/redirect-target':
            with lock:
                state['redirect_targets'] += 1
                save()
            self.reply(200, {'unexpected_redirect': True})
        else:
            self.reply(404, {'error': 'unknown fixture path'})

    def do_POST(self):
        if not self.authorized():
            return
        length = int(self.headers.get('Content-Length', 0))
        if length > 4096:
            self.reply(413, {'error': 'too large'})
            return
        self.rfile.read(length)
        parsed = urlparse(self.path)
        if parsed.path == '/actuate':
            run = parse_qs(parsed.query).get('run', [''])[0]
            with lock:
                state['actuations'][run] = state['actuations'].get(run, 0) + 1
                count = state['actuations'][run]
                save()
            self.reply(200, {'test': True, 'count': count})
        elif parsed.path == '/slow':
            with lock:
                state['slow_requests'] += 1
                save()
            time.sleep(2)
            self.reply(200, {'test': True, 'completed_after_timeout': True})
        elif parsed.path == '/control/reboot':
            from serial.tools import list_ports
            ports = [p for p in list_ports.comports() if p.device == args.serial_port]
            if not ports or (ports[0].serial_number or '').lower().replace(':', '') != args.device_mac.lower().replace(':', ''):
                self.reply(409, {'error': 'pinned ESP32 serial identity mismatch'})
                return
            command = [sys.executable, '-m', 'esptool', '--chip', 'esp32s3', '--port', args.serial_port, '--after', 'watchdog-reset', 'read-mac']
            result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=25)
            with (args.out / 'reboot.log').open('ab') as output:
                output.write(result.stdout)
            if result.returncode:
                self.reply(500, {'error': 'ESP32 reboot failed'})
                return
            with lock:
                state['reboots'] += 1
                save()
            self.reply(200, {'rebooted': True})
        else:
            self.reply(404, {'error': 'unknown fixture path'})


save()
print(f'BLE hardware HTTP fixture listening at http://{args.bind}:{args.port}', flush=True)
ThreadingHTTPServer((args.bind, args.port), Handler).serve_forever()
