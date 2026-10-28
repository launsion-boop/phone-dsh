#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// Reference xl exec-bridge v1 server for desktop simulation (spec/exec-bridge-v1).
// It plays the host app: runs commands in a workspace directory on this machine,
// serves the optional fs, host HTTP egress and lifecycle endpoints, and enforces
// the bearer token. It is a test double, not a sandbox: commands run as the
// current user with a minimal environment.
//
//   node sim/exec-bridge-sim.mjs --workspace <dir> [--port 0] [--token-file f] [--guest-root <path>]
//                               [--no-stdin-pipe] [--no-http-proxy] [--allow-origin <url-prefix>]...
//
// Prints one JSON line on stdout when ready: {"ready":true,"url":...,"token_file":...,"pid":...}.
// POST /v1/sim/lifecycle {"state":"pause"} changes the lifecycle state (sim-only, token required).

import { spawn } from 'node:child_process'
import { randomBytes, timingSafeEqual } from 'node:crypto'
import { mkdirSync, realpathSync, writeFileSync } from 'node:fs'
import { lstat, mkdir, open, readdir, rename, stat } from 'node:fs/promises'
import http from 'node:http'
import https from 'node:https'
import { dirname, join, posix, relative, resolve } from 'node:path'
import { parseArgs } from 'node:util'

const { values: opts } = parseArgs({
  options: {
    workspace: { type: 'string' },
    port: { type: 'string', default: '0' },
    'token-file': { type: 'string' },
    'guest-root': { type: 'string' },
    'no-stdin-pipe': { type: 'boolean', default: false },
    'no-http-proxy': { type: 'boolean', default: false },
    'allow-origin': { type: 'string', multiple: true, default: [] },
    'retention-seconds': { type: 'string', default: '1800' },
  },
})
if (opts.workspace === undefined) throw new Error('--workspace is required')
mkdirSync(opts.workspace, { recursive: true })
const workspace = realpathSync(opts.workspace)
// Identity mapping by default: the recommended deployment (guest path == host path).
const guestRoot = opts['guest-root'] ?? workspace
const token = randomBytes(32).toString('hex')
const tokenFile = opts['token-file'] ?? join(workspace, '..', `exec-bridge-${process.pid}.token`)
writeFileSync(tokenFile, `${token}\n`, { mode: 0o600 })
const retentionMs = Number(opts['retention-seconds']) * 1000
const MAX_REQUEST = 1024 * 1024
const allowedOrigins = opts['allow-origin']

const hello = {
  protocol: 'pdsh-exec-bridge/1',
  provider: { name: 'desktop-sim', version: '0.1.0' },
  guest: {
    platform: 'posix',
    default_shell: '/bin/sh',
    path_env: '/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin',
    mounts: [{ host_path: workspace, guest_path: guestRoot, read_only: false }],
  },
  capabilities: {
    exec: true, stdin_pipe: !opts['no-stdin-pipe'], fs: true, http_proxy: !opts['no-http-proxy'],
    lifecycle: true, process_group: true, confine: [],
  },
  limits: { max_concurrent: 8, max_output_bytes_per_stream: 8 * 1024 * 1024, max_request_bytes: MAX_REQUEST, retention_seconds: Number(opts['retention-seconds']) },
}

// ── helpers ──────────────────────────────────────────────────────────────────

class BridgeError extends Error {
  constructor(status, code, message) { super(message); this.status = status; this.code = code }
}

function sendJson(res, status, body) {
  const text = body === undefined ? '' : JSON.stringify(body)
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text) })
  res.end(text)
}

function sendError(res, error) {
  if (res.headersSent) { res.destroy(); return }
  const status = error instanceof BridgeError ? error.status : 500
  const code = error instanceof BridgeError ? error.code : 'internal'
  sendJson(res, status, { error: { code, message: error.message } })
}

async function readBody(req) {
  const chunks = []
  let size = 0
  for await (const chunk of req) {
    size += chunk.length
    if (size > MAX_REQUEST) throw new BridgeError(413, 'too_large', 'request body too large')
    chunks.push(chunk)
  }
  return Buffer.concat(chunks)
}

async function readJson(req) {
  const body = await readBody(req)
  if (body.length === 0) return {}
  try { return JSON.parse(body.toString('utf8')) } catch { throw new BridgeError(400, 'bad_request', 'body is not JSON') }
}

function authorized(req) {
  const header = req.headers.authorization ?? ''
  const presented = Buffer.from(header.startsWith('Bearer ') ? header.slice(7) : '')
  const expected = Buffer.from(token)
  return presented.length === expected.length && timingSafeEqual(presented, expected)
}

/** Guest path → real path inside the workspace, or throw 403. */
function realPath(guestPath) {
  if (typeof guestPath !== 'string' || !guestPath.startsWith('/') || guestPath.includes('\0')) {
    throw new BridgeError(400, 'bad_request', 'path must be an absolute guest path')
  }
  const normalized = posix.normalize(guestPath)
  const rest = normalized === guestRoot ? '' : normalized.startsWith(`${guestRoot}/`) ? normalized.slice(guestRoot.length + 1) : undefined
  if (rest === undefined) throw new BridgeError(403, 'forbidden', `${guestPath} is outside the guest mounts`)
  return rest === '' ? workspace : join(workspace, rest)
}

/** Refuse a path whose resolved location (symlinks followed) escapes the workspace. */
async function confined(path, mustExist) {
  let probe = path
  for (;;) {
    try {
      const real = realpathSync(probe)
      const rel = relative(workspace, real)
      if (rel.startsWith('..') || resolve(workspace, rel) !== real) throw new BridgeError(403, 'forbidden', 'path escapes the workspace')
      return path
    } catch (error) {
      if (error instanceof BridgeError) throw error
      if (mustExist || probe === workspace) throw new BridgeError(404, 'not_found', `no such file: ${path}`)
      probe = dirname(probe)
    }
  }
}

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical)
  if (value !== null && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(k => [k, canonical(value[k])]))
  return value
}

// ── executions ───────────────────────────────────────────────────────────────

const executions = new Map()

function validateExec(body) {
  const bad = (message) => { throw new BridgeError(400, 'bad_request', message) }
  if (typeof body.exec_id !== 'string' || body.exec_id.length === 0 || body.exec_id.length > 200 || body.exec_id.includes('\0')) bad('invalid exec_id')
  if (!Array.isArray(body.argv) || body.argv.length === 0 || body.argv.some(a => typeof a !== 'string' || a.includes('\0')) || body.argv[0] === '') bad('invalid argv')
  if (body.env !== undefined) {
    for (const [key, value] of Object.entries(body.env)) {
      if (key === '' || key.includes('=') || key.includes('\0')) bad(`invalid env key ${key}`)
      if (value !== null && (typeof value !== 'string' || value.includes('\0'))) bad(`invalid env value for ${key}`)
    }
  }
  if (body.grace_ms !== undefined && !(Number.isInteger(body.grace_ms) && body.grace_ms >= 1 && body.grace_ms <= 60000)) bad('invalid grace_ms')
  if (body.confine !== undefined) throw new BridgeError(501, 'unsupported', 'the desktop sim enforces no per-execution confinement')
  const stdin = body.stdin ?? { mode: 'ignore' }
  if (!['ignore', 'data', 'pipe'].includes(stdin.mode)) bad('invalid stdin mode')
  if (stdin.mode === 'pipe' && !hello.capabilities.stdin_pipe) throw new BridgeError(501, 'unsupported', 'stdin pipe is disabled')
  return { ...body, stdin }
}

function requestIdentity(body) {
  return JSON.stringify(canonical({ argv: body.argv, cwd: body.cwd, env: body.env ?? {}, stdin: body.stdin, deadline: body.deadline ?? null, confine: body.confine ?? null }))
}

function startExecution(body) {
  const record = {
    id: body.exec_id, identity: requestIdentity(body), events: [], subscribers: new Set(),
    state: 'running', startedAt: Date.now(), exit: undefined, quiescent: false, child: undefined,
    graceMs: body.grace_ms ?? 3000, cancelStatus: undefined, killTimer: undefined, deadlineTimer: undefined, pgid: undefined,
  }
  executions.set(record.id, record)
  const emit = (event) => {
    const full = { ...event, exec_id: record.id, seq: record.events.length }
    record.events.push(full)
    for (const subscriber of record.subscribers) subscriber(full)
  }
  record.emit = emit

  let cwd
  try { cwd = realPath(body.cwd) } catch (error) {
    emit({ type: 'start', pid: null, replayed: false })
    finish(record, { code: null, signal: null, status: 'rejected', error: error.message }, true)
    return record
  }
  const env = { PATH: hello.guest.path_env, HOME: workspace, LANG: 'C.UTF-8', TMPDIR: join(workspace, '..') }
  for (const [key, value] of Object.entries(body.env ?? {})) {
    if (value === null) delete env[key]
    else env[key] = value
  }
  let child
  try {
    child = spawn(body.argv[0], body.argv.slice(1), {
      cwd, env, detached: true,
      stdio: [body.stdin.mode === 'ignore' ? 'ignore' : 'pipe', 'pipe', 'pipe'],
    })
  } catch (error) {
    emit({ type: 'start', pid: null, replayed: false })
    finish(record, { code: null, signal: null, status: 'failed', error: `${error.code ?? ''} ${error.message}`.trim() }, true)
    return record
  }
  record.child = child
  record.pgid = child.pid
  let spawnError
  child.once('error', (error) => { spawnError = error })
  child.once('spawn', () => emit({ type: 'start', pid: child.pid, replayed: false }))
  if (body.stdin.mode === 'data') child.stdin.end(Buffer.from(body.stdin.data ?? '', 'base64'))
  record.stdin = body.stdin.mode === 'pipe' ? child.stdin : undefined
  child.stdin?.on('error', () => {})
  let stdoutBytes = 0
  let stderrBytes = 0
  child.stdout.on('data', (chunk) => { stdoutBytes += chunk.length; emit({ type: 'output', stream: 'stdout', data: chunk.toString('base64') }) })
  child.stderr.on('data', (chunk) => { stderrBytes += chunk.length; emit({ type: 'output', stream: 'stderr', data: chunk.toString('base64') }) })
  // `close` fires after exit AND both pipes reached EOF: the toolbox completion rule.
  child.once('close', (code, signal) => {
    if (spawnError !== undefined) {
      if (record.events.length === 0) emit({ type: 'start', pid: null, replayed: false })
      finish(record, { code: null, signal: null, status: 'failed', error: `${spawnError.code ?? ''} ${spawnError.message}`.trim() }, true)
      return
    }
    const status = record.cancelStatus ?? (signal !== null ? 'signaled' : 'exited')
    finish(record, { code, signal, status, stdout_bytes: stdoutBytes, stderr_bytes: stderrBytes }, groupEmpty(record.pgid))
  })
  if (Number.isInteger(body.deadline)) {
    record.deadlineTimer = setTimeout(() => terminate(record, 'timed_out', 'SIGTERM', record.graceMs), Math.max(0, body.deadline - Date.now()))
  }
  return record
}

function groupEmpty(pgid) {
  if (pgid === undefined) return true
  try { process.kill(-pgid, 0); return false } catch { return true }
}

function finish(record, exit, quiescent) {
  clearTimeout(record.deadlineTimer)
  record.state = 'exited'
  record.exit = { ...exit, quiescent }
  record.emit({ type: 'exit', ...exit, quiescent })
  if (quiescent) settleQuiescent(record, false)
  else {
    // Background children still hold the process group: report when it empties.
    const poll = setInterval(() => {
      if (!groupEmpty(record.pgid)) return
      clearInterval(poll)
      settleQuiescent(record, true)
    }, 100)
    record.quiescencePoll = poll
  }
}

function settleQuiescent(record, emitEvent) {
  record.quiescent = true
  if (record.exit !== undefined) record.exit.quiescent = true
  clearTimeout(record.killTimer)
  if (emitEvent) record.emit({ type: 'quiescent' })
  for (const subscriber of record.subscribers) subscriber(null)
  record.subscribers.clear()
  setTimeout(() => { if (executions.get(record.id) === record) executions.delete(record.id) }, retentionMs).unref()
}

function terminate(record, status, signal, graceMs) {
  if (record.quiescent || record.pgid === undefined) return
  record.cancelStatus ??= status
  try { process.kill(-record.pgid, signal) } catch { /* already gone */ }
  clearTimeout(record.killTimer)
  record.killTimer = setTimeout(() => {
    try { process.kill(-record.pgid, 'SIGKILL') } catch { /* already gone */ }
  }, graceMs)
}

function streamEvents(req, res, record, afterSeq, replayed) {
  res.writeHead(200, { 'content-type': 'application/x-ndjson', 'cache-control': 'no-store' })
  const write = (event) => {
    if (event === null) { res.end(); return }
    if (event.seq <= afterSeq) return
    const out = replayed && event.type === 'start' ? { ...event, replayed: true } : event
    res.write(`${JSON.stringify(out)}\n`)
  }
  for (const event of record.events) write(event)
  if (record.quiescent) { res.end(); return }
  record.subscribers.add(write)
  // Detach on disconnect: the execution keeps running (spec 4.5).
  res.on('close', () => { record.subscribers.delete(write) })
}

// ── lifecycle ────────────────────────────────────────────────────────────────

let lifecycle = { rev: 0, state: 'run', reason: 'foreground', budget_ms: 0 }
const lifecycleWaiters = new Set()
function setLifecycle(next) {
  lifecycle = { rev: lifecycle.rev + 1, state: next.state, ...(next.reason ? { reason: next.reason } : {}), budget_ms: next.budget_ms ?? 0 }
  for (const wake of lifecycleWaiters) wake()
  lifecycleWaiters.clear()
}

// ── host HTTP egress ─────────────────────────────────────────────────────────

const STRIP_UP = new Set(['authorization', 'host', 'connection', 'content-length', 'keep-alive', 'transfer-encoding', 'upgrade'])
const STRIP_DOWN = new Set(['connection', 'keep-alive', 'transfer-encoding', 'upgrade'])

async function proxyHttp(req, res) {
  if (!hello.capabilities.http_proxy) throw new BridgeError(501, 'unsupported', 'http proxy disabled')
  const target = new URL(req.headers['x-pdsh-target-url'] ?? '')
  const method = req.headers['x-pdsh-target-method'] ?? 'GET'
  if (allowedOrigins.length > 0 && !allowedOrigins.some(prefix => target.href.startsWith(prefix))) {
    throw new BridgeError(403, 'forbidden', `upstream ${target.origin} is not allowed`)
  }
  const body = await readBody(req)
  const headers = {}
  for (const [name, value] of Object.entries(req.headers)) {
    if (STRIP_UP.has(name) || name.startsWith('x-pdsh-')) continue
    headers[name] = value
  }
  if (req.headers['x-pdsh-upstream-authorization'] !== undefined) headers.authorization = req.headers['x-pdsh-upstream-authorization']
  if (req.headers['x-pdsh-idempotency-key'] !== undefined) headers['x-pdsh-idempotency-key'] = req.headers['x-pdsh-idempotency-key']
  if (body.length > 0) headers['content-length'] = String(body.length)
  const transport = target.protocol === 'https:' ? https : http
  const upstream = transport.request(target, { method, headers })
  upstream.on('response', (response) => {
    const down = {}
    for (const [name, value] of Object.entries(response.headers)) if (!STRIP_DOWN.has(name)) down[name] = value
    res.writeHead(response.statusCode ?? 502, down)
    response.pipe(res)
  })
  upstream.on('error', (error) => {
    if (res.headersSent) { res.destroy(); return }
    res.writeHead(502, { 'x-pdsh-proxy-error': 'upstream_unreachable', 'content-type': 'text/plain' })
    res.end(error.message)
  })
  upstream.end(body)
}

// ── fs ───────────────────────────────────────────────────────────────────────

function typeOf(stats) {
  return stats.isFile() ? 'file' : stats.isDirectory() ? 'dir' : stats.isSymbolicLink() ? 'symlink' : 'other'
}

async function fsOp(op, body) {
  const path = await confined(realPath(body.path), op !== 'write')
  switch (op) {
    case 'stat': {
      const stats = await lstat(path)
      return { type: typeOf(stats), size: stats.size, mtime_ms: stats.mtimeMs, mode: stats.mode & 0o7777 }
    }
    case 'read': {
      const handle = await open(path, 'r')
      try {
        const { size } = await handle.stat()
        const offset = body.offset ?? 0
        const length = Math.min(body.length ?? MAX_REQUEST, MAX_REQUEST, Math.max(0, size - offset))
        const buffer = Buffer.alloc(length)
        const { bytesRead } = await handle.read(buffer, 0, length, offset)
        return { data: buffer.subarray(0, bytesRead).toString('base64'), eof: offset + bytesRead >= size, size }
      } finally { await handle.close() }
    }
    case 'write': {
      const data = Buffer.from(body.data ?? '', 'base64')
      const mode = body.mode ?? 'truncate'
      const existing = await stat(path).catch(() => undefined)
      if (mode === 'create' && existing !== undefined) throw new BridgeError(409, 'stale', 'file exists')
      if (body.expected_mtime_ms !== undefined && existing?.mtimeMs !== body.expected_mtime_ms) throw new BridgeError(409, 'stale', 'file changed')
      await mkdir(dirname(path), { recursive: true })
      if (mode === 'append') {
        const handle = await open(path, 'a')
        try { await handle.write(data); await handle.sync() } finally { await handle.close() }
      } else {
        const temp = `${path}.pdsh-tmp-${process.pid}-${randomBytes(4).toString('hex')}`
        const handle = await open(temp, 'w', 0o644)
        try { await handle.write(data); await handle.sync() } finally { await handle.close() }
        await rename(temp, path)
      }
      const after = await stat(path)
      return { size: after.size, mtime_ms: after.mtimeMs }
    }
    case 'list': {
      const entries = await readdir(path, { withFileTypes: true })
      return { entries: entries.map(entry => ({ name: entry.name, type: typeOf(entry) })) }
    }
    default:
      throw new BridgeError(404, 'not_found', `unknown fs op ${op}`)
  }
}

// ── server ───────────────────────────────────────────────────────────────────

const server = http.createServer(async (req, res) => {
  try {
    if (req.headers.origin !== undefined) throw new BridgeError(403, 'forbidden', 'browser origins are refused')
    if (!authorized(req)) throw new BridgeError(401, 'unauthorized', 'missing or wrong bearer token')
    const url = new URL(req.url ?? '/', 'http://127.0.0.1')
    const path = url.pathname
    process.stderr.write(`sim: ${req.method} ${path}${path === '/v1/http' ? ` -> ${req.headers['x-pdsh-target-url']}` : ''}\n`)
    if (req.method === 'GET' && path === '/v1/hello') return sendJson(res, 200, hello)
    if (req.method === 'POST' && path === '/v1/exec') {
      const body = validateExec(await readJson(req))
      const existing = executions.get(body.exec_id)
      if (existing !== undefined) {
        if (existing.identity !== requestIdentity(body)) throw new BridgeError(409, 'exec_id_conflict', 'exec_id was reused with a different request')
        return streamEvents(req, res, existing, -1, true)
      }
      return streamEvents(req, res, startExecution(body), -1, false)
    }
    let match = /^\/v1\/exec\/([^/]+)(\/events|\/cancel|\/stdin)?$/.exec(path)
    if (match !== null) {
      const record = executions.get(decodeURIComponent(match[1]))
      if (record === undefined) throw new BridgeError(404, 'not_found', 'unknown exec_id')
      const action = match[2]
      if (action === undefined && req.method === 'GET') {
        return sendJson(res, 200, { exec_id: record.id, state: record.state, started_at: record.startedAt, ...(record.exit ? { exit: { code: record.exit.code, signal: record.exit.signal, status: record.exit.status, quiescent: record.quiescent } } : {}) })
      }
      if (action === '/events' && req.method === 'GET') return streamEvents(req, res, record, Number(url.searchParams.get('after_seq') ?? '-1'), false)
      if (action === '/cancel' && req.method === 'POST') {
        const body = await readJson(req)
        terminate(record, 'cancelled', body.signal ?? 'SIGTERM', body.grace_ms ?? record.graceMs)
        return sendJson(res, 202, {})
      }
      if (action === '/stdin' && req.method === 'POST') {
        const body = await readJson(req)
        if (record.stdin === undefined || record.stdin.writableEnded) throw new BridgeError(409, 'stdin_closed', 'stdin is not an open pipe')
        if (body.data) await new Promise((resolve, reject) => record.stdin.write(Buffer.from(body.data, 'base64'), (error) => error ? reject(error) : resolve()))
        if (body.eof) record.stdin.end()
        res.writeHead(204); return res.end()
      }
    }
    match = /^\/v1\/fs\/(stat|read|write|list)$/.exec(path)
    if (match !== null && req.method === 'POST') return sendJson(res, 200, await fsOp(match[1], await readJson(req)))
    if (path === '/v1/http' && req.method === 'POST') return await proxyHttp(req, res)
    if (path === '/v1/lifecycle' && req.method === 'GET') {
      const since = url.searchParams.has('since') ? Number(url.searchParams.get('since')) : undefined
      const waitMs = Math.min(30000, Number(url.searchParams.get('wait_ms') ?? '0'))
      if (since === lifecycle.rev && waitMs > 0) {
        await new Promise((resolve) => {
          const timer = setTimeout(resolve, waitMs)
          lifecycleWaiters.add(() => { clearTimeout(timer); resolve() })
          req.on('close', resolve)
        })
      }
      return sendJson(res, 200, lifecycle)
    }
    if (path === '/v1/sim/lifecycle' && req.method === 'POST') {
      const body = await readJson(req)
      if (!['run', 'pause', 'stop'].includes(body.state)) throw new BridgeError(400, 'bad_request', 'state must be run, pause or stop')
      setLifecycle(body)
      return sendJson(res, 200, lifecycle)
    }
    throw new BridgeError(404, 'not_found', `no endpoint ${req.method} ${path}`)
  } catch (error) {
    sendError(res, error)
  }
})

server.listen(Number(opts.port), '127.0.0.1', () => {
  const { port } = server.address()
  process.stdout.write(`${JSON.stringify({ ready: true, url: `http://127.0.0.1:${port}`, token_file: tokenFile, workspace, guest_root: guestRoot, pid: process.pid })}\n`)
})

const stopAll = () => {
  for (const record of executions.values()) if (!record.quiescent && record.pgid !== undefined) { try { process.kill(-record.pgid, 'SIGKILL') } catch {} }
  process.exit(0)
}
process.on('SIGTERM', stopAll)
process.on('SIGINT', stopAll)
