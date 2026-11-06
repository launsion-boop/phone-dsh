# SPDX-License-Identifier: MIT
"""Device task inbox validation and durable storage."""
import datetime
import json
import re
import sqlite3
import unicodedata

IDENTIFIER = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$')
UTC_TIME = re.compile(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$')
FAILURES = {'denied', 'unavailable', 'expired', 'failed', 'unknown_outcome'}


def decode_task(task):
    def contains_nul(value):
        if isinstance(value, str):
            return '\x00' in value
        if isinstance(value, list):
            return any(contains_nul(item) for item in value)
        if isinstance(value, dict):
            return any(contains_nul(key) or contains_nul(item) for key, item in value.items())
        return False
    if contains_nul(task):
        raise ValueError('NUL in task')
    if not isinstance(task, dict):
        raise ValueError('invalid task')
    task_id, key, requester, created, body = (task.get(k) for k in ('id', 'idempotency_key', 'requester', 'created_at', 'body'))
    if not isinstance(task_id, str) or not IDENTIFIER.fullmatch(task_id) or not isinstance(key, str) or not IDENTIFIER.fullmatch(key):
        raise ValueError('invalid task identity')
    if not isinstance(requester, str) or not 1 <= len(requester.encode('utf-8')) <= 128 or any(unicodedata.category(c) in {'Cc', 'Cf'} for c in requester):
        raise ValueError('invalid requester')
    def timestamp(value):
        if not isinstance(value, str) or not 20 <= len(value.encode()) <= 35 or not UTC_TIME.fullmatch(value):
            raise ValueError('invalid time')
        return datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
    created_date = timestamp(created)
    deadline = task.get('deadline')
    if 'deadline' in task and deadline is None:
        raise ValueError('invalid deadline')
    if deadline is not None and timestamp(deadline) <= created_date:
        raise ValueError('invalid deadline')
    if not isinstance(body, dict) or body.get('type') != 'goal':
        raise ValueError('unsupported task type')
    text = body.get('text')
    if not isinstance(text, str) or not 1 <= len(text.encode('utf-8')) <= 768 or any(unicodedata.category(c) in {'Cc', 'Cf'} and c not in '\n\r\t' for c in text):
        raise ValueError('invalid goal text')
    result = {'id': task_id, 'idempotency_key': key, 'requester': requester, 'created_at': created, 'body': {'type': 'goal', 'text': text}}
    if deadline is not None:
        result['deadline'] = deadline
    return result


def ensure_tables(con):
    con.execute('CREATE TABLE IF NOT EXISTS tasks (id TEXT PRIMARY KEY, task_key TEXT UNIQUE NOT NULL, task TEXT NOT NULL, phase TEXT NOT NULL, terminal TEXT)')


def enqueue(con, task):
    task = decode_task(task)
    encoded = json.dumps(task, sort_keys=True, separators=(',', ':'), ensure_ascii=False)
    con.execute('BEGIN IMMEDIATE')
    try:
        existing = con.execute('SELECT task FROM tasks WHERE id=? OR task_key=?', (task['id'], task['idempotency_key'])).fetchone()
        if existing:
            if existing[0] != encoded:
                raise ValueError('task identity conflict')
        else:
            if con.execute('SELECT COUNT(*) FROM tasks').fetchone()[0] >= 4096:
                raise ValueError('task store full')
            con.execute('INSERT INTO tasks VALUES (?,?,?,?,NULL)', (task['id'], task['idempotency_key'], encoded, 'pending'))
        con.execute('COMMIT')
    except Exception:
        con.execute('ROLLBACK')
        raise


def accept(con, task_id):
    con.execute('BEGIN IMMEDIATE')
    try:
        row = con.execute('SELECT phase FROM tasks WHERE id=?', (task_id,)).fetchone()
        if row is None:
            result = 404
        elif row[0] == 'terminal':
            result = 422
        else:
            con.execute("UPDATE tasks SET phase='accepted' WHERE id=?", (task_id,))
            result = 204
        con.execute('COMMIT')
        return result
    except Exception:
        con.execute('ROLLBACK')
        raise


def finish(con, task_id, action, body):
    if action == 'complete':
        if not isinstance(body, dict) or set(body) != {'output', 'truncated'} or not isinstance(body['output'], str) or '\x00' in body['output'] or len(body['output'].encode('utf-8')) > 1024 or type(body['truncated']) is not bool:
            return 400
    elif action == 'fail':
        if not isinstance(body, dict) or set(body) != {'failure'} or not isinstance(body['failure'], dict):
            return 400
        failure = body['failure']
        if set(failure) != {'kind', 'message'} or failure['kind'] not in FAILURES or not isinstance(failure['message'], str) or '\x00' in failure['message'] or len(failure['message'].encode('utf-8')) > 256:
            return 400
    else:
        return 404
    terminal = json.dumps({'action': action, 'body': body}, sort_keys=True, separators=(',', ':'), ensure_ascii=False)
    con.execute('BEGIN IMMEDIATE')
    try:
        row = con.execute('SELECT phase, terminal FROM tasks WHERE id=?', (task_id,)).fetchone()
        if row is None:
            status = 404
        elif row[0] == 'terminal':
            status = 409 if row[1] == terminal else 422
        elif row[0] != 'accepted':
            status = 422
        else:
            con.execute("UPDATE tasks SET phase='terminal', terminal=? WHERE id=?", (terminal, task_id))
            status = 204
        con.execute('COMMIT')
        return status
    except Exception:
        con.execute('ROLLBACK')
        raise
