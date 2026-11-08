# SPDX-License-Identifier: MIT
import binascii
import json
import pathlib
import unittest
from discovery import candidate, txt_bytes


class DiscoveryTest(unittest.TestCase):
    def test_shared_vectors(self):
        path = pathlib.Path(__file__).resolve().parents[2] / 'spec/device/v1/golden/lan-discovery.jsonl'
        for line in path.read_text(encoding='utf-8').splitlines():
            row = json.loads(line)
            with self.subTest(row['name']):
                result = candidate(row['service'], row['host'], row['port'], txt_bytes(row['txt_records']))
                self.assertEqual(result, row.get('url'))

    def test_shared_raw_vectors(self):
        path = pathlib.Path(__file__).resolve().parents[2] / 'spec/device/v1/golden/lan-discovery-raw.jsonl'
        rows = [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines()]
        self.assertTrue(rows)
        by_name = {row['name']: row for row in rows}
        self.assertEqual(len(by_name), len(rows), 'raw vector names must be unique')
        required_valid = {'valid', 'case_and_binary_unknown', 'numeric_label_named_domain', 'hex_label_named_domain'}
        required_invalid = {
            'truncated', 'duplicate_case', 'unicode_kelvin_casefold', 'ipv4_dotted',
            'ipv4_short', 'ipv4_integer', 'ipv4_hex', 'ipv4_mixed_hex',
            'numeric_leading_zero', 'numeric_out_of_range', 'numeric_hostname',
            'hex_prefix_only', 'hex_prefix_short', 'ipv4_hex_empty_final',
            'named_numeric_final', 'named_hex_prefix_final', 'named_hex_final',
        }
        self.assertFalse((required_valid | required_invalid) - by_name.keys(), 'required raw vectors missing')
        for name in required_valid:
            self.assertIsInstance(by_name[name].get('url'), str, name)
        for name in required_invalid:
            self.assertEqual(by_name[name].get('error'), 'invalid_advertisement', name)
        for row in rows:
            with self.subTest(row['name']):
                self.assertNotEqual('url' in row, 'error' in row)
                if 'error' in row:
                    self.assertEqual(row['error'], 'invalid_advertisement')
                else:
                    self.assertIsInstance(row['url'], str)
                result = candidate(row['service'], row['host'], row['port'],
                                   binascii.unhexlify(row['txt_hex']))
                self.assertEqual(result, row.get('url'))

    def test_invalid_txt_and_duplicate_case(self):
        self.assertIsNone(candidate('A', 'a.local.', 443, b'\x0atest'))
        self.assertIsNone(candidate('A', 'a.local.', 443, txt_bytes(['PROFILE=pdsh-mcp-1', 'profile=pdsh-mcp-1'])))
        self.assertEqual(candidate('A', 'A.local.', 443, b'\x01\xff' + txt_bytes(['PROFILE=pdsh-mcp-1'])), 'https://a.local/mcp')

    def test_service_must_be_valid_bounded_utf8(self):
        profile = txt_bytes(['profile=pdsh-mcp-1'])
        self.assertIsNone(candidate('\ud800', 'a.local.', 443, profile))
        self.assertIsNone(candidate('界' * 22, 'a.local.', 443, profile))
        self.assertEqual(candidate('界' * 21, 'a.local.', 443, profile), 'https://a.local/mcp')


if __name__ == '__main__':
    unittest.main()
