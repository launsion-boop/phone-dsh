#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""TLS MCP reference device. The persisted light is a simulated actuator."""
import argparse
import hmac
import json
import os
from pathlib import Path
import sqlite3
import ssl
import time
import re
import signal
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote_to_bytes

from publication import PublicationError, check_identity, monitor, publish, withdraw
from tasks import ensure_tables, accept, finish

MAX_BODY = 16384
SUPPORTED = {'2025-03-26', '2025-06-18', '2025-11-25'}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate JSON member')
        result[key] = value
    return result


def db(path):
    con = sqlite3.connect(path, timeout=5, isolation_level=None)
    con.execute('PRAGMA journal_mode=WAL')
    con.execute('CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id=1), on_value INTEGER NOT NULL, revision INTEGER NOT NULL)')
    con.execute('INSERT OR IGNORE INTO state VALUES (1, 0, 0)')
    con.execute('CREATE TABLE IF NOT EXISTS receipts (operation_id TEXT PRIMARY KEY, on_value INTEGER NOT NULL, revision INTEGER NOT NULL)')
    ensure_tables(con)
    return con


def task_route(path):
    match = re.fullmatch(r'/tasks/([^/]+)/(accept|complete|fail)', path)
    if not match or re.search(r'%(?![0-9A-Fa-f]{2})', match.group(1)):
        return None
    try:
        task_id = unquote_to_bytes(match.group(1)).decode('ascii')
    except UnicodeDecodeError:
        return None
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._:-]{0,63}', task_id):
        return None
    return task_id, match.group(2)


def tool_definitions():
    return [
        {'name': 'light.get', 'description': 'Read the reference device simulated light state.', 'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': False}},
        {'name': 'light.set', 'description': 'Set the simulated light using a caller-provided operation_id. Reuse the same ID and arguments to recover an interrupted call.', 'inputSchema': {'type': 'object', 'properties': {'operation_id': {'type': 'string', 'minLength': 1, 'maxLength': 128}, 'on': {'type': 'boolean'}}, 'required': ['operation_id', 'on'], 'additionalProperties': False}},
        {'name': 'light.result', 'description': 'Look up a previously submitted operation without executing it.', 'inputSchema': {'type': 'object', 'properties': {'operation_id': {'type': 'string', 'minLength': 1, 'maxLength': 128}}, 'required': ['operation_id'], 'additionalProperties': False}},
    ]


def op_id(args):
    value = args.get('operation_id')
    if not isinstance(value, str) or not value or len(value.encode('utf-8')) > 128 or any(ord(c) < 33 or ord(c) > 126 for c in value):
        raise ValueError('invalid operation_id')
    return value


def tool_call(path, name, args):
    if not isinstance(args, dict):
        raise ValueError('arguments must be an object')
    con = db(path)
    try:
        if name == 'light.get':
            if args:
                raise ValueError('unexpected arguments')
            on, revision = con.execute('SELECT on_value, revision FROM state WHERE id=1').fetchone()
            return {'on': bool(on), 'state_revision': revision, 'source': 'simulated'}
        if name == 'light.result':
            if set(args) != {'operation_id'}:
                raise ValueError('invalid arguments')
            operation_id = op_id(args)
            row = con.execute('SELECT on_value, revision FROM receipts WHERE operation_id=?', (operation_id,)).fetchone()
            return {'operation_id': operation_id, 'status': 'completed', 'on': bool(row[0]), 'state_revision': row[1]} if row else {'operation_id': operation_id, 'status': 'outcome_unknown'}
        if name != 'light.set' or set(args) != {'operation_id', 'on'} or type(args.get('on')) is not bool:
            raise ValueError('unknown tool or invalid arguments')
        operation_id = op_id(args)
        con.execute('BEGIN IMMEDIATE')
        row = con.execute('SELECT on_value, revision FROM receipts WHERE operation_id=?', (operation_id,)).fetchone()
        if row:
            if row[0] != int(args['on']):
                raise ValueError('operation_id conflict')
            revision = row[1]
        else:
            if con.execute('SELECT COUNT(*) FROM receipts').fetchone()[0] >= 4096:
                raise ValueError('receipt store full')
            con.execute('UPDATE state SET on_value=?, revision=revision+1 WHERE id=1', (int(args['on']),))
            revision = con.execute('SELECT revision FROM state WHERE id=1').fetchone()[0]
            con.execute('INSERT INTO receipts VALUES (?, ?, ?)', (operation_id, int(args['on']), revision))
        con.execute('COMMIT')
        return {'operation_id': operation_id, 'status': 'completed', 'on': args['on'], 'state_revision': revision}
    finally:
        con.close()


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass  # No credentials, arguments or device data in access logs.

    def reply(self, status, obj=None):
        body = json.dumps(obj, separators=(',', ':')).encode() if obj is not None else b''
        self.send_response(status)
        if obj is not None:
            self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def auth(self):
        headers = self.headers.get_all('Authorization', [])
        expected = 'Bearer ' + self.server.token
        return len(headers) == 1 and hmac.compare_digest(headers[0], expected)

    def allowed(self):
        # The Host header must equal the TLS hostname used for provisioning.
        expected = self.server.hostname if self.server.server_port == 443 else f'{self.server.hostname}:{self.server.server_port}'
        hosts = self.headers.get_all('Host', [])
        if len(hosts) != 1 or hosts[0].lower() != expected.lower() or self.headers.get('Origin'):
            return 403
        return 200 if self.auth() else 401

    def do_GET(self):
        if self.path != '/tasks':
            return self.reply(405 if self.path == '/mcp' else 404)
        status = self.allowed()
        if status != 200:
            return self.reply(status)
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.close_connection = True
        self.connection.settimeout(10)
        sent = set()
        heartbeat = time.monotonic()
        try:
            while True:
                con = db(self.server.state_path)
                try:
                    rows = con.execute("SELECT id, task FROM tasks WHERE phase != 'terminal' ORDER BY rowid").fetchall()
                finally:
                    con.close()
                for task_id, task in rows:
                    if task_id not in sent:
                        self.wfile.write(b'event: task\ndata: ' + task.encode('utf-8') + b'\n\n')
                        self.wfile.flush()
                        sent.add(task_id)
                if time.monotonic() - heartbeat >= 15:
                    self.wfile.write(b': ping\n\n'); self.wfile.flush(); heartbeat = time.monotonic()
                time.sleep(0.25)
        except (BrokenPipeError, ConnectionResetError, TimeoutError, ssl.SSLError):
            return

    def do_POST(self):
        self.connection.settimeout(10)
        task_path = task_route(self.path)
        if self.path != '/mcp' and task_path is None:
            return self.reply(404)
        status = self.allowed()
        if status != 200:
            return self.reply(status)
        lengths = self.headers.get_all('Content-Length', [])
        if len(lengths) != 1 or not lengths[0].isdigit() or self.headers.get('Transfer-Encoding'):
            return self.reply(400)
        size = int(lengths[0])
        if not 0 < size <= MAX_BODY:
            return self.reply(413)
        try:
            message = json.loads(self.rfile.read(size), object_pairs_hook=unique_object)
        except (ValueError, UnicodeDecodeError):
            return self.reply(400)
        if task_path is not None:
            task_id, action = task_path
            con = db(self.server.state_path)
            try:
                if action == 'accept':
                    status = accept(con, task_id) if message == {} else 400
                else:
                    status = finish(con, task_id, action, message)
            except sqlite3.Error:
                status = 503
            finally:
                con.close()
            return self.reply(status)
        if not isinstance(message, dict) or message.get('jsonrpc') != '2.0' or not isinstance(message.get('method'), str):
            return self.reply(400)
        method, request_id = message['method'], message.get('id')
        if 'id' not in message:
            return self.reply(202)
        if isinstance(request_id, bool) or not isinstance(request_id, (str, int)):
            return self.reply(400)
        params = message.get('params', {})
        if not isinstance(params, dict):
            return self.rpc_error(request_id, -32602, 'invalid parameters')
        if method == 'initialize':
            version = params.get('protocolVersion')
            if version not in SUPPORTED:
                return self.rpc_error(request_id, -32602, 'unsupported protocol version')
            return self.rpc_result(request_id, {'protocolVersion': version, 'capabilities': {'tools': {'listChanged': False}}, 'serverInfo': {'name': 'phone-dsh-lan-reference', 'version': '1.0.0'}})
        if method == 'ping':
            return self.rpc_result(request_id, {})
        if method == 'tools/list':
            return self.rpc_result(request_id, {'tools': tool_definitions()})
        if method == 'tools/call':
            try:
                result = tool_call(self.server.state_path, params.get('name'), params.get('arguments', {}))
                return self.rpc_result(request_id, {'content': [{'type': 'text', 'text': json.dumps(result, separators=(',', ':'))}], 'structuredContent': result, 'isError': False})
            except (ValueError, sqlite3.Error) as error:
                return self.rpc_result(request_id, {'content': [{'type': 'text', 'text': str(error) if isinstance(error, ValueError) else 'state unavailable'}], 'isError': True})
        return self.rpc_error(request_id, -32601, 'method not found')

    def rpc_result(self, request_id, result):
        return self.reply(200, {'jsonrpc': '2.0', 'id': request_id, 'result': result})

    def rpc_error(self, request_id, code, message):
        return self.reply(200, {'jsonrpc': '2.0', 'id': request_id, 'error': {'code': code, 'message': message}})


def sni_guard(hostname):
    """Reject handshakes whose SNI is absent or is not the advertised hostname."""
    def callback(_sock, server_name, _context):
        if server_name is None or server_name.lower() != hostname:
            return ssl.ALERT_DESCRIPTION_UNRECOGNIZED_NAME
        return None
    return callback


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cert', required=True)
    parser.add_argument('--key', required=True)
    parser.add_argument('--token-file', required=True)
    parser.add_argument('--hostname', required=True, help='certificate DNS hostname, also used to validate Host')
    parser.add_argument('--port', type=int, default=8443)
    parser.add_argument('--listen', default='0.0.0.0')
    parser.add_argument('--state', required=True)
    parser.add_argument('--publish-name', help='advertise with macOS dns-sd; the published SRV target is verified against --hostname')
    parser.add_argument('--publish-address', help='publish --hostname as the SRV target with this address (dns-sd -P) instead of the system hostname')
    parser.add_argument('--publish-timeout', type=float, default=10.0, help='seconds to register and verify the advertisement')
    parser.add_argument('--publish-recheck', type=float, default=60.0, help='seconds between re-verifications of the published record')
    args = parser.parse_args()
    try:
        hostname = check_identity(args.hostname, args.cert)
    except PublicationError as error:
        parser.error(str(error))
    token_path = Path(args.token_file)
    if os.stat(token_path).st_mode & 0o077:
        parser.error('token file must be private (mode 0600)')
    token = token_path.read_text(encoding='utf-8').strip()
    if not 32 <= len(token) <= 512 or not token.isascii() or any(ord(c) < 33 or ord(c) > 126 for c in token):
        parser.error('token must contain 32–512 printable ASCII characters')
    con = db(args.state)
    con.close()
    server = ThreadingHTTPServer((args.listen, args.port), Handler)
    server.daemon_threads = True
    server.token, server.hostname, server.state_path = token, hostname, args.state
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(args.cert, args.key)
    context.sni_callback = sni_guard(hostname)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    publisher = None

    def terminate(_signum, _frame):
        raise SystemExit(0)  # run the finally block so the advertisement is withdrawn

    signal.signal(signal.SIGTERM, terminate)
    try:
        if args.publish_name:
            try:
                publisher = publish(args.publish_name, hostname, server.server_port, args.publish_address, args.publish_timeout)
            except PublicationError as error:
                print(f'Advertisement withdrawn: {error}', file=sys.stderr, flush=True)
                raise SystemExit(2)
            print(f'Published {args.publish_name!r} at {hostname}:{server.server_port}', flush=True)
            failures = []

            def withdrawn(error):
                failures.append(error)
                print(f'Advertisement withdrawn: {error}', file=sys.stderr, flush=True)
                threading.Thread(target=server.shutdown, daemon=True).start()

            monitor(publisher, args.publish_name, hostname, server.server_port, args.publish_recheck,
                    args.publish_timeout, withdrawn)
        print(f'Listening on TLS port {server.server_port}', flush=True)
        server.serve_forever()
        if args.publish_name and failures:
            raise SystemExit(2)
    finally:
        if publisher:
            withdraw(publisher)
        server.server_close()


if __name__ == '__main__':
    main()
