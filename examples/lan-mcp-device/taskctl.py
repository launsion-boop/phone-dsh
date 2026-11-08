#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Submit or inspect reference-device tasks from the device's local process."""
import argparse
import datetime
import json
import uuid
from server import db
from tasks import enqueue


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', required=True)
    sub = parser.add_subparsers(dest='action', required=True)
    submit = sub.add_parser('submit')
    submit.add_argument('--text', required=True)
    submit.add_argument('--id', default=None)
    submit.add_argument('--key', default=None)
    submit.add_argument('--requester', default='device')
    sub.add_parser('list')
    args = parser.parse_args()
    con = db(args.state)
    try:
        if args.action == 'submit':
            task_id = args.id or str(uuid.uuid4())
            task = {'id': task_id, 'idempotency_key': args.key or task_id, 'requester': args.requester,
                    'created_at': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                    'body': {'type': 'goal', 'text': args.text}}
            enqueue(con, task)
            print(task_id)
        else:
            for task, phase, terminal in con.execute('SELECT task, phase, terminal FROM tasks ORDER BY rowid'):
                print(json.dumps({'task': json.loads(task), 'phase': phase, 'terminal': json.loads(terminal) if terminal else None}, ensure_ascii=False))
    finally:
        con.close()


if __name__ == '__main__':
    main()
