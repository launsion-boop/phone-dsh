#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Checker for the P09 Bot UI-state seam (`spec/ui/v1/bot/ui-state.md`).

Validates the value-type schemas, the shared vectors (recomputing every expected
value with an independent implementation of the normative rules), the strings
and activity-phrase data, the pure-data fixture export, and every `source`
anchor (`File.swift:line` + an `expect` snippet that must still be on that line).

Usage:
    python3 spec/ui/v1/bot/tools/check_bot_ui.py --root .

Exit code 0 on success, 1 on any mismatch, 2 on a usage or I/O error.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit, unquote

BOT_REL = Path("spec") / "ui" / "v1" / "bot"
PROBE_BOT_REL = Path("examples") / "probe-app" / "PhoneDSHProbe" / "Bot"


class CheckError(Exception):
    pass


_ROOT = None
_PH = None
_ST = None
_RULES = None
_CATS = None
_PRIMARY = None
_ROTATION = None
_SPEC_GOLDEN = None


def configure(root: Path) -> None:
    global _ROOT, _PH, _ST, _RULES, _CATS, _PRIMARY, _ROTATION, _SPEC_GOLDEN
    _ROOT = root
    _PH = load_json(root / BOT_REL / "activity-phrases.json")
    strings = load_json(root / BOT_REL / "strings.json")
    _ST = {e["id"]: e["value"] for e in strings["strings"]}
    _CATS = [c["category"] for c in _PH["categories"]]
    _PRIMARY = {c["category"]: c["primary"]["value"] for c in _PH["categories"]}
    _ROTATION = {c["category"]: [p["value"] for p in c["rotation"]] for c in _PH["categories"]}
    _RULES = {r["tool"]: r for r in _PH["toolRules"]}
    _SPEC_GOLDEN = _load_spec_golden(root)
    _bind()


def _load_spec_golden(root: Path):
    path = root / "spec" / "v1" / "tools" / "spec_golden.py"
    spec = importlib.util.spec_from_file_location("bot_ui_spec_golden", path)
    if spec is None or spec.loader is None:
        raise CheckError(f"cannot load shared validator from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def load_json(path: Path):
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise CheckError(f"{path}: cannot read: {exc}") from exc
    try:
        return json.loads(text, object_pairs_hook=_pairs_no_duplicates)
    except json.JSONDecodeError as exc:
        raise CheckError(f"{path}: invalid JSON: {exc}") from exc


def _pairs_no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise CheckError(f"duplicate JSON member {key!r}")
        result[key] = value
    return result


def schema(name: str):
    return load_json(_ROOT / BOT_REL / "schema" / name)


def validate(instance, schema_doc, where: str):
    try:
        _SPEC_GOLDEN.validate_json(instance, schema_doc, where)
    except _SPEC_GOLDEN.SpecError as exc:
        raise CheckError(str(exc)) from exc


# ---------------------------------------------------------------------------
# Independent reference implementation of the normative derived-state rules.
# This is deliberately separate from the Swift implementation: the vectors are
# the shared contract, and this code is the checker's reading of it.
# ---------------------------------------------------------------------------

ST = None
PH = None
CATS = None
PRIMARY = None
ROTATION = None
RULES = None


def _bind():
    global ST, PH, CATS, PRIMARY, ROTATION, RULES
    ST, PH = _ST, _PH
    CATS, PRIMARY, ROTATION, RULES = _CATS, _PRIMARY, _ROTATION, _RULES
MOTION_STANDARD = 'standard'

def s(body, *keys):
    for k in keys:
        v = body.get(k)
        if isinstance(v, str) and v != '':
            return v
    return None

def trimmed(v):
    return v.strip()

def parse_choice(v, index):
    if isinstance(v, str):
        label = v.strip()
        if not label:
            return None
        return {'id': f'{index}:{label}', 'label': label, 'value': label,
                'description': None, 'recommended': False, 'danger': False}
    if not isinstance(v, dict):
        return None
    raw = s(v, 'label', 'text', 'title', 'value')
    if raw is None:
        return None
    label = raw.strip()
    if not label:
        return None
    explicit = s(v, 'id', 'optionID') or ''
    cid = explicit if explicit else f'{index}:{raw}'
    style = (v.get('style') if isinstance(v.get('style'), str) else 'default').lower()
    value = v['value'] if isinstance(v.get('value'), str) else label
    desc = s(v, 'description', 'detail')
    recommended = (v.get('recommended') is True or style == 'primary') and style != 'danger'
    return {'id': cid, 'label': label, 'value': value, 'description': desc,
            'recommended': recommended, 'danger': style == 'danger'}

def parse_choices(value, limit=4):
    if not isinstance(value, list):
        return []
    out = []
    for i, item in enumerate(value[:limit]):
        c = parse_choice(item, i)
        if c is not None:
            out.append(c)
    ri = next((i for i, c in enumerate(out) if c['recommended'] and not c['danger']), None)
    for i in range(len(out)):
        out[i]['recommended'] = (i == ri)
    return out

ALIASES = {'in_progress': 'active', 'running': 'active', 'working': 'active',
           'complete': 'done', 'completed': 'done', 'success': 'done', 'ok': 'done', 'sent': 'done',
           'error': 'failed', 'failure': 'failed', 'blocked': 'failed'}
ALLOWED_STEP = {'pending', 'active', 'done', 'failed', 'skipped'}

def parse_steps(value, limit=8):
    if not isinstance(value, list):
        return []
    out = []
    for i, item in enumerate(value[:limit]):
        if isinstance(item, str):
            if item:
                out.append({'id': f'step-{i}', 'label': item, 'state': 'pending', 'detail': None})
            continue
        if not isinstance(item, dict):
            continue
        label = s(item, 'label', 'title', 'text')
        if not label:
            continue
        raw = item.get('state') if isinstance(item.get('state'), str) else (
            item.get('status') if isinstance(item.get('status'), str) else 'pending')
        state = ALIASES.get(raw, raw)
        out.append({'id': s(item, 'id') or f'step-{i}', 'label': label,
                    'state': state if state in ALLOWED_STEP else 'pending',
                    'detail': s(item, 'detail', 'meta', 'note')})
    return out

def parse_checklist(value, limit=12):
    if not isinstance(value, list):
        return []
    out = []
    for i, item in enumerate(value[:limit]):
        if isinstance(item, str):
            if item:
                out.append({'id': f'item-{i}', 'text': item, 'done': False, 'note': None, 'synthetic': False})
            continue
        if not isinstance(item, dict):
            continue
        text = s(item, 'text', 'content', 'label', 'title')
        if not text:
            continue
        out.append({'id': s(item, 'id') or f'item-{i}', 'text': text,
                    'done': item.get('done') is True, 'note': s(item, 'note', 'meta', 'due'),
                    'synthetic': item.get('synthetic') is True})
    return out

def parse_links(value, limit=4):
    if not isinstance(value, list):
        return []
    out = []
    for i, item in enumerate(value[:limit]):
        if not isinstance(item, dict):
            continue
        raw = item.get('url')
        if not isinstance(raw, str) or len(raw.encode('utf-16-le')) // 2 > 2048:
            continue
        try:
            parts = urlsplit(raw)
        except ValueError:
            continue
        scheme = (parts.scheme or '').lower()
        host = parts.hostname or ''
        if scheme not in ('http', 'https') or not host:
            continue
        site = s(item, 'site') or (host[4:] if host.startswith('www.') else host)
        out.append({'id': s(item, 'id') or f'link-{i}', 'url': raw,
                    'title': s(item, 'title', 'name', 'label') or site, 'site': site,
                    'description': s(item, 'description', 'summary', 'note'),
                    'kind': (item.get('kind') if isinstance(item.get('kind'), str) else 'other')})
    return out

def attachment_kind(name, mime=''):
    ext = name.rsplit('.', 1)[-1].lower() if '.' in name else ''
    if mime.startswith('image/') or ext in ('png', 'jpg', 'jpeg', 'gif', 'webp', 'heic'):
        return 'image'
    if mime.startswith('audio/') or ext in ('mp3', 'm4a', 'wav'):
        return 'audio'
    if mime.startswith('video/') or ext in ('mp4', 'mov'):
        return 'video'
    if mime == 'application/pdf' or ext == 'pdf':
        return 'pdf'
    if ext in ('md', 'markdown'):
        return 'markdown'
    if ext in ('csv', 'tsv', 'xls', 'xlsx'):
        return 'table'
    if ext == 'json':
        return 'json'
    if ext in ('zip', 'tar', 'gz', '7z'):
        return 'archive'
    if ext in ('doc', 'docx', 'txt', 'rtf'):
        return 'document'
    return 'file'

def parse_attachments(value, limit=10):
    if not isinstance(value, list):
        return []
    out = []
    for item in value[:limit]:
        if not isinstance(item, dict):
            continue
        name = s(item, 'name', 'fileName')
        if not name:
            continue
        mime = item.get('mimeType') if isinstance(item.get('mimeType'), str) else ''
        size = item.get('size')
        size = int(max(0, size)) if isinstance(size, (int, float)) and not isinstance(size, bool) else 0
        out.append({'name': name, 'path': item.get('path') if isinstance(item.get('path'), str) else '',
                    'size': size, 'mimeType': mime,
                    'kind': (item.get('kind') if isinstance(item.get('kind'), str) else attachment_kind(name, mime))})
    return out

def card_parse(row):
    b = row.get('body') or {}
    t = b.get('type')
    kind = None
    if t == 'widget':
        ct = b.get('cardType')
        if ct not in ('question', 'steps', 'task', 'document', 'progress', 'checklist', 'link'):
            return None
        kind = ct
    elif t == 'attachment':
        if b.get('cardType') not in (None, 'attachment'):
            return None
        kind = 'attachment'
    elif t in ('approval', 'automation', 'notice'):
        kind = t
    else:
        return None
    return {'kind': kind, 'body': b} if card_valid(kind, b) else None

def card_valid(kind, b):
    ask = b.get('ask') if isinstance(b.get('ask'), dict) else {}
    if kind in ('question', 'steps'):
        choices = parse_choices(b.get('options' if kind == 'question' else 'steps'))
        prompt = s(b, 'question', 'prompt', 'helpText', 'help') or ''
        return bool(choices) or bool(prompt.strip())
    if kind == 'task':
        title = s(b, 'title', 'text', 'question') or ''
        steps = b.get('tasks') if isinstance(b.get('tasks'), list) else (
            b.get('steps') if isinstance(b.get('steps'), list) else [])
        return bool(title) or bool(steps)
    if kind == 'attachment':
        return bool(s(b, 'fileName', 'name', 'path'))
    if kind == 'document':
        return bool(s(b, 'title', 'name', 'fileName', 'path', 'url', 'summary', 'content'))
    if kind == 'progress':
        return bool(s(b, 'title', 'name'))
    if kind == 'checklist':
        return bool(s(b, 'title')) and bool(parse_checklist(b.get('items')))
    if kind == 'link':
        return bool(parse_links(b.get('links')))
    if kind == 'approval':
        status = (b.get('status') if isinstance(b.get('status'), str) else (
            ask.get('status') if isinstance(ask.get('status'), str) else 'pending'))
        action = s(b, 'action', 'title', 'text') or (ask.get('action') if isinstance(ask.get('action'), str) else '') or ''
        if status == 'pending':
            ident = s(b, 'approvalID', 'requestId', 'id') or (ask.get('requestId') if isinstance(ask.get('requestId'), str) else None)
            digest = b.get('digest') if isinstance(b.get('digest'), str) else None
            return bool(ident) and bool(digest) and bool(action)
        return bool(action)
    if kind == 'automation':
        name = s(b, 'title', 'name', 'automationId')
        if not name and isinstance(b.get('automation'), dict):
            name = s(b['automation'], 'name', 'automationId')
        return bool(name)
    if kind == 'notice':
        tone = (b.get('tone') if isinstance(b.get('tone'), str) else 'error')
        text = b.get('text') if isinstance(b.get('text'), str) else ''
        return tone in ('error', 'denied', 'denial') and bool(text.strip())
    return False

def is_renderable(row):
    b = row.get('body') or {}
    if b.get('type') == 'deleted':
        return False
    if b.get('type') == 'text':
        text = b.get('text') if isinstance(b.get('text'), str) else ''
        has_text = bool(text.strip())
        has_attach = row.get('role') == 'user' and bool(parse_attachments(b.get('attachments')))
        return row.get('kind') in ('message', 'sendMessage') and row.get('role') in ('user', 'assistant') and (has_text or has_attach)
    return card_parse(row) is not None

def visible_rows(inp):
    return [r for r in inp['rows'] if is_renderable(r) and (r.get('body') or {}).get('type') != 'notice']

def action_state(inp, key):
    return inp['actionStates'].get(key)

def settlement(inp, row):
    card = card_parse(row)
    if card is None:
        return None
    kind = card['kind']
    b = card['body']
    rid = row['id']
    if kind in ('question', 'steps'):
        st = action_state(inp, f'card:{rid}')
        if st in ('pending', 'failed'):
            return None
        prompt = s(b, 'question', 'prompt')
        detail = prompt.strip() if prompt else None
        if not detail:
            detail = ST['settlement.stepsSuggestion'] if kind == 'steps' else None
        status = b.get('status') if isinstance(b.get('status'), str) else None
        if rid in inp['dismissedCardIDs'] or status == 'dismissed':
            return settle('xmark.circle', ST['settlement.dismissed'], detail)
        if st == 'accepted' or status == 'answered':
            label = chosen_label(inp, row, card)
            title = ST['settlement.selected'].format(label=label) if label else ST['settlement.sent']
            return settle('checkmark.circle', title, detail)
        if rid in muted_ids(inp, visible_rows(inp)):
            return settle('minus.circle', ST['settlement.skipped'], detail)
        return None
    if kind == 'checklist':
        if b.get('interactive') is False:
            return None
        prog = inp['checklistProgress'].get(rid)
        if prog and prog.get('sending') is True:
            return None
        items = parse_checklist(b.get('items'))
        done = prog['done'] if prog else sum(1 for i in items if i['done'])
        total = prog['total'] if prog else len(items)
        title = b.get('title') if isinstance(b.get('title'), str) else ''
        detail = ST['settlement.checklistDetail'].format(title=title, done=done, total=total)
        if prog and prog.get('sent') is True:
            return settle('checkmark.circle', ST['settlement.checklistSent'], detail)
        if rid in muted_ids(inp, visible_rows(inp)):
            return settle('minus.circle', ST['settlement.skipped'], detail)
        return None
    if kind == 'approval':
        st = action_state(inp, f'approval:{rid}')
        if st in ('pending', 'failed'):
            return None
        ask = b.get('ask') if isinstance(b.get('ask'), dict) else {}
        status = b.get('status') if isinstance(b.get('status'), str) else (
            ask.get('status') if isinstance(ask.get('status'), str) else 'pending')
        action = s(b, 'action', 'title', 'text') or (ask.get('action') if isinstance(ask.get('action'), str) else '') or ST['settlement.approvalDefaultAction']
        command = s(b, 'command', 'target') or (ask.get('target') if isinstance(ask.get('target'), str) else '') or ''
        detail = command if command else action
        mono = bool(command)
        auto = rid in inp['autoDeclinedApprovalIDs']
        if auto:
            return settle('xmark.circle', ST['settlement.approvalAutoDeclined'], detail, 'neutral', mono)
        if status == 'pending':
            return None
        allowed = status in ('allowed', 'always')
        scope = s(b, 'alwaysScope') or (ask.get('alwaysScope') if isinstance(ask.get('alwaysScope'), str) else None) or 'until'
        if status == 'allowed':
            title = ST['settlement.approvalAllowedOnce']
        elif status == 'always':
            title = ST['settlement.approvalSessionAllowed'] if scope == 'session' else ST['settlement.approvalAlways']
        elif status in ('denied', 'never'):
            title = ST['settlement.approvalDenied']
        elif status == 'timed-out':
            title = ST['settlement.approvalTimedOut']
        elif status == 'expired':
            title = ST['settlement.approvalExpired']
        else:
            title = ST['settlement.approvalHandled']
        return settle('checkmark.circle.fill' if allowed else 'xmark.circle', title, detail,
                      'success' if allowed else 'neutral', mono)
    return None

def settle(glyph, title, detail, tone='neutral', mono=False):
    return {'glyph': glyph, 'title': title, 'detail': detail, 'tone': tone, 'monospacedDetail': mono}

def chosen_label(inp, row, card):
    b = card['body']
    oid = b.get('answeredOptionID') if isinstance(b.get('answeredOptionID'), str) else inp['answeredOptionIDs'].get(row['id'])
    if not oid:
        return None
    key = 'steps' if card['kind'] == 'steps' else 'options'
    for c in parse_choices(b.get(key)):
        if c['id'] == oid:
            return c['label']
    return None

def muted_ids(inp, vis):
    last = None
    for i, r in enumerate(vis):
        if r.get('role') == 'user' and (r.get('body') or {}).get('type') == 'text':
            last = i
    if last is None:
        return []
    out = []
    for r in vis[:last]:
        card = card_parse(r)
        if card is None or card['kind'] not in ('question', 'steps', 'checklist'):
            continue
        if action_state(inp, f'card:{r["id"]}') is not None:
            continue
        if card['kind'] == 'checklist':
            p = inp['checklistProgress'].get(r['id'])
            if p and (p.get('sending') or p.get('sent')):
                continue
            if card['body'].get('interactive') is False:
                continue
        out.append(r['id'])
    return out

def approval_status(row):
    b = row.get('body') or {}
    ask = b.get('ask') if isinstance(b.get('ask'), dict) else {}
    if isinstance(b.get('status'), str):
        return b['status']
    if isinstance(ask.get('status'), str):
        return ask['status']
    return 'pending'

def counts(inp, vis):
    pending = 0
    for r in vis:
        if (r.get('body') or {}).get('type') != 'approval':
            continue
        if approval_status(r) != 'pending':
            continue
        st = action_state(inp, f'approval:{r["id"]}')
        if st in ('pending', 'accepted'):
            continue
        pending += 1
    attention = pending
    for r in vis:
        card = card_parse(r)
        if card is None:
            continue
        if card['kind'] in ('question', 'steps'):
            st = action_state(inp, f'card:{r["id"]}')
            if st != 'pending' and settlement(inp, r) is None:
                attention += 1
        elif card['kind'] == 'checklist':
            if card['body'].get('interactive') is False:
                continue
            p = inp['checklistProgress'].get(r['id'])
            if p and p.get('sending') is True:
                continue
            if settlement(inp, r) is None:
                attention += 1
    if inp['context']['followingCount'] is not None:
        following = inp['context']['followingCount']
    else:
        following = 0
        for r in vis:
            card = card_parse(r)
            if card is None:
                continue
            b = card['body']
            if card['kind'] == 'automation':
                st = b.get('status') if isinstance(b.get('status'), str) else (
                    b['automation'].get('status') if isinstance(b.get('automation'), dict) and isinstance(b['automation'].get('status'), str) else 'sent')
                if st in ('running', 'confirming'):
                    following += 1
            elif card['kind'] == 'progress':
                st = b.get('state') if isinstance(b.get('state'), str) else 'running'
                if st == 'running':
                    following += 1
            elif card['kind'] == 'task':
                st = b.get('status') if isinstance(b.get('status'), str) else (
                    b['task'].get('status') if isinstance(b.get('task'), dict) and isinstance(b['task'].get('status'), str) else '')
                if st in ('running', 'active', 'in_progress', 'working'):
                    following += 1
    return pending, attention, following

def problem_text(raw):
    if not raw:
        return None
    parts = [p.strip() for p in raw.splitlines()]
    parts = [p for p in parts if p]
    return ST['header.problem.join'].join(parts) if parts else None

def working_fish(state):
    return 'thinking' if state in ('idle', 'sleeping', 'standby', 'waking', 'done') else state

def unexpired_one_shot(presentation, now):
    if not isinstance(presentation, dict):
        return None
    shot = presentation.get('oneShot')
    if isinstance(shot, dict) and shot.get('endsAt', 0) > now:
        return shot
    return None

def fish_lifecycle(inp, pending):
    """The one shared projection (ui-state.md §4.7)."""
    if pending > 0:
        return 'alerting'
    now = inp['now']
    shot = (unexpired_one_shot(inp['livePresentation'], now)
            or unexpired_one_shot(inp['runtimePresentation'], now))
    if shot is not None:
        return shot['state']
    live_turn = inp['live'] is not None
    if live_turn and isinstance(inp['livePresentation'], dict):
        base = inp['livePresentation'].get('fishState') or 'idle'
    else:
        base = inp['runtimePresentation'].get('fishState') or 'idle'
    if inp['running']:
        return 'working' if base == 'idle' else base
    if inp['idleSleeping']:
        return 'sleeping'
    return base

def action_retry_allowed(action, card_kind, state):
    """ui-state.md §3.1 retry policy; `None` means the key is absent."""
    if action == 'dismiss':
        return card_kind == 'question' and state in (None, 'failed')
    if action == 'answer':
        return state in (None, 'failed')
    if action == 'approval':
        return state in (None, 'failed')
    return False

def work_style(cat):
    return PH['workStyle'][cat]['value']

def header(inp, turn_active, line, pending, fish):
    prob = problem_text(inp['problem'])
    if prob is not None:
        return {'phase': 'problem', 'line': act('thinking', prob, 'generic', 0), 'fishState': fish,
                'motion': 'standard', 'workStyle': 'generic',
                'lineIsQuiet': True, 'lineIsProblem': True}
    if turn_active and line is not None:
        return {'phase': 'working', 'line': line, 'fishState': working_fish(fish),
                'motion': 'lively', 'workStyle': work_style(line['category']),
                'lineIsQuiet': line['category'] == 'waiting', 'lineIsProblem': False}
    if pending > 0:
        text = '' if pending == 1 else ST['header.waiting.plural'].format(count=pending)
        return {'phase': 'waitingForYou', 'line': act('thinking', text, 'waiting', 0), 'fishState': fish,
                'motion': 'standard', 'workStyle': 'generic',
                'lineIsQuiet': True, 'lineIsProblem': False}
    return {'phase': 'idle', 'line': None, 'fishState': fish, 'motion': 'standard',
            'workStyle': 'generic', 'lineIsQuiet': False, 'lineIsProblem': False}

def act(status, detail, category, started):
    return {'status': status, 'detail': detail, 'category': category, 'startedAt': started}

def shows_activity(inp):
    if inp['awaitingTurn']:
        return True
    if inp['runningTurnID'] is not None:
        return True
    live = inp['live']
    return live is not None and not live['ended'] and not inp['lineSuppressed']

def streaming_now(inp):
    if inp['streaming']['pendingDelta']:
        return True
    if inp['streaming']['streamingText']:
        return True
    live = inp['live']
    return live is not None and bool(inp['streaming']['liveBuffer'].strip())

def line_activity(inp, pending):
    if not shows_activity(inp):
        return None
    if pending > 0:
        return act('thinking', '', 'waiting', 0)
    if streaming_now(inp):
        return act('streaming', '', 'replying', 0)
    if inp['live'] is not None:
        pres = inp['livePresentation']
        factory = pres.get('activity') if isinstance(pres, dict) else None
    else:
        factory = inp['runtimePresentation'].get('activity')
    if factory is not None:
        return factory
    return act('thinking', '', 'thinking', 0)

def sustained(activity, now):
    start = activity.get('startedAt', 0)
    if start <= 0 or now < start:
        return 0
    elapsed = now - start
    if elapsed < 60000:
        return 0
    return max(1, elapsed // 60000)

def next_minute(start, now):
    if now < start + 60000:
        return start + 60000
    return start + ((now - start) // 60000 + 1) * 60000

def activity_line(activity, now):
    if activity is None:
        return {'text': '', 'nextDeadline': None}
    detail = activity.get('detail', '')
    if detail:
        base = detail
        phrases = [detail]
    else:
        phrases = ROTATION[activity['category']]
        base = phrases[0]
    minutes = sustained(activity, now)
    text = base + ST['activity.minutes'].format(minutes=minutes) if minutes > 0 else base
    deadlines = []
    if not detail and len(phrases) > 1:
        deadlines.append(now + PH['timing']['rotationIntervalMillis']['value'])
    start = activity.get('startedAt', 0)
    if start > 0:
        deadlines.append(next_minute(start, now))
    deadlines = [d for d in deadlines if d > now]
    return {'text': text, 'nextDeadline': min(deadlines) if deadlines else None}

def relative_time(ms, now):
    if ms is None or ms == 0:
        return ST['drawer.noMessages']
    seconds = (now - ms) / 1000.0
    if seconds < 60:
        return '刚刚'
    if seconds < 3600:
        return f'{int(seconds // 60)} 分钟前'
    if seconds < 86400:
        return f'{int(seconds // 3600)} 小时前'
    # Calendar-dependent branch is not exercised by pinned vectors.
    return 'M月d日'

def drawer_status(inp, pending, vis):
    d = inp['drawer']
    if pending > 0:
        text, color = ST['drawer.pending'].format(count=pending), 'warning'
    elif d['isRunning']:
        activity = None
        # roster activity is separate from the chat line; vectors put it in drawer.activity
        activity = d.get('activity')
        if activity is not None and activity.get('detail'):
            text = activity['detail']
        elif activity is not None:
            text = PRIMARY[activity['category']]
        else:
            text = {'thinking': ST['drawer.state.thinking'], 'working': ST['drawer.state.working'],
                    'speaking': ST['drawer.state.replying'], 'streaming': ST['drawer.state.replying'],
                    'alerting': ST['drawer.state.alerting'], 'sleeping': ST['drawer.state.sleeping']}.get(
                        d.get('fishState', 'idle'), ST['drawer.state.running'])
        color = 'secondary'
    else:
        text = relative_time(d['lastMessageAt'], inp['now'])
        color = 'secondary'
    return {'text': text, 'color': color}

def unread_badge(inp):
    n = inp['drawer']['unreadCount']
    if n <= 0:
        return {'shown': False, 'text': '', 'accessibility': ''}
    return {'shown': True, 'text': '99+' if n > 99 else str(n),
            'accessibility': ST['drawer.unread'].format(count=n)}

def derive(inp):
    vis = visible_rows(inp)
    live = inp['live']
    display = [r for r in vis if not (
        live is not None and live.get('turn') is not None and r.get('role') == 'assistant'
        and (r.get('body') or {}).get('type') == 'text' and (r.get('body') or {}).get('turn') == live['turn'])]
    muted = muted_ids(inp, vis)
    settlements = []
    for r in display:
        st = settlement(inp, r)
        if st is not None:
            settlements.append({'rowID': r['id'], **st})
    pending, attention, following = counts(inp, vis)
    fish = fish_lifecycle(inp, inp['pendingApprovalCount'])
    turn_active = shows_activity(inp)
    line = line_activity(inp, pending)
    hdr = header(inp, turn_active, line, pending, fish)
    return {
        'visibleRowIDs': [r['id'] for r in vis],
        'displayRowIDs': [r['id'] for r in display],
        'mutedCardIDs': muted,
        'settledRowIDs': [s['rowID'] for s in settlements],
        'settlements': settlements,
        'pendingApprovalCount': pending,
        'needsAttentionCount': attention,
        'followingCount': following,
        'fishState': fish,
        'header': hdr,
        'lineActivity': line,
        'activityLine': activity_line(hdr['line'], inp['now']),
        'drawerStatus': drawer_status(inp, pending, vis),
        'unreadBadge': unread_badge(inp),
    }

def tool_activity(tool, args):
    bare = tool
    if tool.startswith('mcp__'):
        parts = tool.split('__')
        if len(parts) > 2:
            bare = '__'.join(parts[2:])
    rule = RULES.get(bare.lower())
    if rule is None:
        rule = {'category': 'generic', 'phrase': '', 'targetKeys': [], 'targetIsURL': False, 'targetArray': False}
    model_text = None
    for k in ('description', 'summary', 'label'):
        v = args.get(k)
        if isinstance(v, str) and v.strip():
            model_text = v
            break
    if model_text is not None:
        return {'category': rule['category'], 'text': cleaned_model_text(model_text)}
    if rule['category'] == 'generic':
        return {'category': 'generic', 'text': ''}
    target = ''
    for k in rule['targetKeys']:
        v = args.get(k)
        if rule['targetArray'] and isinstance(v, list):
            first = next((x for x in v if isinstance(x, str) and x), None)
            if first is not None:
                target = short_target(first); break
            continue
        if isinstance(v, str) and v:
            if rule['targetIsURL']:
                host = url_host(v)
                if host is not None:
                    target = short_target(host); break
            target = short_target(v); break
    phrase = rule['phrase']
    return {'category': rule['category'], 'text': phrase if not target else f'{phrase} · {target}'}

def cleaned_model_text(raw):
    text = raw.strip()
    punctuation = '。！？!?；;，,、.…'
    while text and text[-1] in punctuation:
        text = text[:-1]
    text = text.strip()
    if not text:
        return None
    if len(text) > 20:
        return text[:19] + '…'
    return text

def short_target(value):
    text = value.strip()
    parts = [p for p in re.split(r'[/\\]', text) if p]
    base = parts[-1] if parts else text
    return base[:39] + '…' if len(base) > 42 else base

def url_host(value):
    trimmed = value.strip()
    candidate = trimmed if '://' in trimmed else 'https://' + trimmed
    try:
        host = urlsplit(candidate).hostname
    except ValueError:
        return None
    if not host:
        return None
    return host[4:] if host.startswith('www.') else host

def utf16_len(text):
    return len(text.encode('utf-16-le')) // 2

def name_problem(name):
    value = name.strip()
    if not value:
        return ST['validation.name.empty'], None
    if utf16_len(value) > 60:
        return ST['validation.name.tooLong'].format(max=60, count=utf16_len(value)), None
    return None, value

def name_capped(name):
    if utf16_len(name) <= 60:
        return name
    out = ''
    units = 0
    for ch in name:
        width = utf16_len(ch)
        if units + width > 60:
            break
        out += ch
        units += width
    return out

def parse_deep_link(url):
    try:
        p = urlsplit(url)
    except ValueError:
        return None
    if p.scheme != 'phonedsh' or p.netloc != 'bot':
        return None
    comps = [unquote(x) for x in p.path.split('/') if x not in ('', '/')]
    if len(comps) != 3 or not comps[0] or not comps[2]:
        return None
    if comps[1] == 'row':
        return {'botID': comps[0], 'destination': {'kind': 'row', 'id': comps[2]}}
    if comps[1] == 'routine':
        return {'botID': comps[0], 'destination': {'kind': 'routine', 'id': comps[2]}}
    return None

def surface(row):
    if not is_renderable(row):
        return 'hidden'
    b = row.get('body') or {}
    if b.get('type') == 'text':
        return 'bubble'
    card = card_parse(row)
    if card is None:
        return 'hidden'
    return {'question': 'widget-card', 'steps': 'widget-card', 'task': 'agent-thread-row',
            'attachment': 'attachment-card', 'document': 'document-card', 'progress': 'progress-card',
            'checklist': 'checklist-card', 'link': 'link-card', 'approval': 'approval-card',
            'automation': 'automation-row', 'notice': 'notice'}[card['kind']]

def copy_text(row):
    b = row.get('body') or {}
    if isinstance(b.get('text'), str) and b['text']:
        return b['text']
    for k in ('title', 'question', 'prompt', 'name', 'fileName', 'path', 'summary'):
        v = b.get(k)
        if isinstance(v, str) and v:
            return v
    return row['id']


# ---------------------------------------------------------------------------
# Anchor and document checks.
# ---------------------------------------------------------------------------

SOURCE_RE = re.compile(r"^([A-Za-z0-9_./-]+\.swift):(\d+)$")
RANGE_RE = re.compile(r"^([A-Za-z0-9_./-]+\.swift):(\d+)(?:-(\d+))?$")
GOLDEN_GLOB = "*.json"
GOLDEN_FILES = (
    "ui-state-vectors.json", "card-parse-vectors.json", "activity-phrase-vectors.json",
    "invalid-vectors.json", "value-vectors.json", "fixtures.json",
)
SCHEMA_NAMES = (
    "row.schema.json", "row-batch.schema.json", "activity.schema.json",
    "presentation.schema.json", "header-presence.schema.json",
    "runtime-state.schema.json", "roster-runtime-state.schema.json",
    "roster-entry.schema.json", "info.schema.json", "drawer-intent.schema.json",
    "info-intent.schema.json", "appearance-intent.schema.json",
    "deep-link.schema.json", "ui-state.schema.json",
)


def _read_probe_source(relative: str) -> list[str]:
    path = _ROOT / PROBE_BOT_REL / relative
    if not path.is_file():
        raise CheckError(f"source file does not exist: {path}")
    return path.read_text(encoding="utf-8").splitlines()


def check_anchor(relative: str, line: int, expect: str, where: str) -> None:
    lines = _read_probe_source(relative)
    if line < 1 or line > len(lines):
        raise CheckError(f"{where}: {relative}:{line} is outside the file")
    if expect and expect not in lines[line - 1]:
        raise CheckError(
            f"{where}: {relative}:{line} does not contain the expected snippet {expect!r}: "
            f"{lines[line - 1].strip()!r}")


def check_source_expression(source: str, where: str) -> None:
    """Resolve `File.swift:line[-line]` (probe-relative or repo-relative) and
    `path/to/file.json[:line]` anchors used by the vector `source` fields."""
    if not isinstance(source, str) or not source:
        raise CheckError(f"{where}: source must be a non-empty string")
    for item in source.split(","):
        item = item.strip()
        match = RANGE_RE.match(item)
        if match is not None:
            relative, first, last = match.group(1), int(match.group(2)), match.group(3)
            lines = _read_probe_source(relative) if "/" not in relative else _read_repo_lines(relative)
            upper = int(last) if last is not None else first
            if first < 1 or upper < first or upper > len(lines):
                raise CheckError(f"{where}: source anchor {item!r} is outside {relative}")
            continue
        path_match = re.match(r"^([A-Za-z0-9_./-]+\.(?:json|md|py))(:(\d+))?$", item)
        if path_match is None:
            raise CheckError(f"{where}: malformed source anchor {item!r}")
        relative = path_match.group(1)
        path = _ROOT / relative
        if not path.is_file():
            raise CheckError(f"{where}: source file does not exist: {relative}")
        if path_match.group(3) is not None:
            line = int(path_match.group(3))
            lines = path.read_text(encoding="utf-8").splitlines()
            if line < 1 or line > len(lines):
                raise CheckError(f"{where}: source anchor {item!r} is outside {relative}")


def _read_repo_lines(relative: str) -> list[str]:
    path = _ROOT / relative
    if not path.is_file():
        raise CheckError(f"source file does not exist: {path}")
    return path.read_text(encoding="utf-8").splitlines()


def check_doc() -> int:
    path = _ROOT / BOT_REL / "ui-state.md"
    text = path.read_text(encoding="utf-8")
    required = (
        "Status: **normative for both ends**",
        "Android: **planned (wave 4 round 2)**",
        "## 1. Driver and page surfaces",
        "## 2. Presentation value types",
        "## 3. Intents",
        "## 4. Derived-state rules (view-owned, pure)",
        "### 4.7 Fish lifecycle — normative",
        "BotFishLifecycleProjection.resolve",
        "Status: DECIDED",
        "CONTRACT CHANGE REQUEST",
        "## 8. Conformance status",
        "**NOT_RUN**",
    )
    for phrase in required:
        if phrase not in text:
            raise CheckError(f"ui-state.md misses required phrase {phrase!r}")
    if "BotChatDriver" not in text or "BotHeaderPresence" not in text:
        raise CheckError("ui-state.md must name BotChatDriver and BotHeaderPresence")
    return len(required)


def check_strings() -> int:
    doc = load_json(_ROOT / BOT_REL / "strings.json")
    if doc.get("schemaVersion") != 1:
        raise CheckError("strings.json schemaVersion must be 1")
    if doc.get("sourceRoot") != "examples/probe-app/PhoneDSHProbe/Bot":
        raise CheckError("strings.json sourceRoot must be the probe Bot directory")
    seen = set()
    for entry in doc.get("strings", []):
        where = f"strings.json[{entry.get('id')}]"
        sid = entry.get("id")
        if not isinstance(sid, str) or not re.fullmatch(r"[a-z][A-Za-z0-9.]*", sid):
            raise CheckError(f"{where}: invalid id")
        if sid in seen:
            raise CheckError(f"{where}: duplicate id")
        seen.add(sid)
        if not isinstance(entry.get("value"), str):
            raise CheckError(f"{where}: value must be a string")
        source = entry.get("source")
        match = SOURCE_RE.match(source or "")
        if match is None:
            raise CheckError(f"{where}: malformed source {source!r}")
        check_anchor(match.group(1), int(match.group(2)), entry.get("expect", ""), where)
        if entry.get("expect") == "":
            raise CheckError(f"{where}: expect must be a non-empty snippet")
        placeholders = set(re.findall(r"\{([a-z][a-z0-9_]*)\}", entry["value"]))
        if "{" in re.sub(r"\{[a-z][a-z0-9_]*\}", "", entry["value"]):
            raise CheckError(f"{where}: unbalanced placeholder braces")
        if "activity.minutes" == sid and not placeholders == {"minutes"}:
            raise CheckError(f"{where}: expected a {{minutes}} placeholder")
    if len(seen) < 100:
        raise CheckError(f"strings.json has only {len(seen)} entries; the seam strings are incomplete")
    return len(seen)


def check_activity_phrases() -> int:
    doc = load_json(_ROOT / BOT_REL / "activity-phrases.json")
    expected_categories = ["thinking", "reading", "searching", "browsing", "running", "writing",
                           "memory", "messaging", "reviewing", "waiting", "replying", "generic"]
    got = [c.get("category") for c in doc.get("categories", [])]
    if got != expected_categories:
        raise CheckError(f"activity categories are {got}, expected {expected_categories}")
    count = 0
    for category in doc["categories"]:
        where = f"activity-phrases.categories[{category['category']}]"
        primary = category.get("primary") or {}
        if primary.get("value") != _ST.get(f"activity.{category['category']}.primary"):
            raise CheckError(f"{where}: primary phrase disagrees with strings.json")
        match = SOURCE_RE.match(primary.get("source", ""))
        if match is None:
            raise CheckError(f"{where}: malformed primary source")
        check_anchor(match.group(1), int(match.group(2)), primary.get("expect", ""), where)
        rotation = category.get("rotation") or []
        if not rotation:
            raise CheckError(f"{where}: rotation must not be empty")
        if category["category"] == "waiting" and len(rotation) != 1:
            raise CheckError(f"{where}: waiting has exactly one phrase")
        if category["category"] in ("thinking", "reviewing", "replying", "generic") and len(rotation) != 3:
            raise CheckError(f"{where}: expected three rotation phrases")
        for index, phrase in enumerate(rotation):
            match = SOURCE_RE.match(phrase.get("source", ""))
            if match is None:
                raise CheckError(f"{where}: malformed rotation source")
            check_anchor(match.group(1), int(match.group(2)), phrase.get("expect", ""), where)
            expected_id = f"activity.{category['category']}.rotation.{index}"
            if expected_id in _ST and _ST[expected_id] != phrase.get("value"):
                raise CheckError(f"{where}: rotation {index} disagrees with strings.json")
            count += 1
    rules = doc.get("toolRules", [])
    if len(rules) != 70:
        raise CheckError(f"activity-phrases has {len(rules)} tool rules, expected 70")
    seen = set()
    for rule in rules:
        where = f"activity-phrases.toolRules[{rule.get('tool')}]"
        tool = rule.get("tool")
        if not isinstance(tool, str) or not tool or tool in seen:
            raise CheckError(f"{where}: tool names must be unique and non-empty")
        seen.add(tool)
        if rule.get("category") not in expected_categories:
            raise CheckError(f"{where}: unknown category")
        if not isinstance(rule.get("phrase"), str) or not rule["phrase"]:
            raise CheckError(f"{where}: phrase must be non-empty")
        if not isinstance(rule.get("targetKeys"), list) or not all(
                isinstance(k, str) and k for k in rule["targetKeys"]):
            raise CheckError(f"{where}: targetKeys must be a string array")
        match = SOURCE_RE.match(rule.get("source", ""))
        if match is None:
            raise CheckError(f"{where}: malformed source")
        check_anchor(match.group(1), int(match.group(2)), rule.get("expect", ""), where)
    if set(doc.get("workStyle", {})) != set(expected_categories):
        raise CheckError("activity-phrases workStyle must cover all twelve categories")
    for category, entry in doc["workStyle"].items():
        if entry.get("value") not in ("generic", "reading", "searching", "running", "writing"):
            raise CheckError(f"activity-phrases.workStyle[{category}]: invalid style")
        match = SOURCE_RE.match(entry.get("source", ""))
        if match is None:
            raise CheckError(f"activity-phrases.workStyle[{category}]: malformed source")
        check_anchor(match.group(1), int(match.group(2)), entry.get("expect", ""), where)
    timing = doc.get("timing", {})
    for key, value in (("minimumVisibleMillis", 800), ("rotationIntervalMillis", 2400),
                       ("minuteMillis", 60000)):
        if timing.get(key, {}).get("value") != value:
            raise CheckError(f"activity-phrases.timing.{key} must be {value}")
        entry = timing[key]
        match = SOURCE_RE.match(entry.get("source", ""))
        if match is None:
            raise CheckError(f"activity-phrases.timing.{key}: malformed source")
        check_anchor(match.group(1), int(match.group(2)), entry.get("expect", ""), where)
    if timing.get("minuteSuffixTemplate", {}).get("value") != _ST.get("activity.minutes"):
        raise CheckError("activity minute suffix disagrees with strings.json")
    policy = doc.get("textPolicy", {})
    if policy.get("maxCharacters") != 20 or policy.get("truncateAt") != 19:
        raise CheckError("activity text cap must be 19 + ellipsis = 20")
    if policy.get("targetMaxCharacters") != 42 or policy.get("targetTruncateAt") != 39:
        raise CheckError("activity target cap must be 39 + ellipsis = 42")
    for entry in policy.get("sources", []):
        match = SOURCE_RE.match(entry.get("source", ""))
        if match is None:
            raise CheckError("activity textPolicy source is malformed")
        check_anchor(match.group(1), int(match.group(2)), entry.get("expect", ""), where)
    return count + len(rules)


def check_schemas() -> int:
    for name in SCHEMA_NAMES:
        path = _ROOT / BOT_REL / "schema" / name
        if not path.is_file():
            raise CheckError(f"missing schema {name}")
        doc = load_json(path)
        if doc.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
            raise CheckError(f"{name}: must be draft 2020-12")
        if not doc.get("title"):
            raise CheckError(f"{name}: title is required")
        if "type" not in doc and "oneOf" not in doc:
            raise CheckError(f"{name}: needs type or oneOf")
        text = path.read_text(encoding="utf-8")
        if '"$ref"' in text:
            raise CheckError(f"{name}: $ref is not supported by the shared validator; keep schemas self-contained")
    return len(SCHEMA_NAMES)


SCHEMA_FILES = {
    "row": "row.schema.json",
    "row-batch": "row-batch.schema.json",
    "activity": "activity.schema.json",
    "presentation": "presentation.schema.json",
    "header-presence": "header-presence.schema.json",
    "runtime-state": "runtime-state.schema.json",
    "roster-runtime-state": "roster-runtime-state.schema.json",
    "roster-entry": "roster-entry.schema.json",
    "info": "info.schema.json",
    "drawer-intent": "drawer-intent.schema.json",
    "info-intent": "info-intent.schema.json",
    "appearance-intent": "appearance-intent.schema.json",
    "deep-link": "deep-link.schema.json",
    "ui-state": "ui-state.schema.json",
}


def _schema(name: str):
    return schema(SCHEMA_FILES[name])


def validate_presentation(value, where: str) -> None:
    validate(value, _schema("presentation"), where)
    if isinstance(value, dict) and value.get("activity") is not None:
        validate(value["activity"], _schema("activity"), where + ".activity")


def check_value_vectors() -> int:
    doc = load_json(_ROOT / BOT_REL / "golden" / "value-vectors.json")
    if doc.get("vector") != "value-types":
        raise CheckError("value-vectors.json vector must be value-types")
    seen = set()
    for case in doc.get("cases", []):
        cid = case.get("id")
        if not isinstance(cid, str) or not cid or cid in seen:
            raise CheckError("value-vectors: ids must be unique and non-empty")
        seen.add(cid)
        name = case.get("schema")
        if name not in SCHEMA_FILES:
            raise CheckError(f"value-vectors[{cid}]: unknown schema {name!r}")
        validate(case["value"], _schema(name), f"value-vectors[{cid}]")
        if name == "roster-entry":
            runtime = case["value"].get("runtime") or {}
            validate(runtime, _schema("roster-runtime-state"), f"value-vectors[{cid}].runtime")
            validate(runtime.get("runtimeState"), _schema("runtime-state"),
                     f"value-vectors[{cid}].runtime.runtimeState")
            if runtime.get("activity") is not None:
                validate(runtime["activity"], _schema("activity"), f"value-vectors[{cid}].runtime.activity")
        if name == "info-intent" and case["value"].get("kind") == "saveProactiveSettings":
            info = _schema("info")
            validate(case["value"]["settings"], info["properties"]["proactiveSettings"],
                     f"value-vectors[{cid}].settings")
    return len(seen)


def _compare(actual, expected, where: str) -> None:
    if actual == expected:
        return
    if isinstance(actual, dict) and isinstance(expected, dict):
        keys = sorted(set(actual) | set(expected))
        for key in keys:
            if key not in actual:
                raise CheckError(f"{where}.{key}: missing from computed state")
            if key not in expected:
                raise CheckError(f"{where}.{key}: unexpected in expected state")
            if actual[key] != expected[key]:
                _compare(actual[key], expected[key], f"{where}.{key}")
    if isinstance(actual, list) and isinstance(expected, list):
        if len(actual) != len(expected):
            raise CheckError(f"{where}: computed {actual!r}, expected {expected!r}")
        for index, (left, right) in enumerate(zip(actual, expected)):
            if left != right:
                _compare(left, right, f"{where}[{index}]")
    raise CheckError(f"{where}: computed {actual!r}, expected {expected!r}")


def check_ui_state_vectors() -> int:
    doc = load_json(_ROOT / BOT_REL / "golden" / "ui-state-vectors.json")
    validate(doc, _schema("ui-state"), "ui-state-vectors")
    now = doc.get("now")
    seen = set()
    covers = set()
    for case in doc["cases"]:
        cid = case["id"]
        if cid in seen:
            raise CheckError(f"ui-state[{cid}]: duplicate id")
        seen.add(cid)
        covers.update(case.get("covers", []))
        where = f"ui-state[{cid}]"
        check_source_expression(case["source"], where)
        inp = case["input"]
        if inp["now"] != now:
            raise CheckError(f"{where}: input.now must equal the pinned top-level now")
        for index, row in enumerate(inp["rows"]):
            validate(row, _schema("row"), f"{where}.rows[{index}]")
            if isinstance(row.get("body"), dict) and row["body"].get("type") in (
                    "text", "widget", "attachment", "approval", "automation", "notice", "deleted"):
                pass
        validate_presentation(inp["runtimePresentation"], f"{where}.runtimePresentation")
        if inp["livePresentation"] is not None:
            validate_presentation(inp["livePresentation"], f"{where}.livePresentation")
        computed = derive(inp)
        _compare(computed, case["expected"], where + ".expected")
        if inp["pendingApprovalCount"] != computed["pendingApprovalCount"]:
            raise CheckError(
                f"{where}: input.pendingApprovalCount is not the derived count "
                f"({inp['pendingApprovalCount']} != {computed['pendingApprovalCount']})")
        if computed["header"]["line"] is not None:
            validate(computed["header"]["line"], _schema("activity"), f"{where}.header.line")
    if len(seen) < 20:
        raise CheckError(f"ui-state-vectors has only {len(seen)} cases; the derived rules are under-covered")
    required_covers = {
        "priority.pending", "priority.one-shot", "priority.live-over-durable",
        "priority.running-idle-to-working", "priority.running-keeps-non-idle",
        "priority.idle-sleeping", "priority.idle-default",
    }
    missing = required_covers - covers
    if missing:
        raise CheckError(
            f"ui-state-vectors misses projection priority coverage {sorted(missing)}")

    intents = doc.get("intentCases", [])
    if len(intents) < 6:
        raise CheckError("ui-state-vectors.intentCases is under-covered")
    seen_intents = set()
    intent_tuples = set()
    for case in intents:
        cid = case["id"]
        if cid in seen_intents:
            raise CheckError(f"intent[{cid}]: duplicate id")
        seen_intents.add(cid)
        where = f"intent[{cid}]"
        check_source_expression(case["source"], where)
        accepted = action_retry_allowed(
            case["action"], case["cardKind"], case["state"])
        if accepted is not case["accepted"]:
            raise CheckError(
                f"{where}: action {case['action']!r} on {case['cardKind']!r} "
                f"with state {case['state']!r} must be "
                f"{'accepted' if accepted else 'rejected'}")
        intent_tuples.add((case["action"], case["cardKind"],
                           case["state"], case["accepted"]))
    required_intents = {
        ("dismiss", "question", None, True),
        ("dismiss", "question", "failed", True),
        ("dismiss", "question", "pending", False),
        ("dismiss", "question", "accepted", False),
        ("dismiss", "steps", None, False),
        ("answer", "question", "failed", True),
        ("approval", "question", "failed", True),
    }
    missing = required_intents - intent_tuples
    if missing:
        raise CheckError(
            f"ui-state-vectors misses retry coverage {sorted(missing)}")
    return len(seen) + len(intents)


def _card_expected(row):
    expected = {"renderable": is_renderable(row), "surface": surface(row), "copyText": copy_text(row)}
    card = card_parse(row)
    if card is not None:
        expected["kind"] = card["kind"]
        body = card["body"]
        if card["kind"] == "question":
            expected["choices"] = parse_choices(body.get("options"))
        if card["kind"] == "steps":
            expected["steps"] = parse_steps(body.get("steps"))
        if card["kind"] == "checklist":
            expected["checklist"] = parse_checklist(body.get("items"))
        if card["kind"] == "link":
            expected["links"] = parse_links(body.get("links"))
        if body.get("attachments") is not None:
            expected["attachments"] = parse_attachments(body["attachments"])
    return expected


def check_card_parse_vectors() -> int:
    doc = load_json(_ROOT / BOT_REL / "golden" / "card-parse-vectors.json")
    if doc.get("vector") != "card-parse":
        raise CheckError("card-parse-vectors.json vector must be card-parse")
    seen = set()
    for case in doc.get("cases", []):
        cid = case.get("id")
        if cid in seen:
            raise CheckError(f"card-parse[{cid}]: duplicate id")
        seen.add(cid)
        where = f"card-parse[{cid}]"
        check_source_expression(case["source"], where)
        validate(case["row"], _schema("row"), where + ".row")
        _compare(_card_expected(case["row"]), case["expected"], where + ".expected")
    if len(seen) < 25:
        raise CheckError(f"card-parse-vectors has only {len(seen)} cases")
    return len(seen)


def _reviewing_expected(tool, arguments):
    bare = tool
    if tool.startswith("mcp__"):
        parts = tool.split("__")
        if len(parts) > 2:
            bare = "__".join(parts[2:])
    rule = RULES.get(bare.lower())
    if rule is None or rule["category"] == "generic":
        return ""
    target = ""
    for key in rule["targetKeys"]:
        value = arguments.get(key)
        if rule["targetArray"] and isinstance(value, list):
            first = next((item for item in value if isinstance(item, str) and item), None)
            if first is not None:
                target = short_target(first)
                break
            continue
        if isinstance(value, str) and value:
            if rule["targetIsURL"]:
                host = url_host(value)
                if host is not None:
                    target = short_target(host)
                    break
            target = short_target(value)
            break
    return f"{PRIMARY['reviewing']} · {target}" if target else ""


def check_activity_vectors() -> int:
    doc = load_json(_ROOT / BOT_REL / "golden" / "activity-phrase-vectors.json")
    if doc.get("vector") != "activity-phrases":
        raise CheckError("activity-phrase-vectors.json vector must be activity-phrases")
    count = 0
    for case in doc.get("toolCases", []):
        where = f"activity-phrase[{case.get('id')}]"
        check_source_expression(case["source"], where)
        _compare(tool_activity(case["input"]["tool"], case["input"]["arguments"]),
                 case["expected"], where + ".expected")
        count += 1
    for case in doc.get("textCases", []):
        where = f"activity-text[{case.get('id')}]"
        check_source_expression(case["source"], where)
        _compare(cleaned_model_text(case["input"]["raw"]), case["expected"], where + ".expected")
        count += 1
    for case in doc.get("targetCases", []):
        where = f"activity-target[{case.get('id')}]"
        check_source_expression(case["source"], where)
        _compare(short_target(case["input"]["raw"]), case["expected"], where + ".expected")
        count += 1
    for case in doc.get("reviewingCases", []):
        where = f"activity-reviewing[{case.get('id')}]"
        check_source_expression(case["source"], where)
        _compare(_reviewing_expected(case["input"]["tool"], case["input"]["arguments"]),
                 case["expected"], where + ".expected")
        count += 1
    for case in doc.get("rotationCases", []):
        where = f"activity-rotation[{case.get('id')}]"
        check_source_expression(case["source"], where)
        expected = [case["detail"]] if case["detail"] else ROTATION[case["category"]]
        _compare(expected, case["expected"], where + ".expected")
        count += 1
    for case in doc.get("minuteCases", []):
        where = f"activity-minute[{case.get('id')}]"
        check_source_expression(case["source"], where)
        _compare(sustained({"startedAt": case["startedAt"]}, case["now"]),
                 case["expected"], where + ".expected")
        count += 1
    constants = doc.get("constants", {})
    if constants.get("rotationIntervalMillis") != PH["timing"]["rotationIntervalMillis"]["value"]:
        raise CheckError("activity vectors rotate at a different interval than the phrase table")
    if constants.get("minuteMillis") != PH["timing"]["minuteMillis"]["value"]:
        raise CheckError("activity vectors use a different minute than the phrase table")
    if len(doc.get("toolCases", [])) < 15:
        raise CheckError("activity vectors must cover at least 15 tool cases")
    return count


def check_invalid_vectors() -> int:
    doc = load_json(_ROOT / BOT_REL / "golden" / "invalid-vectors.json")
    if doc.get("vector") != "invalid":
        raise CheckError("invalid-vectors.json vector must be invalid")
    upstream = load_json(_ROOT / "spec" / "bot" / "v1" / "user-action.schema.json")
    seen = set()
    for case in doc.get("cases", []):
        cid = case.get("id")
        if not isinstance(cid, str) or cid in seen:
            raise CheckError("invalid-vectors: ids must be unique and non-empty")
        seen.add(cid)
        where = f"invalid[{cid}]"
        check_source_expression(case["source"], where)
        validator = case.get("validator")
        value = case.get("value")
        if validator is None or not case.get("reason"):
            raise CheckError(f"{where}: validator and reason are required")
        if validator.startswith("schema:"):
            name = validator.split(":", 1)[1]
            if name not in SCHEMA_FILES:
                raise CheckError(f"{where}: unknown schema {name!r}")
            try:
                validate(value, _schema(name), where)
            except CheckError:
                continue
            raise CheckError(f"{where}: value was accepted but must be rejected ({case['reason']})")
        if validator == "rule:user-action":
            try:
                validate(value, upstream, where)
            except CheckError:
                continue
            raise CheckError(f"{where}: user action was accepted but must be rejected")
        if validator == "rule:name-cap":
            problem, _ = name_problem(value)
            if problem is None:
                raise CheckError(f"{where}: name was accepted but must be rejected")
            continue
        if validator == "rule:deep-link":
            if parse_deep_link(value) is not None:
                raise CheckError(f"{where}: deep link parsed but must be rejected")
            continue
        if validator == "rule:action-retry":
            if not isinstance(value, dict):
                raise CheckError(f"{where}: value must be an action-retry object")
            if action_retry_allowed(value.get("action"), value.get("cardKind"),
                                    value.get("state")):
                raise CheckError(
                    f"{where}: action was accepted but must be rejected "
                    f"({case['reason']})")
            continue
        if validator == "rule:approval-renderability":
            row = {"id": "x", "body": value}
            if card_parse(row) is not None:
                raise CheckError(f"{where}: approval card parsed but must fail closed")
            continue
        if validator == "rule:card-parse":
            row = {"id": "x", "body": value}
            if card_parse(row) is not None:
                raise CheckError(f"{where}: card parsed but must fail closed")
            continue
        raise CheckError(f"{where}: unknown validator {validator!r}")
    if len(seen) < 20:
        raise CheckError(f"invalid-vectors has only {len(seen)} cases")
    return len(seen)


def _fixture_cases() -> list[str]:
    text = (_ROOT / PROBE_BOT_REL / "BotFixtures.swift").read_text(encoding="utf-8")
    match = re.search(r"enum BotUIFixtureCase: String, CaseIterable, Identifiable \{(.*?)\n\}",
                      text, re.S)
    if match is None:
        raise CheckError("BotFixtures.swift: cannot find BotUIFixtureCase")
    names = []
    for line in match.group(1).splitlines():
        line = line.strip()
        if not line.startswith("case "):
            continue
        for part in line[5:].split(","):
            name = part.strip()
            if re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", name):
                names.append(name)
    if not names:
        raise CheckError("BotFixtures.swift: BotUIFixtureCase has no cases")
    return names


def check_fixtures() -> int:
    doc = load_json(_ROOT / BOT_REL / "golden" / "fixtures.json")
    if doc.get("pinnedNow") != 1760000000000:
        raise CheckError("fixtures.json pinnedNow must be 1760000000000")
    exported = doc.get("exported", [])
    skipped = doc.get("skipped", [])
    seen = set()
    rows = 0
    for scenario in exported:
        sid = scenario.get("scenario")
        if not isinstance(sid, str) or sid in seen:
            raise CheckError("fixtures.json: exported scenario ids must be unique")
        seen.add(sid)
        for index, row in enumerate(scenario.get("rows", [])):
            if scenario.get("deliberatelyInvalidRows"):
                try:
                    validate(row, _schema("row"), f"fixtures[{sid}].rows[{index}]")
                except CheckError:
                    if is_renderable(row):
                        raise CheckError(
                            f"fixtures[{sid}].rows[{index}]: schema-invalid row is still renderable; "
                            "deliberatelyInvalidRows may only hide fail-closed rows")
            else:
                validate(row, _schema("row"), f"fixtures[{sid}].rows[{index}]")
            if row.get("createdAt", 0) < doc["pinnedNow"]:
                raise CheckError(f"fixtures[{sid}].rows[{index}]: timestamps must be pinned at or after pinnedNow")
            rows += 1
        if scenario.get("infoSnapshot") is not None:
            validate(scenario["infoSnapshot"], _schema("info"), f"fixtures[{sid}].infoSnapshot")
    for entry in skipped:
        if entry.get("scenario") in seen:
            raise CheckError(f"fixtures.json: {entry.get('scenario')} is both exported and skipped")
        if not entry.get("reason"):
            raise CheckError("fixtures.json: every skipped scenario needs a reason")
        seen.add(entry.get("scenario"))
    declared = set(_fixture_cases())
    missing = sorted(declared - seen)
    extra = sorted(seen - declared)
    if missing:
        raise CheckError("fixtures.json does not account for: " + ", ".join(missing))
    if extra:
        raise CheckError("fixtures.json names unknown fixture cases: " + ", ".join(extra))
    return len(exported) + len(skipped)


def check_golden_manifest() -> int:
    """Every golden JSON is read by this checker (the cross-tree reader glob is
    `*.json`); an unlisted file fails instead of silently skipping validation."""
    golden = _ROOT / BOT_REL / "golden"
    found = sorted(path.name for path in golden.glob(GOLDEN_GLOB) if path.is_file())
    if found != sorted(GOLDEN_FILES):
        missing = sorted(set(GOLDEN_FILES) - set(found))
        extra = sorted(set(found) - set(GOLDEN_FILES))
        raise CheckError(f"golden manifest mismatch: missing {missing}, unread {extra}")
    return len(found)


CHECKS = (
    ("golden-manifest", check_golden_manifest),
    ("doc", check_doc),
    ("strings", check_strings),
    ("activity-phrases", check_activity_phrases),
    ("schemas", check_schemas),
    ("value-vectors", check_value_vectors),
    ("ui-state-vectors", check_ui_state_vectors),
    ("card-parse-vectors", check_card_parse_vectors),
    ("activity-phrase-vectors", check_activity_vectors),
    ("invalid-vectors", check_invalid_vectors),
    ("fixtures", check_fixtures),
)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Check the P09 Bot UI-state seam")
    parser.add_argument("--root", default=".", help="repository root")
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()
    if not (root / BOT_REL / "ui-state.md").is_file():
        print(f"check_bot_ui: {root} is not a phone-dsh checkout", file=sys.stderr)
        return 2
    try:
        configure(root)
        total = 0
        for name, check in CHECKS:
            count = check()
            total += count
            print(f"  PASS  {name:<26} {count}")
    except CheckError as exc:
        print(f"check_bot_ui: FAIL: {exc}", file=sys.stderr)
        return 1
    print(f"check_bot_ui: ok ({total} checks/records)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
