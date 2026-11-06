# SPDX-License-Identifier: MIT
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

    def test_invalid_txt_and_duplicate_case(self):
        self.assertIsNone(candidate('A', 'a.local.', 443, b'\x0atest'))
        self.assertIsNone(candidate('A', 'a.local.', 443, txt_bytes(['PROFILE=pdsh-mcp-1', 'profile=pdsh-mcp-1'])))
        self.assertEqual(candidate('A', 'A.local.', 443, b'\x01\xff' + txt_bytes(['PROFILE=pdsh-mcp-1'])), 'https://a.local/mcp')


if __name__ == '__main__':
    unittest.main()
