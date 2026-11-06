# SPDX-License-Identifier: MIT
import http.client
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


class ReferenceDeviceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.dir = Path(cls.temp.name)
        cls.cert, cls.key = cls.dir / 'cert.pem', cls.dir / 'key.pem'
        cls.tokenfile, cls.state = cls.dir / 'token', cls.dir / 'state.db'
        cls.token = 'test-token-' + 'x' * 48
        cls.tokenfile.write_text(cls.token, encoding='utf-8')
        cls.tokenfile.chmod(0o600)
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost', '-keyout', str(cls.key), '-out', str(cls.cert)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            cls.port = sock.getsockname()[1]
        cls.start_server()

    @classmethod
    def start_server(cls):
        cls.process = subprocess.Popen(['python3', str(HERE / 'server.py'), '--cert', str(cls.cert), '--key', str(cls.key), '--token-file', str(cls.tokenfile), '--hostname', 'localhost', '--listen', '127.0.0.1', '--port', str(cls.port), '--state', str(cls.state)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        line = cls.process.stdout.readline()
        if 'Listening on TLS port' not in line:
            raise RuntimeError('reference server did not start: ' + cls.process.stderr.read())

    @classmethod
    def stop_server(cls):
        cls.process.terminate()
        cls.process.wait(timeout=10)
        cls.process.stdout.close()
        cls.process.stderr.close()

    @classmethod
    def tearDownClass(cls):
        cls.stop_server()
        cls.temp.cleanup()

    def request(self, method, params=None, token=True, host=None):
        context = ssl.create_default_context(cafile=str(self.cert))
        connection = http.client.HTTPSConnection('localhost', self.port, context=context, timeout=5)
        headers = {'Content-Type': 'application/json'}
        if token is not None:
            headers['Authorization'] = 'Bearer ' + (self.token if token is True else token)
        if host:
            headers['Host'] = host
        body = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params or {}})
        connection.request('POST', '/mcp', body=body, headers=headers)
        response = connection.getresponse()
        result = response.status, response.read()
        connection.close()
        return result

    def test_unauthorized_host_and_tls(self):
        self.assertEqual(self.request('tools/list', token=None)[0], 401)
        self.assertEqual(self.request('tools/list', token='wrong')[0], 401)
        self.assertEqual(self.request('tools/list', host='evil.example')[0], 403)
        with self.assertRaises(ssl.SSLCertVerificationError):
            connection = http.client.HTTPSConnection('localhost', self.port, timeout=5)
            connection.request('POST', '/mcp')

    def test_side_effect_deduplication_and_result_query(self):
        args = {'operation_id': 'reference-op-1', 'on': True}
        def call(name, arguments):
            status, body = self.request('tools/call', {'name': name, 'arguments': arguments})
            self.assertEqual(status, 200)
            return json.loads(body)['result']
        first = call('light.set', args)['structuredContent']
        repeated = call('light.set', args)['structuredContent']
        self.assertEqual(first, repeated)
        self.assertTrue(call('light.set', {**args, 'on': False})['isError'])
        self.assertEqual(call('light.result', {'operation_id': args['operation_id']})['structuredContent'], first)
        self.assertEqual(call('light.result', {'operation_id': 'missing'})['structuredContent']['status'], 'outcome_unknown')
        self.stop_server()
        self.start_server()
        self.assertEqual(call('light.result', {'operation_id': args['operation_id']})['structuredContent'], first)

    def test_lost_response_can_be_queried_without_reexecution(self):
        args = {'operation_id': 'lost-response-1', 'on': True}
        payload = json.dumps({'jsonrpc': '2.0', 'id': 9, 'method': 'tools/call', 'params': {'name': 'light.set', 'arguments': args}}).encode()
        context = ssl.create_default_context(cafile=str(self.cert))
        with socket.create_connection(('localhost', self.port), timeout=5) as raw:
            with context.wrap_socket(raw, server_hostname='localhost') as conn:
                headers = (f'POST /mcp HTTP/1.1\r\nHost: localhost:{self.port}\r\n'
                           f'Authorization: Bearer {self.token}\r\nContent-Type: application/json\r\n'
                           f'Content-Length: {len(payload)}\r\nConnection: close\r\n\r\n').encode()
                conn.sendall(headers + payload)
                # The client disappears immediately after the complete request.
        for _ in range(40):
            status, body = self.request('tools/call', {'name': 'light.result', 'arguments': {'operation_id': args['operation_id']}})
            result = json.loads(body)['result']['structuredContent']
            if result['status'] == 'completed':
                break
            time.sleep(0.05)
        self.assertEqual(result['status'], 'completed')
        status, body = self.request('tools/call', {'name': 'light.set', 'arguments': args})
        self.assertEqual(json.loads(body)['result']['structuredContent'], result)

    def test_real_mcp_client_over_tls(self):
        script = '''
import fs from "node:fs";
import { Client, StreamableHTTPClientTransport } from "@modelcontextprotocol/client";
const token = fs.readFileSync(process.argv[2], "utf8").trim();
const client = new Client({name: "device-test", version: "1.0"});
const transport = new StreamableHTTPClientTransport(new URL(process.argv[1]), {requestInit: {headers: {Authorization: `Bearer ${token}`}}});
await client.connect(transport);
const tools = await client.listTools();
if (!tools.tools.some(t => t.name === "light.get")) throw new Error("missing device skill");
const result = await client.callTool({name: "light.get", arguments: {}});
if (result.isError || result.structuredContent.source !== "simulated") throw new Error("invalid result");
await client.close();
'''
        env = dict(os.environ, NODE_EXTRA_CA_CERTS=str(self.cert))
        result = subprocess.run(['node', '--input-type=module', '-e', script, f'https://localhost:{self.port}/mcp', str(self.tokenfile)], cwd=ROOT / 'plugins', env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_real_phonedsh_manager_registers_and_calls_device_skill(self):
        script = """
import fs from 'node:fs';
import { Context } from '@deepseek-ai/cordis';
import { ToolCallId } from '@deepseek-ai/dsh-llm';
import SystemPrompt from '@deepseek-ai/dsh-system-prompt';
import ToolRuntime from '@deepseek-ai/dsh-tools';
import * as phoneMcp from './phone-mcp/src/index.ts';
const token = fs.readFileSync(process.argv[2], 'utf8').trim();
const ctx = new Context();
try {
  await ctx.plugin(SystemPrompt);
  await ctx.plugin(ToolRuntime);
  await ctx.plugin(phoneMcp, {file: process.argv[3], env: {DEVICE_TOKEN: 'Bearer ' + token}});
  const service = ctx.get('phoneMcpRemote');
  const added = await service.mcpUpsert({serverName:'device', url:process.argv[1], headersFromEnv:{Authorization:'DEVICE_TOKEN'}, enabled:true, toolCallTimeoutMs:5000});
  const tool = added.tools.find(name => name.startsWith('mcp__device__light_get_'));
  if (!tool) throw new Error('device skill was not registered: ' + JSON.stringify(added.tools));
  const result = await ctx.tools.execute({callId:ToolCallId('lan-device-test'),name:tool,arguments:{},signal:new AbortController().signal});
  if (result.isError || !JSON.stringify(result).includes('simulated')) throw new Error('device skill execution failed');
} finally { await ctx.fiber.dispose(); }
"""
        env = dict(os.environ, NODE_EXTRA_CA_CERTS=str(self.cert))
        result = subprocess.run(['node', '--input-type=module', '-e', script, f'https://localhost:{self.port}/mcp', str(self.tokenfile), str(self.dir / 'mcp.json')], cwd=ROOT / 'plugins', env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
