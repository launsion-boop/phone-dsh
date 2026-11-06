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
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from discovery import PROFILE, SERVICE

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
    return con


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

    def do_GET(self):
        self.reply(405)

    def do_POST(self):
        self.connection.settimeout(10)
        if self.path != '/mcp':
            return self.reply(404)
        # The Host header must equal the TLS hostname used for provisioning.
        expected_host = self.server.hostname if self.server.server_port == 443 else f'{self.server.hostname}:{self.server.server_port}'
        hosts = self.headers.get_all('Host', [])
        if len(hosts) != 1 or hosts[0].lower() != expected_host.lower() or self.headers.get('Origin'):
            return self.reply(403)
        if not self.auth():
            return self.reply(401)
        lengths = self.headers.get_all('Content-Length', [])
        if len(lengths) != 1 or not lengths[0].isdigit() or self.headers.get('Transfer-Encoding'):
            return self.reply(400)
        size = int(lengths[0])
        if not 0 < size <= MAX_BODY:
            return self.reply(413)
        try:
            message = json.loads(self.rfile.read(size), object_pairs_hook=unique_object)
            if not isinstance(message, dict) or message.get('jsonrpc') != '2.0' or not isinstance(message.get('method'), str):
                raise ValueError('invalid JSON-RPC request')
        except (ValueError, UnicodeDecodeError):
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cert', required=True)
    parser.add_argument('--key', required=True)
    parser.add_argument('--token-file', required=True)
    parser.add_argument('--hostname', required=True, help='certificate DNS hostname, also used to validate Host')
    parser.add_argument('--port', type=int, default=8443)
    parser.add_argument('--listen', default='0.0.0.0')
    parser.add_argument('--state', required=True)
    parser.add_argument('--publish-name', help='advertise with macOS dns-sd; hostname must match local DNS-SD SRV target')
    args = parser.parse_args()
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
    server.token, server.hostname, server.state_path = token, args.hostname.rstrip('.').lower(), args.state
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(args.cert, args.key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    publisher = None
    if args.publish_name:
        publisher = subprocess.Popen(['dns-sd', '-R', args.publish_name, SERVICE, 'local.', str(args.port), 'profile=' + PROFILE], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        print(f'Listening on TLS port {server.server_port}', flush=True)
        server.serve_forever()
    finally:
        if publisher:
            publisher.terminate()
            publisher.wait(timeout=5)
        server.server_close()


if __name__ == '__main__':
    main()
