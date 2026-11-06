# SPDX-License-Identifier: MIT
import json
from pathlib import Path
import sqlite3
import unittest
from tasks import decode_task, enqueue, ensure_tables, accept, finish


class DeviceTaskTest(unittest.TestCase):
    def test_shared_tasks(self):
        path = Path(__file__).resolve().parents[2] / 'spec/device/v1/golden/task-cases.jsonl'
        for line in path.read_text(encoding='utf-8').splitlines():
            row = json.loads(line)
            with self.subTest(row['name']):
                try:
                    decode_task(row['task'])
                    accepted = True
                except (ValueError, UnicodeError):
                    accepted = False
                self.assertEqual(accepted, row['valid'])

    def test_device_inbox_deduplication_and_conflicts(self):
        con = sqlite3.connect(':memory:', isolation_level=None)
        ensure_tables(con)
        task = {'id': 'task:1', 'idempotency_key': 'key', 'requester': 'device', 'created_at': '2026-11-06T00:00:00Z', 'body': {'type': 'goal', 'text': 'hello'}}
        enqueue(con, task)
        enqueue(con, task)
        with self.assertRaises(ValueError):
            enqueue(con, {**task, 'id': 'other'})
        self.assertEqual(accept(con, 'task:1'), 204)
        self.assertEqual(accept(con, 'task:1'), 204)
        self.assertEqual(finish(con, 'task:1', 'complete', {'output': 'answer', 'truncated': False}), 204)
        self.assertEqual(finish(con, 'task:1', 'complete', {'output': 'answer', 'truncated': False}), 409)
        self.assertEqual(finish(con, 'task:1', 'complete', {'output': 'different', 'truncated': False}), 422)
        con.close()


if __name__ == '__main__':
    unittest.main()
