# SPDX-License-Identifier: MIT
"""lan-mcp.md#name-consistency: shared vectors and the real macOS DNS-SD publisher."""
import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

from discovery import PROFILE, candidate, canonical_hostname, publication_check, txt_bytes
from publication import PublicationError, check_identity, monitor, parse_lookup, publish, verify_published, withdraw

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent
RESULTS = {'consistent', 'hostname_invalid', 'certificate_name_missing', 'srv_target_invalid',
           'srv_target_mismatch', 'srv_port_mismatch'}


def make_cert(directory, *names):
    cert, key = directory / f'{uuid.uuid4().hex}.pem', directory / f'{uuid.uuid4().hex}.key'
    san = ','.join(f'DNS:{name}' for name in names)
    args = ['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes',
            '-days', '1', '-subj', '/CN=' + (names[0] if names else 'none'), '-keyout', str(key), '-out', str(cert)]
    if san:
        args[-4:-4] = ['-addext', 'subjectAltName=' + san]
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return cert, key


class PublicationVectorTest(unittest.TestCase):
    def test_shared_publication_vectors(self):
        path = ROOT / 'spec/device/v1/golden/lan-publication.jsonl'
        rows = [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines()]
        self.assertEqual(len({row['name'] for row in rows}), len(rows))
        self.assertEqual({row['result'] for row in rows}, RESULTS, 'every outcome needs a vector')
        for row in rows:
            with self.subTest(row['name']):
                url = candidate('Lamp', row['srv_target'], row['srv_port'], txt_bytes(['profile=' + PROFILE]))
                self.assertEqual(url, row.get('url'))
                self.assertEqual(publication_check(row['hostname'], row['certificate_dns_names'], row['srv_target'],
                                                   row['srv_port'], row['port']), row['result'])
                if row['result'] == 'consistent':
                    self.assertTrue(url.startswith('https://' + canonical_hostname(row['hostname']) + '/')
                                    or url.startswith('https://' + canonical_hostname(row['hostname']) + ':'))

    def test_lookup_parser(self):
        lines = ['Lookup A._pdsh-mcp._tcp.local.', ' 0:00:00.000  ...STARTING...',
                 ' 0:00:00.001  A._pdsh-mcp._tcp.local. can be reached at Lamp.local.:8443 (interface 1) Flags: 1',
                 ' profile=pdsh-mcp-1',
                 ' 0:00:00.001  A._pdsh-mcp._tcp.local. can be reached at other.local.:8443 (interface 4)',
                 ' profile=pdsh-mcp-1 note=x']
        self.assertEqual(parse_lookup(lines), (['Lamp.local.', 'other.local.'], [8443, 8443],
                                               ['profile=pdsh-mcp-1', 'profile=pdsh-mcp-1 note=x']))

    def test_identity_requires_exact_certificate_name(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = pathlib.Path(temp)
            self.assertEqual(check_identity('Lamp.Local.', make_cert(directory, 'lamp.local')[0]), 'lamp.local')
            for hostname, names, code in [
                ('lamp.local', ('other.local',), 'certificate_name_missing'),
                ('lamp.local', ('*.local',), 'certificate_name_missing'),
                ('lamp.local', (), 'certificate_name_missing'),
                ('xn--bcher-kva.local', ('xn--bcher-kva.local',), 'hostname_invalid'),
            ]:
                with self.subTest(hostname=hostname, names=names):
                    with self.assertRaises(PublicationError) as raised:
                        check_identity(hostname, make_cert(directory, *names)[0])
                    self.assertEqual(raised.exception.code, code)


class MonitorTest(unittest.TestCase):
    def test_mismatch_withdraws_once(self):
        publisher = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], stdout=subprocess.PIPE, text=True)
        failures, calls = [], []

        def verify(*args):
            calls.append(args)
            if len(calls) == 2:
                raise PublicationError('srv_target_mismatch', 'renamed')

        stop, thread = monitor(publisher, 'A', 'lamp.local', 8443, 0.05, 1, failures.append, verify=verify)
        thread.join(timeout=5)
        self.assertEqual([error.code for error in failures], ['srv_target_mismatch'])
        self.assertIsNotNone(publisher.poll(), 'the advertisement must be withdrawn')

    def test_publisher_exit_is_a_failure(self):
        publisher = subprocess.Popen([sys.executable, '-c', 'pass'], stdout=subprocess.PIPE, text=True)
        publisher.wait(timeout=10)
        failures = []
        _, thread = monitor(publisher, 'A', 'lamp.local', 8443, 0.05, 1, failures.append, verify=lambda *a: None)
        thread.join(timeout=5)
        self.assertEqual([error.code for error in failures], ['publication_unverified'])


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('dns-sd'), 'real DNS-SD publisher is macOS dns-sd')
class RealDNSSDPublicationTest(unittest.TestCase):
    """Publishes on the local link through mDNSResponder and resolves the actual record."""

    def system_hostname(self):
        name = subprocess.run(['scutil', '--get', 'LocalHostName'], check=True, capture_output=True, text=True).stdout.strip()
        return canonical_hostname(name + '.local')

    def test_proxy_publication_matches_configured_hostname(self):
        name, host = 'PDSH pub ' + uuid.uuid4().hex[:8], f'pdsh-{uuid.uuid4().hex[:10]}.local'
        publisher = publish(name, host, 18443, '127.0.0.1', timeout=10)
        try:
            self.assertEqual(verify_published(name, host, 18443, 10), [host])
            with self.assertRaises(PublicationError) as raised:
                verify_published(name, host, 18444, 10)
            self.assertEqual(raised.exception.code, 'srv_port_mismatch')
        finally:
            withdraw(publisher)

    def test_system_target_must_equal_hostname(self):
        system = self.system_hostname()
        if system is None:
            self.skipTest('system LocalHostName is not a valid discovery hostname')
        name = 'PDSH sys ' + uuid.uuid4().hex[:8]
        publisher = publish(name, system, 18445, timeout=10)
        withdraw(publisher)
        before = time.monotonic()
        with self.assertRaises(PublicationError) as raised:
            publish('PDSH bad ' + uuid.uuid4().hex[:8], 'not-' + system, 18446, timeout=10)
        self.assertEqual(raised.exception.code, 'srv_target_mismatch')
        self.assertLess(time.monotonic() - before, 25)

    def test_unpublished_instance_times_out(self):
        with self.assertRaises(PublicationError) as raised:
            verify_published('PDSH absent ' + uuid.uuid4().hex[:8], 'absent.local', 18447, timeout=2)
        self.assertEqual(raised.exception.code, 'publication_unverified')

    def test_server_publishes_and_serves_one_hostname(self):
        # Full chain on the real publisher: published SRV -> canon -> URL host -> mDNS
        # address -> TLS SNI and certificate check against H -> authenticated MCP.
        import http.client
        import ssl
        host = f'pdsh-{uuid.uuid4().hex[:10]}.local'
        with tempfile.TemporaryDirectory() as temp:
            directory = pathlib.Path(temp)
            cert, key = make_cert(directory, host)
            token = directory / 'token'
            token.write_text('t' * 48, encoding='utf-8')
            token.chmod(0o600)
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                port = sock.getsockname()[1]
            name = 'PDSH ok ' + uuid.uuid4().hex[:8]
            server = subprocess.Popen([sys.executable, str(HERE / 'server.py'), '--cert', str(cert), '--key', str(key),
                                       '--token-file', str(token), '--hostname', host.upper() + '.', '--listen', '127.0.0.1',
                                       '--port', str(port), '--state', str(directory / 'state.db'),
                                       '--publish-name', name, '--publish-address', '127.0.0.1'],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.assertIn('Published', server.stdout.readline())
                self.assertIn('Listening on TLS port', server.stdout.readline())
                self.assertEqual(verify_published(name, host, port, 10), [host])
                url = candidate(name, host + '.', port, txt_bytes(['profile=' + PROFILE]))
                self.assertEqual(url, f'https://{host}:{port}/mcp')
                connection = http.client.HTTPSConnection(host, port, timeout=10,
                                                         context=ssl.create_default_context(cafile=str(cert)))
                body = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
                                   'params': {'protocolVersion': '2025-06-18'}})
                connection.request('POST', '/mcp', body=body, headers={'Authorization': 'Bearer ' + 't' * 48,
                                                                         'Content-Type': 'application/json'})
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                self.assertEqual(json.loads(response.read())['result']['protocolVersion'], '2025-06-18')
                connection.close()
            finally:
                server.terminate()
                server.wait(timeout=15)
                server.stdout.close()
                server.stderr.close()
            with self.assertRaises(PublicationError):
                verify_published(name, host, port, timeout=3)

    def test_server_withdraws_mismatching_advertisement(self):
        system = self.system_hostname()
        if system is None:
            self.skipTest('system LocalHostName is not a valid discovery hostname')
        with tempfile.TemporaryDirectory() as temp:
            directory = pathlib.Path(temp)
            wrong = 'not-' + system
            cert, key = make_cert(directory, wrong)
            token = directory / 'token'
            token.write_text('t' * 48, encoding='utf-8')
            token.chmod(0o600)
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                port = sock.getsockname()[1]
            name = 'PDSH srv ' + uuid.uuid4().hex[:8]
            result = subprocess.run([sys.executable, str(HERE / 'server.py'), '--cert', str(cert), '--key', str(key),
                                     '--token-file', str(token), '--hostname', wrong, '--listen', '127.0.0.1',
                                     '--port', str(port), '--state', str(directory / 'state.db'),
                                     '--publish-name', name, '--publish-timeout', '8'],
                                    capture_output=True, text=True, timeout=40)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn('srv_target_mismatch', result.stderr)
            self.assertNotIn('Listening on TLS port', result.stdout)
            # The withdrawn instance must no longer resolve.
            with self.assertRaises(PublicationError):
                verify_published(name, wrong, port, timeout=3)


if __name__ == '__main__':
    unittest.main()
