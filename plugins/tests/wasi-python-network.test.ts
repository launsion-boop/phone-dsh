// SPDX-License-Identifier: MIT
/**
 * G2-FIX-67 Python standard-library half: the `urllib`/`http.client` bridge
 * over the private `/__xl__/http` descriptor.
 *
 * These tests run the mounted Python shim source with the host `python3` and a
 * fake `_xl_http._call`. They prove the shim's HTTP semantics without a
 * network, a model or credentials. The last test is gated on
 * `PDSH_PYTHON_WASM`/`PDSH_PYTHON_STDLIB`: when a real CPython WASI pair is
 * present it runs the real `urllib` stack through `PythonRuntime` and a fake
 * synchronous `/v1/http` XHR; otherwise it skips with that reason. The Mac/CI
 * command for it is in docs/p1/python-urllib-http.md.
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import * as fsPromises from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { Worker } from 'node:worker_threads'
import { workerTransport } from '../wasi-toolbox/src/message-endpoint.ts'
import type { ToolWorkerTransport, WorkerLike } from '../wasi-toolbox/src/message-endpoint.ts'
import { NodeFsBackend } from '../wasi-toolbox/src/vfs-backends.ts'
import type { NodeFsPromisesLike } from '../wasi-toolbox/src/vfs-backends.ts'
import {
  PYTHON_CWD_SHIM_SOURCE,
} from '../wasi-toolbox/python/cwd-shim.ts'
import {
  PYTHON_HTTP_SHIM_FILENAME,
  PYTHON_HTTP_SHIM_SOURCE,
  pythonHttpShimFiles,
} from '../wasi-toolbox/python/http-shim.ts'
import { PythonRuntime } from '../wasi-toolbox/python/runtime.ts'
import type { LoopbackHttpRoute } from '../wasi-toolbox/src/http-bridge.ts'
import {
  PYTHON_SUBPROCESS_MODULE_SOURCE,
  pythonShimFiles,
} from '../wasi-toolbox/python/subprocess-shim.ts'

const python = process.env.PYTHON ?? 'python3'
const probe = spawnSync(python, ['--version'], { encoding: 'utf8' })
const NO_PYTHON = probe.status === 0
  ? false
  : `no host ${python} (${probe.error?.message ?? probe.stderr.trim()}); the Python shim tests are skipped`

const realWasmPath = process.env.PDSH_PYTHON_WASM
const realStdlibPath = process.env.PDSH_PYTHON_STDLIB
const REAL_WASI_SKIP = realWasmPath === undefined
  ? 'set PDSH_PYTHON_WASM and PDSH_PYTHON_STDLIB to a built CPython WASI pair'
  : realStdlibPath === undefined
    ? 'set PDSH_PYTHON_STDLIB to the python313.zip matching PDSH_PYTHON_WASM'
    : false

const scratch: string[] = []
after(() => {
  for (const root of scratch) rmSync(root, { recursive: true, force: true })
})

function shimDirectory(withHttpShim = true): string {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-python-network-'))
  scratch.push(root)
  writeFileSync(join(root, 'sitecustomize.py'), PYTHON_CWD_SHIM_SOURCE)
  if (withHttpShim) writeFileSync(join(root, PYTHON_HTTP_SHIM_FILENAME), PYTHON_HTTP_SHIM_SOURCE)
  return root
}

interface PythonRun {
  readonly status: number | null
  readonly stdout: string
  readonly stderr: string
}

function runPython(script: string, options: {
  readonly shimDir?: string
  readonly env?: Readonly<Record<string, string | undefined>>
} = {}): PythonRun {
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    PYTHONNOUSERSITE: '1',
    PYTHONDONTWRITEBYTECODE: '1',
  }
  delete env.PYTHONHOME
  delete env.PYTHONPATH
  delete env.PDSH_PYTHON_HTTP
  if (options.shimDir !== undefined) env.PYTHONPATH = options.shimDir
  for (const [name, value] of Object.entries(options.env ?? {})) {
    if (value === undefined) delete env[name]
    else env[name] = value
  }
  const result = spawnSync(python, ['-c', script], {
    encoding: 'utf8',
    env,
    timeout: 20_000,
  })
  return {
    status: result.status,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? '',
  }
}

test('http shim: the mounted layer carries _xl_http.py and sitecustomize gates it', () => {
  const files = pythonShimFiles()
  const http = files.find(file => file.path.endsWith(`/${PYTHON_HTTP_SHIM_FILENAME}`))
  assert.ok(http !== undefined)
  assert.equal(http.path, `/python-shims/${PYTHON_HTTP_SHIM_FILENAME}`)
  assert.match(http.source, /_BRIDGE_PATH = "\/__xl__\/http"/u)
  assert.match(http.source, /def install\(\):/u)
  assert.deepEqual(pythonHttpShimFiles().map(file => file.path), ['/python-shims/_xl_http.py'])
  assert.match(PYTHON_CWD_SHIM_SOURCE, /if os\.environ\.get\("PDSH_PYTHON_HTTP"\) == "1":/u)
  assert.match(PYTHON_CWD_SHIM_SOURCE, /_xl_http\.install\(\)/u)
  assert.match(PYTHON_SUBPROCESS_MODULE_SOURCE, /"PDSH_PYTHON_HTTP"/u)
})

test('http shim: without it, a simulated no-ssl interpreter reports unknown https and an http URLError', { skip: NO_PYTHON }, () => {
  const run = runPython(`
import sys
sys.modules["ssl"] = None
import urllib.request

try:
    urllib.request.urlopen("https://example.test/")
    print("https: ok")
except Exception as exc:
    print("https:", type(exc).__name__, str(exc))

try:
    urllib.request.urlopen("http://127.0.0.1:1/", timeout=2)
    print("http: ok")
except Exception as exc:
    print("http:", type(exc).__name__, str(exc))
`)
  assert.equal(run.status, 0, run.stderr)
  assert.match(run.stdout, /https: (?:ValueError|URLError) .*unknown url type: https/u)
  assert.match(run.stdout, /http: URLError/u)
})

test('http shim: response context managers close unread bytes and preserve exceptions', { skip: NO_PYTHON }, () => {
  const shim = shimDirectory()
  const run = runPython(`
import _xl_http
_xl_http._call = lambda *args, **kwargs: (200, "OK", [], b"hello")
_xl_http.install()
import urllib.request

with urllib.request.urlopen("https://example.test/context") as response:
    assert response.read(1) == b"h"
    assert not response.isclosed()
assert response.isclosed()
assert response.read() == b""

try:
    with urllib.request.urlopen("https://example.test/exception") as failed:
        raise RuntimeError("context sentinel")
except RuntimeError as error:
    assert str(error) == "context sentinel"
else:
    raise AssertionError("the response context suppressed the exception")
assert failed.isclosed()
print("response-context-ok")
`, { shimDir: shim, env: { PDSH_PYTHON_HTTP: '1' } })
  assert.equal(run.status, 0, run.stderr)
  assert.match(run.stdout, /response-context-ok/u)
})

test('http shim: urllib GET/POST/redirect/HTTPError and direct HTTPSConnection use _call', { skip: NO_PYTHON }, () => {
  const shim = shimDirectory()
  const run = runPython(`
import json
import _xl_http

calls = []

def fake(method, url, headers=None, body=b""):
    calls.append({
        "method": method,
        "url": url,
        "headers": dict(headers or {}),
        "body": bytes(body or b"").decode("latin-1"),
    })
    if url.endswith("/notfound"):
        return 404, "Not Found", [("Content-Type", "text/plain")], b"not here"
    if url.endswith("/error"):
        return 500, "Server Error", [], b"boom"
    if url.endswith("/redirect"):
        return 302, "Found", [("Location", "https://example.test/final")], b""
    if method.upper() == "HEAD":
        return 200, "OK", [("Content-Type", "text/plain")], b""
    return 200, "OK", [
        ("X-Multi", "a"),
        ("X-Multi", "b"),
        ("Content-Type", "text/plain"),
    ], b"hello"

_xl_http._call = fake
_xl_http.install()
_xl_http.install()

import http.client
import urllib.error
import urllib.request

result = {}

response = urllib.request.urlopen("https://example.test/a?x=1")
result["get"] = {
    "status": response.status,
    "multi": response.getheader("X-Multi"),
    "body": response.read().decode("latin-1"),
}

request = urllib.request.Request(
    "https://example.test/post",
    data=b"abc",
    headers={"X-Test": "v"},
    method="POST",
)
response = urllib.request.urlopen(request)
result["post"] = {
    "status": response.status,
    "body": response.read().decode("latin-1"),
}

response = urllib.request.urlopen("http://example.test/plain?y=2")
result["http"] = {
    "status": response.status,
    "body": response.read().decode("latin-1"),
}

response = urllib.request.urlopen(urllib.request.Request(
    "https://example.test/head",
    method="HEAD",
))
result["head"] = {
    "status": response.status,
    "body": response.read().decode("latin-1"),
}

for name, path in (("notfound", "/notfound"), ("error", "/error")):
    try:
        urllib.request.urlopen("https://example.test" + path)
        result[name] = {"unexpected": True}
    except urllib.error.HTTPError as exc:
        result[name] = {"code": exc.code, "body": exc.read().decode("latin-1")}

response = urllib.request.urlopen("https://example.test/redirect")
result["redirect"] = {
    "status": response.status,
    "url": response.geturl(),
    "body": response.read().decode("latin-1"),
}

connection = http.client.HTTPSConnection("example.test")
connection.request("GET", "/direct")
response = connection.getresponse()
result["direct"] = {
    "status": response.status,
    "reason": response.reason,
    "body": response.read().decode("latin-1"),
}
try:
    connection.set_tunnel("proxy.test", 8080)
    result["tunnel"] = "accepted"
except NotImplementedError:
    result["tunnel"] = "refused"
connection.close()

print(json.dumps({"result": result, "calls": calls}))
`, { shimDir: shim, env: { PDSH_PYTHON_HTTP: '1' } })
  assert.equal(run.status, 0, run.stderr)
  const payload = JSON.parse(run.stdout) as {
    result: Record<string, Record<string, unknown>>
    calls: { method: string; url: string; headers: Record<string, string>; body: string }[]
  }
  assert.deepEqual(payload.result['get'], { status: 200, multi: 'a, b', body: 'hello' })
  assert.deepEqual(payload.result['post'], { status: 200, body: 'hello' })
  assert.deepEqual(payload.result['http'], { status: 200, body: 'hello' })
  assert.deepEqual(payload.result['head'], { status: 200, body: '' })
  assert.deepEqual(payload.result['notfound'], { code: 404, body: 'not here' })
  assert.deepEqual(payload.result['error'], { code: 500, body: 'boom' })
  assert.deepEqual(payload.result['redirect'], {
    status: 200,
    url: 'https://example.test/final',
    body: 'hello',
  })
  assert.deepEqual(payload.result['direct'], { status: 200, reason: 'OK', body: 'hello' })
  assert.equal(payload.result['tunnel'], 'refused')

  const post = payload.calls.find(call => call.url === 'https://example.test/post')
  assert.ok(post !== undefined)
  assert.equal(post.method, 'POST')
  assert.equal(post.headers['X-Test'], 'v')
  assert.equal(post.body, 'abc')
  assert.ok(payload.calls.some(call => call.url === 'http://example.test/plain?y=2'))
  const redirects = payload.calls.filter(call => call.url === 'https://example.test/redirect' || call.url === 'https://example.test/final')
  assert.deepEqual(redirects.map(call => call.url), [
    'https://example.test/redirect',
    'https://example.test/final',
  ])
})

test('http shim: sitecustomize installs only when PDSH_PYTHON_HTTP=1 and a missing shim never blocks startup', { skip: NO_PYTHON }, () => {
  const shim = shimDirectory()
  const installed = runPython(`
import http.client
import _xl_http
print("installed", http.client.HTTPSConnection is _xl_http.HTTPSConnection)
`, { shimDir: shim, env: { PDSH_PYTHON_HTTP: '1' } })
  assert.equal(installed.status, 0, installed.stderr)
  assert.equal(installed.stdout.trim(), 'installed True')

  const untouched = runPython(`
import http.client
import _xl_http
print("installed", http.client.HTTPSConnection is _xl_http.HTTPSConnection)
`, { shimDir: shim })
  assert.equal(untouched.status, 0, untouched.stderr)
  assert.equal(untouched.stdout.trim(), 'installed False')

  const missing = shimDirectory(false)
  const started = runPython('print("started")', {
    shimDir: missing,
    env: { PDSH_PYTHON_HTTP: '1' },
  })
  assert.equal(started.status, 0, started.stderr)
  assert.equal(started.stdout.trim(), 'started')
})

interface FakeHttpRoute {
  readonly origin: string
  readonly target: string
  readonly token: string
  readonly body?: string
}

function spawnRealWasiWorker(config: FakeHttpRoute): ToolWorkerTransport {
  const worker = new Worker(
    new URL('../wasi-toolbox/python/node-worker-python-harness.ts', import.meta.url),
    { workerData: { pdshFakeHttp: config } },
  )
  return workerTransport(worker as unknown as WorkerLike)
}

interface RealWasiResult {
  readonly exitCode: number
  readonly stdout: string
  readonly stderr: string
}

async function runRealWasi(options: {
  readonly wasm: Uint8Array
  readonly stdlib: Uint8Array
  readonly workspace: string
  readonly fake: FakeHttpRoute
  readonly http?: LoopbackHttpRoute
  readonly script: string
}): Promise<RealWasiResult> {
  const runtime = new PythonRuntime({
    wasm: options.wasm,
    stdlib: options.stdlib,
    backend: new NodeFsBackend(fsPromises as unknown as NodeFsPromisesLike),
    preopens: [{ guestPath: '/workspace', hostPath: options.workspace }],
    cwd: '/workspace',
    crossOriginIsolated: true,
    spawnWorker: () => spawnRealWasiWorker(options.fake),
    workerReadyTimeoutMs: 30_000,
    ...(options.http === undefined ? {} : { http: options.http }),
  })
  const stdout: Uint8Array[] = []
  const stderr: Uint8Array[] = []
  try {
    const result = await runtime.run({
      program: 'python3',
      argv: ['-c', options.script],
      onStdout: chunk => stdout.push(chunk),
      onStderr: chunk => stderr.push(chunk),
    })
    return {
      exitCode: result.exitCode,
      stdout: Buffer.concat(stdout).toString('utf8'),
      stderr: Buffer.concat(stderr).toString('utf8'),
    }
  } finally {
    await runtime.dispose()
  }
}

test(
  'http shim: real CPython WASI GET reaches the fake /v1/http route (PDSH_PYTHON_WASM)',
  { skip: REAL_WASI_SKIP, timeout: 180_000 },
  async () => {
    // If the variables are set, a missing/corrupt pair must fail loudly rather
    // than silently turn this branch into another host-Python PASS.
    const wasm = readFileSync(realWasmPath as string)
    const stdlib = readFileSync(realStdlibPath as string)
    const root = mkdtempSync(join(tmpdir(), 'pdsh-python-wasi-http-'))
    scratch.push(root)
    const workspace = join(root, 'workspace')
    mkdirSync(workspace, { recursive: true })

    const origin = 'https://loopback.test'
    const token = 'real-wasi-channel-token'
    const target = 'https://example.test/real-wasi'
    const fake: FakeHttpRoute = {
      origin,
      target,
      token,
      body: 'real-wasi-through-fake-loopback',
    }

    // Control: without an injected route the shim is not installed, so this is
    // the pre-fix failure the transport half must repair.
    const control = await runRealWasi({
      wasm,
      stdlib,
      workspace,
      fake,
      script: `
import urllib.request
try:
    urllib.request.urlopen("https://example.test/real-wasi", timeout=10)
    print("control=unexpected-success")
except Exception as exc:
    print("control=%s:%s" % (type(exc).__name__, exc))
`,
    })
    assert.equal(control.exitCode, 0, control.stderr)
    assert.match(control.stdout, /control=.*unknown url type: https/u)

    // Repaired: the real interpreter's urllib goes through /__xl__/http, the
    // WASI host frames it, and the fake synchronous XHR performs one POST
    // /v1/http with the injected bearer.
    const routed = await runRealWasi({
      wasm,
      stdlib,
      workspace,
      fake,
      http: { origin, token },
      script: `
import urllib.request
with urllib.request.urlopen("https://example.test/real-wasi", timeout=10) as response:
    print("status=%d" % response.status)
    print("header=%s" % response.getheader("X-Fake-Loopback"))
    print("body=%s" % response.read().decode("utf-8"))
assert response.isclosed()
`,
    })
    assert.equal(routed.exitCode, 0, routed.stderr)
    assert.match(routed.stdout, /status=200/u)
    assert.match(routed.stdout, /header=yes/u)
    assert.match(routed.stdout, /body=real-wasi-through-fake-loopback/u)
  },
)
