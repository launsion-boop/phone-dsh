#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read-only localhost status board for a LAN reference-device prototype."""
import argparse
import html
import json
from pathlib import Path
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def latest_task(database: Path):
    # SQLite URI read-only mode plus query_only prevent modifications to the
    # reference device, including when the database file is missing.
    uri = database.resolve().as_uri() + '?mode=ro'
    with sqlite3.connect(uri, uri=True, timeout=1) as connection:
        connection.execute('PRAGMA query_only=ON')
        row = connection.execute('SELECT task, phase, terminal FROM tasks ORDER BY rowid DESC LIMIT 1').fetchone()
    if row is None:
        return None
    task, phase, terminal = row
    return json.loads(task), phase, json.loads(terminal) if terminal else None


def ble_result(path: Path):
    """Show only a complete result explicitly produced by the test peer."""
    try:
        if path.stat().st_size > 65536:
            return None
        result = json.loads(path.read_text(encoding='utf-8'))
        if not isinstance(result, dict) or result.get('transport') != 'ble' or result.get('phase') != 'completed':
            return None
        if result.get('device') != 'PDSHRT':
            return None
        if not isinstance(result.get('task'), str) or not isinstance(result.get('output'), str):
            return None
        return result
    except (OSError, ValueError, TypeError):
        return None


def page(database: Path, ble_path: Path = Path('/tmp/pdsh-prototype-ble-result.json')) -> bytes:
    try:
        record = latest_task(database)
        problem = None
    except (OSError, sqlite3.Error, ValueError, TypeError, json.JSONDecodeError):
        record, problem = None, '无法读取参考设备记录，请检查演示设备是否正在运行。'
    request = '等待设备提交任务'
    answer = '等待结果'
    status, detail, step = '等待任务', '参考设备尚无任务', 0
    if record:
        task, phase, terminal = record
        if not isinstance(task, dict):
            task = {}
        body = task.get('body')
        if not isinstance(body, dict):
            body = {}
        request = body.get('text') if isinstance(body.get('text'), str) else '无法读取任务内容'
        if phase in ('pending', 'queued'):
            status, detail, step = '等待手机接收', '设备已提交，等待手机确认', 1
        elif phase == 'accepted':
            status, detail, step = '手机已接收', '正在等待手机返回最终结果', 2
        elif phase == 'terminal' and isinstance(terminal, dict):
            outcome = terminal.get('body')
            if not isinstance(outcome, dict):
                outcome = {}
            if terminal.get('action') == 'complete':
                status, detail, step = '任务已完成', '结果已由设备保存', 3
                answer = outcome.get('output') if isinstance(outcome.get('output'), str) else '（空结果）'
            else:
                status, detail, step = '任务未完成', '设备已收到失败回执', 3
                failure = outcome.get('failure')
                answer = failure.get('message', '任务失败') if isinstance(failure, dict) else '任务失败'
        else:
            status, detail, step = '状态未知', '请检查设备任务记录', 0
    if problem:
        status, detail = '读取失败', problem
    def esc(value):
        return html.escape(str(value), quote=True)
    dots = ''.join(
        '<div class="stage {}"><span>{:02}</span><strong>{}</strong><small>{}</small></div>'.format(
            'active' if step >= index else '', index, title, description)
        for index, title, description in [
            (1, '设备提交', '局域网参考设备'),
            (2, '手机接收', 'phoneDSH 任务会话'),
            (3, '结果返回', '设备保存回执'),
        ]
    )
    ble = ble_result(ble_path)
    ble_status = '任务已完成' if ble else '尚未完成'
    ble_detail = '结果已由 Mac 蓝牙参考外设返回' if ble else '尚无已完成的蓝牙参考外设结果'
    ble_task = ble['task'] if ble else '等待蓝牙参考外设结果'
    ble_answer = ble['output'] if ble else '等待结果'
    ble_dots = ''.join(
        '<div class="stage {}"><span>{:02}</span><strong>{}</strong><small>{}</small></div>'.format(
            'active' if ble else '', index, title, description)
        for index, title, description in [
            (1, '设备提交', 'Mac 蓝牙参考外设'),
            (2, '手机接收', 'phoneDSH 任务会话'),
            (3, '结果返回', '参考外设确认'),
        ]
    )
    document = f'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="2"><title>phoneDSH 设备任务演示</title>
<style>
:root{{font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Microsoft YaHei",sans-serif;color:#172033;background:#f3f6fa}}
*{{box-sizing:border-box}}body{{margin:0;padding:48px 24px}}main{{max-width:1000px;margin:auto}}
header{{display:flex;align-items:center;gap:12px;color:#52627b;font-size:14px;font-weight:600;letter-spacing:.04em}}
.logo{{width:36px;height:36px;border-radius:11px;background:#2665e8;color:white;display:grid;place-items:center;font-size:17px}}
h1{{font-size:38px;letter-spacing:-.03em;margin:30px 0 10px}}.sub{{color:#67758b;margin:0 0 18px;line-height:1.7}}
.notice{{background:#fff7e7;border:1px solid #f1d9a5;border-radius:14px;padding:14px 18px;margin:0 0 20px;color:#73521b;font-size:14px;font-weight:600;line-height:1.7}}
.second{{margin-top:18px}}.panel{{background:white;border:1px solid #e4eaf2;border-radius:20px;padding:28px;box-shadow:0 12px 34px #1c355d0a}}
.top{{display:flex;align-items:flex-start;justify-content:space-between;gap:16px}}.eyebrow{{color:#77849a;font-size:13px;font-weight:600}}
.status{{font-size:24px;margin:8px 0 4px}}.detail{{color:#718098;font-size:14px}}.badge{{padding:8px 12px;border-radius:99px;background:#eef5ff;color:#255ed1;font-size:13px;white-space:nowrap}}
.flow{{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin:28px 0}}.stage{{border:1px solid #e9edf4;border-radius:14px;padding:18px;display:flex;flex-direction:column;gap:7px;color:#9ba8ba}}
.stage.active{{border-color:#b9d1ff;background:#f7faff;color:#1d56bd}}.stage span{{font-size:12px;font-weight:700}}.stage strong{{font-size:16px}}.stage small{{font-size:12px}}
.cards{{display:grid;grid-template-columns:1fr 1fr;gap:14px}}.card{{background:#f7f9fc;border-radius:14px;padding:20px;min-height:142px}}.label{{font-size:13px;color:#7a899e;font-weight:600}}.value{{margin-top:14px;font-size:19px;line-height:1.6;white-space:pre-wrap;overflow-wrap:anywhere}}.answer{{color:#1c5dc9}}
footer{{color:#8491a4;font-size:12px;line-height:1.8;margin-top:20px}}@media(max-width:600px){{body{{padding:24px 14px}}h1{{font-size:28px}}.panel{{padding:18px}}.flow{{gap:6px}}.stage{{padding:10px}}.cards{{grid-template-columns:1fr}}}}
</style></head><body><main>
<header><span class="logo">↗</span> phoneDSH · 设备互联</header>
<h1>设备任务演示</h1><p class="sub">设备提交任务，手机上的 DSH 处理后，将结果返回设备。</p>
<div class="notice">本演示只提交文本并返回模型回答；设备会话当前没有手机控制工具。模型内容仅供展示，实际可用能力以接入和授权为准。</div>
<section class="panel"><div class="top"><div><div class="eyebrow">实时状态</div><div class="status">{esc(status)}</div><div class="detail">{esc(detail)}</div></div><span class="badge">局域网 · 测试原型</span></div>
<div class="flow">{dots}</div><div class="cards"><div class="card"><div class="label">设备请求</div><div class="value">{esc(request)}</div></div><div class="card"><div class="label">设备收到的结果</div><div class="value answer">{esc(answer)}</div></div></div></section>
<section class="panel second"><div class="top"><div><div class="eyebrow">蓝牙参考外设</div><div class="status">{esc(ble_status)}</div><div class="detail">{esc(ble_detail)}</div></div><span class="badge">蓝牙 · Mac 参考外设</span></div>
<div class="flow">{ble_dots}</div><div class="cards"><div class="card"><div class="label">设备请求</div><div class="value">{esc(ble_task)}</div></div><div class="card"><div class="label">设备收到的结果</div><div class="value answer">{esc(ble_answer)}</div></div></div></section>
<footer>此页面只读展示参考设备的实际任务记录，每 2 秒刷新；状态不能证明手机当前在线。<br>演示使用临时证书和测试专用授权；正式 App 的设备派任务入口尚未开放。<br>蓝牙结果来自 Mac 参考外设，不代表实体 ESP32 已通过。</footer>
</main></body></html>'''
    return document.encode('utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--db', type=Path, required=True, help='LAN reference-device SQLite state')
    parser.add_argument('--port', type=int, default=18765)
    parser.add_argument('--ble-result', type=Path, default=Path('/tmp/pdsh-prototype-ble-result.json'))
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error('--port must be in 1..65535')
    database = args.db
    ble_path = args.ble_result

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != '/':
                self.send_error(404)
                return
            content = page(database, ble_path)
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(content)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(content)

        def log_message(self, format, *args):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    print(f'Prototype board: http://127.0.0.1:{args.port}/', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
