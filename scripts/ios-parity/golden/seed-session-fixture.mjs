#!/usr/bin/env node
/**
 * SUPERSEDED — kept as the failure evidence, not as the working seeder.
 *
 * This script hand-writes concatenated zstd frames. The server did list the
 * seeded session (the first frame carries the header), but opening it produced
 * zero transcript rows and the title `未命名`: the event frames never reached
 * the projection. Use `seed-official-session.mjs` instead — it parses the
 * fixture through the official format reader and persists it through the
 * official `JsonlSessionPersistence.create/append/close` seam, which owns the
 * frame layout, seq envelope and encoding.
 *
 * ---------------------------------------------------------------------------
 * Seed one recorded session fixture into a *temporary copy* of a DSH_HOME.
 *
 * Why this exists: the local ~/.dsh sessions are all single-turn
 * MISSING_CREDENTIAL failures, so they cannot show assistant text or tool
 * cards. The official checkout ships richer recorded fixtures under
 * `snapshots/session/<scenario>/session.v4.jsonl` (an authored transcript with
 * assistant reasoning, a bash tool call, its result, a final assistant turn and
 * `turn/end completed`). Those fixtures are comparison artifacts: their
 * identities are placeholders (`{{session:1}}`, `{{cwd}}`, `{{message:1}}`, …)
 * and their rows carry no `seq`/`time` envelope.
 *
 * This script turns one such fixture into a session log the official web server
 * can actually project, inside a throwaway DSH_HOME:
 *
 *   1. resolve the target session's real cwd (projcache identity, else the
 *      existing log header) so the seeded header keeps the same workspace group;
 *   2. replace every placeholder with the target session's id/cwd (and
 *      deterministic message/job ids, an empty tool catalog, a short system
 *      prompt);
 *   3. add the missing `seq`/`time` envelope, anchored to the fixture's own
 *      embedded timestamps so the run stays deterministic and internally
 *      consistent;
 *   4. write `session.v4.jsonl.zstd` for that session, drop the stale
 *      projection cache and lock file, and remove any other log generation in
 *      the directory so the server cannot pick the old one.
 *
 * The real ~/.dsh must never be a target: the script refuses a home that is the
 * user's own DSH_HOME unless `--allow-real-home` is passed.
 *
 * Usage:
 *   node seed-session-fixture.mjs \
 *     --home /tmp/dsh-golden.XXX/dsh-home-session \
 *     --fixture <official>/snapshots/session/bash-tool-turn/session.v4.jsonl \
 *     --session-id session-08d252dc-f487-42c1-9b87-68467f70f1e2 \
 *     [--system-text "..."] [--out /tmp/seed.json]
 */
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join, resolve } from 'node:path'

const SYSTEM_TEXT_DEFAULT = 'You are an AI agent powered by DeepSeek Harness.'

function parseArgs(argv) {
  const args = {
    home: null,
    fixture: null,
    sessionId: null,
    cwd: null,
    systemText: SYSTEM_TEXT_DEFAULT,
    out: null,
    allowRealHome: false,
    zstd: process.env.ZSTD_BIN ?? null,
  }
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i]
    const next = () => {
      i += 1
      if (i >= argv.length) throw new Error(`missing value for ${key}`)
      return argv[i]
    }
    switch (key) {
      case '--home': args.home = next(); break
      case '--fixture': args.fixture = next(); break
      case '--session-id': args.sessionId = next(); break
      case '--cwd': args.cwd = next(); break
      case '--system-text': args.systemText = next(); break
      case '--out': args.out = next(); break
      case '--zstd': args.zstd = next(); break
      case '--allow-real-home': args.allowRealHome = true; break
      default: throw new Error(`unknown argument: ${key}`)
    }
  }
  if (!args.home) throw new Error('--home is required (temporary DSH_HOME copy)')
  if (!args.fixture) throw new Error('--fixture is required (path to session.v4.jsonl)')
  if (!args.sessionId) throw new Error('--session-id is required')
  return args
}

function die(message) {
  console.error(`[seed-session-fixture] FAILED: ${message}`)
  process.exit(1)
}

function sha256File(file) {
  return createHash('sha256').update(readFileSync(file)).digest('hex')
}

/** Escape a value the way a JSON string literal would spell it (without quotes). */
function jsonStringBody(value) {
  return JSON.stringify(value).slice(1, -1)
}

function findZstd(explicit) {
  const candidates = [explicit, process.env.ZSTD_BIN, '/opt/homebrew/bin/zstd', '/usr/local/bin/zstd', '/usr/bin/zstd']
    .filter((candidate) => typeof candidate === 'string' && candidate.length > 0)
  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate
  }
  const which = spawnSync('which', ['zstd'], { encoding: 'utf8' })
  if (which.status === 0) {
    const found = which.stdout.trim()
    if (found) return found
  }
  return null
}

/** Decompress one existing session log to read its header (zstd CLI, no deps). */
function readExistingHeader(file, zstdBin) {
  let text
  if (file.endsWith('.zstd')) {
    if (!zstdBin) return null
    const result = spawnSync(zstdBin, ['-dc', file], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
    if (result.status !== 0) return null
    text = result.stdout
  } else {
    text = readFileSync(file, 'utf8')
  }
  const firstLine = text.split('\n').find((line) => line.trim().length > 0)
  if (!firstLine) return null
  try {
    return JSON.parse(firstLine)
  } catch {
    return null
  }
}

/**
 * Resolve the cwd the session belongs to. The seeded header must keep it, or
 * the sidebar would show a group that matches no existing directory.
 */
function resolveCwd(home, sessionId, sessionDir, zstdBin) {
  const cachePath = join(home, 'storages', 'session_projcache', 'sessions', `${sessionId}.json`)
  if (existsSync(cachePath)) {
    try {
      const cache = JSON.parse(readFileSync(cachePath, 'utf8'))
      const cwd = cache?.record?.identity?.cwd
      if (typeof cwd === 'string' && cwd.length > 0) return { cwd, source: 'projcache' }
    } catch {
      /* fall through to the log header */
    }
  }
  const logs = readdirSync(sessionDir).filter((name) => /^session(\.[1-9]\d*)?(\.v[1-9]\d*)?\.jsonl(\.zstd)?$/.test(name))
  for (const log of logs) {
    const header = readExistingHeader(join(sessionDir, log), zstdBin)
    if (header && typeof header.cwd === 'string' && header.cwd.length > 0) {
      return { cwd: header.cwd, source: `header:${log}` }
    }
  }
  return null
}

/** Last logical timestamp carried by an embedded assistant stream. */
function streamEnd(stream) {
  let end
  for (const record of stream ?? []) {
    const recordEnd = Number.isSafeInteger(record.time)
      ? record.time
      : (record.time0 ?? 0) + (Array.isArray(record.dt) ? record.dt.reduce((total, delta) => total + delta, 0) : 0)
    end = end === undefined ? recordEnd : Math.max(end, recordEnd)
  }
  return end
}

/** Re-anchor one embedded stream at `startAt`, preserving every intra-stream gap. */
function rebaseStream(stream, startAt) {
  const first = stream?.[0]
  if (first === undefined) return stream
  const sourceStart = Number.isSafeInteger(first.time) ? first.time : first.time0
  const delta = startAt - sourceStart
  return stream.map((record) => (Number.isSafeInteger(record.time)
    ? { ...record, time: record.time + delta }
    : { ...record, time0: record.time0 + delta }))
}

/**
 * Materialize the fixture rows the way the official web test seeder does
 * (`apps/web/tests/scaffold.ts:seedSession`): events are re-timed from the
 * header's `createdAt`, and an assistant message's embedded stream is rebased
 * onto its own event time. Keeping the fixture's original absolute stream times
 * would leave them months after the event envelope, which the projection rejects.
 */
function materializeEvents(rows, timeAnchor) {
  let nextTime = timeAnchor
  return rows.map((row, index) => {
    if (typeof row.type !== 'string') die(`fixture event row ${index + 2} has no type`)
    const time = nextTime
    if (row.type === 'assistant/message' || row.type === 'assistant/attempt') {
      const stream = rebaseStream(row.data?.stream, time)
      const completedAt = Math.max(time, streamEnd(stream) ?? time)
      nextTime = completedAt + 1
      return { ...row, seq: index, time: completedAt, data: { ...row.data, stream } }
    }
    nextTime = time + 1
    return { ...row, seq: index, time }
  })
}

function main() {
  const args = parseArgs(process.argv.slice(2))
  const home = resolve(args.home)
  const fixture = resolve(args.fixture)
  const realHome = resolve(homedir(), '.dsh')

  if (!existsSync(home) || !statSync(home).isDirectory()) die(`DSH_HOME to seed does not exist: ${home}`)
  if (!existsSync(fixture)) die(`fixture not found: ${fixture}`)
  if (home === realHome && !args.allowRealHome) {
    die(`refusing to seed the real DSH_HOME (${home}); copy it to a temporary directory first (or pass --allow-real-home)`)
  }
  if (!args.sessionId.startsWith('session-')) die(`session id must start with "session-": ${args.sessionId}`)

  const sessionDirs = []
  const sessionsRoot = join(home, 'sessions')
  if (!existsSync(sessionsRoot)) die(`seeded DSH_HOME has no sessions/: ${sessionsRoot}`)
  for (const encoded of readdirSync(sessionsRoot)) {
    const candidate = join(sessionsRoot, encoded, args.sessionId)
    if (existsSync(candidate) && statSync(candidate).isDirectory()) sessionDirs.push(candidate)
  }
  if (sessionDirs.length !== 1) {
    die(`expected exactly one session directory named ${args.sessionId} under ${sessionsRoot}, found ${sessionDirs.length}`)
  }
  const sessionDir = sessionDirs[0]

  const zstdBin = findZstd(args.zstd)
  const resolved = args.cwd === null ? resolveCwd(home, args.sessionId, sessionDir, zstdBin) : { cwd: resolve(args.cwd), source: 'argument' }
  if (!resolved) die(`could not resolve the seeded session's cwd from the projcache or its log header; pass --cwd`)
  const cwd = resolved.cwd

  const fixtureText = readFileSync(fixture, 'utf8')
  const replacements = new Map()
  const countOf = (token) => fixtureText.split(token).length - 1
  const countMatches = (pattern) => [...fixtureText.matchAll(pattern)].length
  const record = (token, count, value) => {
    if (count > 0) replacements.set(token, { count, value })
    return value
  }

  // Session + cwd identity first: every other placeholder is a deterministic
  // stand-in, these two have to match the target directory/list entry exactly.
  let seeded = fixtureText
  seeded = seeded.replaceAll('{{session:1}}', () => record('{{session:1}}', countOf('{{session:1}}'), args.sessionId))
  seeded = seeded.replaceAll('{{cwd}}', () => record('{{cwd}}', countOf('{{cwd}}'), jsonStringBody(cwd)))
  seeded = seeded.replaceAll('{{system}}', () => record('{{system}}', countOf('{{system}}'), jsonStringBody(args.systemText)))
  // `{{tools}}` stands in for the pinned tool-schema sidecar. The transcript is
  // driven by the recorded tool/call rows, so an empty catalog is the honest
  // choice here: the fixture does not carry the original schemas.
  seeded = seeded.replaceAll('"{{tools}}"', () => {
    if (countOf('"{{tools}}"') > 0) replacements.set('{{tools}}', { count: countOf('"{{tools}}"'), value: [] })
    return '[]'
  })
  seeded = seeded.replaceAll(/\{\{message:(\d+)\}\}/g, (_match, digits) => {
    const id = `d0de0000-0000-4000-8000-${String(Number(digits)).padStart(12, '0')}`
    record('{{message:N}}', countMatches(/\{\{message:\d+\}\}/g), id)
    return id
  })
  seeded = seeded.replaceAll(/\{\{id:(\d+)\}\}/g, (_match, digits) => {
    const id = `fixture-${String(Number(digits)).padStart(2, '0')}-4f1e8a2c`
    record('{{id:N}}', countMatches(/\{\{id:\d+\}\}/g), id)
    return id
  })

  const leftover = [...seeded.matchAll(/\{\{[^}]*\}\}/g)].map((match) => match[0])
  if (leftover.length > 0) die(`unreplaced placeholder(s) remain: ${[...new Set(leftover)].join(', ')}`)

  const rawLines = seeded.split('\n').filter((line) => line.trim().length > 0)
  if (rawLines.length === 0) die('fixture has no rows')
  const rows = rawLines.map((line, index) => {
    try {
      return JSON.parse(line)
    } catch (error) {
      return die(`fixture row ${index + 1} is not JSON: ${error.message}`)
    }
  })

  // The fixture's `{{tools}}` token stands in for the pinned tool-schema
  // sidecar, which the recording does not carry. An empty tool catalog must be
  // *omitted* rather than stored as `[]`: the current-format validator refuses
  // `request/header` rows with an empty tools array ("must omit empty tools").
  const toolsOmitted = []
  for (const row of rows) {
    if (row?.type !== 'request/header') continue
    const header = row.data?.header
    if (header !== null && typeof header === 'object' && Array.isArray(header.tools) && header.tools.length === 0) {
      delete header.tools
      toolsOmitted.push(true)
    }
  }


  const header = rows[0]
  if (header?.type !== 'session') die('fixture row 1 must be the session header')
  if (header.id !== args.sessionId) die(`header id ${JSON.stringify(header.id)} does not match ${args.sessionId}`)
  if (header.cwd !== cwd) die(`header cwd ${JSON.stringify(header.cwd)} does not match ${JSON.stringify(cwd)}`)
  if (header.version !== 4) die(`fixture must be a v4 log, got version ${header.version}`)

  // The fixture rows are a comparison artifact: no seq/time envelope and a
  // stream clock that is not anchored to the header. Re-time them the way the
  // official web test seeder does so the projection accepts the recording.
  const timeAnchor = Number.isSafeInteger(header.createdAt) ? header.createdAt : Date.now() - 60_000
  const events = materializeEvents(rows.slice(1), timeAnchor)
  for (const [index, event] of events.entries()) {
    if (event.seq !== index) die(`fixture seq must be dense: row ${index + 2} has seq ${event.seq}`)
  }
  let previousTime = 0
  for (const event of events) {
    if (event.time < previousTime) die(`fixture time must be monotonic at seq ${event.seq}`)
    previousTime = event.time
  }

  const seededLines = [JSON.stringify(header), ...events.map((event) => JSON.stringify(event))]
  const seededText = `${seededLines.join('\n')}\n`

  // Drop every other generation first: a stale v3/v4 log next to the seeded one
  // would make the served transcript depend on selection order.
  const removed = []
  for (const name of readdirSync(sessionDir)) {
    if (/^session(\.[1-9]\d*)?(\.v[1-9]\d*)?\.jsonl(\.zstd)?$/.test(name)) {
      rmSync(join(sessionDir, name), { force: true })
      removed.push(name)
    }
  }
  const rawPath = join(sessionDir, 'session.v4.jsonl')

  // The JSONL backend stores a *concatenated* Zstandard container, not one frame
  // per file: the first frame must decode to exactly the header line (see
  // `assertZstdHeaderFrame` in session-persistence-jsonl), and every following
  // frame carries a batch of event lines. A single whole-file frame makes the
  // backend treat the log as corrupt and silently drop it from the session list,
  // so compress each line into its own frame and concatenate them.
  const writtenLog = `${rawPath}.zstd`
  let compression = 'raw'
  if (zstdBin) {
    const frames = []
    for (const line of seededLines) {
      const result = spawnSync(zstdBin, ['-q', '-c', '-19'], { input: `${line}\n`, maxBuffer: 8 * 1024 * 1024 })
      if (result.status !== 0) {
        die(`zstd compression failed: ${result.stderr?.toString().trim() || result.error?.message || `exit ${result.status}`}`)
      }
      frames.push(result.stdout)
    }
    writeFileSync(writtenLog, Buffer.concat(frames))
    compression = `${zstdBin} (${frames.length} concatenated frames)`
  } else {
    writeFileSync(rawPath, seededText)
    compression = 'raw (zstd CLI not found: the server will not read a raw log unless the backend is configured for it)'
  }

  const lockRemoved = (() => {
    const lockPath = join(sessionDir, 'session.lock')
    if (!existsSync(lockPath)) return false
    rmSync(lockPath, { force: true })
    return true
  })()

  const projcachePath = join(home, 'storages', 'session_projcache', 'sessions', `${args.sessionId}.json`)
  const projcacheRemoved = existsSync(projcachePath)
  if (projcacheRemoved) rmSync(projcachePath, { force: true })

  const countsByType = {}
  for (const event of events) countsByType[event.type] = (countsByType[event.type] ?? 0) + 1

  const summary = {
    home,
    fixture,
    fixtureSha256: sha256File(fixture),
    sessionId: args.sessionId,
    cwd,
    cwdSource: resolved.source,
    sessionDir,
    header: { version: header.version, id: header.id, cwd: header.cwd, createdAt: header.createdAt },
    events: events.length,
    countedByType: countsByType,
    rows: seededLines.length,
    seq: { first: events[0]?.seq ?? null, last: events.at(-1)?.seq ?? null },
    time: { anchor: timeAnchor, first: events[0]?.time ?? null, last: events.at(-1)?.time ?? null },
    placeholders: Object.fromEntries([...replacements].map(([token, entry]) => [token, { count: entry.count, value: entry.value }])),
    replacedFiles: removed,
    writtenLog,
    compression,
    lockRemoved,
    projcache: { path: projcachePath, removed: projcacheRemoved },
    seededSha256: createHash('sha256').update(seededText).digest('hex'),
    seededLines,
  }

  if (args.out) writeFileSync(resolve(args.out), `${JSON.stringify(summary, null, 2)}\n`)
  console.log(`[seed-session-fixture] seeded ${args.sessionId} from ${fixture}`)
  console.log(`[seed-session-fixture] ${events.length} event(s) seq 0..${events.at(-1)?.seq} ` +
    `type=${JSON.stringify(countsByType)} cwd=${cwd}`)
  console.log(`[seed-session-fixture] replaced ${[...replacements].map(([token, entry]) => `${token}×${entry.count}`).join(', ')}`)
  console.log(`[seed-session-fixture] projcache removed=${projcacheRemoved} lock removed=${lockRemoved} log=${summary.writtenLog}`)
  return 0
}

try {
  process.exit(main() ?? 0)
} catch (error) {
  console.error(`[seed-session-fixture] FAILED: ${error.message}`)
  process.exit(1)
}
