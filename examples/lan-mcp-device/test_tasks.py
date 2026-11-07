# SPDX-License-Identifier: MIT
import json
from pathlib import Path
import sqlite3
import unittest
from tasks import decode_task, decode_task_json, enqueue, ensure_tables, accept, finish


class DeviceTaskTest(unittest.TestCase):
    def test_shared_raw_json(self):
        path = Path(__file__).resolve().parents[2] / 'spec/device/v1/golden/task-raw-json-cases.jsonl'
        for line in path.read_text(encoding='utf-8').splitlines():
            row = json.loads(line)
            con = sqlite3.connect(':memory:', isolation_level=None)
            ensure_tables(con)
            try:
                enqueue(con, row['json'])
                valid = True
            except (ValueError, UnicodeError):
                valid = False
            self.assertEqual(valid, row['valid'], row['name'])
            con.close()

    def test_unknown_strings_require_unicode_scalars_before_storage(self):
        task = {'id': 'task-1', 'idempotency_key': 'key-1', 'requester': 'sensor',
                'created_at': '2026-11-06T00:00:00Z', 'body': {'type': 'goal', 'text': 'Hello'}}
        for extra in ({'nested': ['\ud800']}, {'nested': ['\udc00']},
                      {'nested': {'\ud800': 'safe'}}, {'nested': {'\udc00': 'safe'}}):
            with self.subTest(extra=repr(extra)):
                con = sqlite3.connect(':memory:', isolation_level=None)
                try:
                    ensure_tables(con)
                    with self.assertRaises(ValueError):
                        enqueue(con, {**task, 'extra': extra})
                    self.assertEqual(con.execute('SELECT COUNT(*) FROM tasks').fetchone()[0], 0)
                finally:
                    con.close()
        # A valid supplementary scalar in an unknown key and value stays accepted.
        self.assertEqual(decode_task({**task, 'extra': {'😀': ['😀']}})['id'], 'task-1')

    def test_shared_raw_bytes(self):
        path = Path(__file__).resolve().parents[2] / 'spec/device/v1/golden/task-raw-bytes.jsonl'
        rows = [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines()]
        self.assertTrue(rows)
        for row in rows:
            with self.subTest(row['name']):
                con = sqlite3.connect(':memory:', isolation_level=None)
                try:
                    ensure_tables(con)
                    try:
                        enqueue(con, bytes.fromhex(row['hex']))
                        valid = True
                    except (ValueError, UnicodeError):
                        valid = False
                    self.assertEqual(valid, row['valid'])
                    self.assertEqual(con.execute('SELECT COUNT(*) FROM tasks').fetchone()[0], int(valid))
                finally:
                    con.close()

    def test_numbers_never_satisfy_known_string_fields(self):
        task = {'id': 'task-1', 'idempotency_key': 'key-1', 'requester': 'sensor',
                'created_at': '2026-11-06T00:00:00Z', 'body': {'type': 'goal', 'text': 'Hello'}}
        invalid = [{**task, key: 123} for key in ('id', 'idempotency_key', 'requester', 'created_at', 'deadline')]
        invalid += [{**task, 'body': 123}, {**task, 'body': {'type': 123, 'text': 'Hello'}},
                    {**task, 'body': {'type': 'goal', 'text': 123}}]
        for value in invalid:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    decode_task_json(json.dumps(value))
        raw = json.dumps(task).replace('"task-1"', '9' * 5000, 1)
        with self.assertRaises(ValueError):
            decode_task_json(raw)

    def test_shared_outcomes(self):
        path = Path(__file__).resolve().parents[2] / 'spec/device/v1/golden/task-outcome-cases.jsonl'
        for line in path.read_text(encoding='utf-8').splitlines():
            row = json.loads(line)
            con = sqlite3.connect(':memory:', isolation_level=None)
            ensure_tables(con)
            task = {'id': 'task-1', 'idempotency_key': 'key', 'requester': 'device', 'created_at': '2026-11-06T00:00:00Z', 'body': {'type': 'goal', 'text': 'hello'}}
            enqueue(con, task)
            self.assertEqual(accept(con, 'task-1'), 204)
            self.assertEqual(finish(con, 'task-1', row['action'], row['body']) == 204, row['valid'], row['name'])
            con.close()
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
