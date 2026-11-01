#!/usr/bin/env node
/**
 * Seed one recorded official session fixture into a throwaway DSH_HOME through
 * the official JSONL persistence API.
 *
 * Why this exists: the local ~/.dsh sessions are single-turn
 * MISSING_CREDENTIAL failures, so they cannot show assistant markdown or tool
 * cards. The official checkout ships richer recorded fixtures under
 * `snapshots/session/<scenario>/session.v4.jsonl` (authored transcript with
 * assistant reasoning, a bash tool call, its result, a final assistant answer
 * and `turn/end completed`).
 *
 * The previous attempt (`seed-session-fixture.mjs`) hand-wrote concatenated
 * zstd frames. The session appeared in the sidebar but the projection produced
 * zero transcript rows and the title `未命名`: only the header frame was read,
 * so the event log was effectively invisible to the backend. This script
 * instead goes through the same seams the official web e2e scaffold uses
 * (`apps/web/tests/scaffold.ts`):
 *
 *   parseSeedFixture  ->  realizeSeedFixture + prepareSessionSnapshotFixtureForComparison
 *                         + parseSessionLog (format-catalog migration + validation)
 *   materialize       ->  rebase each embedded assistant stream onto its event
 *                         time, anchor the envelope at the fixture `createdAt`
 *   persistSeedSession ->  new cordis Context + JsonlSessionPersistence plugin
 *                         + create(meta) + append(events) + close()
 *
 * The persistence backend therefore owns the header/frame boundaries, the
 * `seq` envelope, the encoding, and its own validation, exactly like a real
 * server-written log. Afterwards the script re-opens and re-reads the log
 * through the same backend and fails if the events or the title did not land.
 *
 * The real ~/.dsh must never be a target: the script refuses the user's own
 * DSH_HOME unless `--allow-real-home` is passed.
 *
 * Fixtures also carry text-only placeholders the official scaffold leaves to the
 * reader (`{{timeContextTimestamp}}`, `{{clientTimeZone}}`, `{{elapsed}}`,
 * `{{sourceRoot}}`, `{{webUrl}}`); those stay literal and are reported, while an
 * unknown placeholder still fails the seed.
 *
 * Usage:
 *   node seed-official-session.mjs \
 *     --official-repo /path/to/deepseek-harness \
 *     --home /tmp/dsh-golden.XXXX/dsh-home-session \
 *     --fixture /path/to/deepseek-harness/snapshots/session/bash-tool-turn/session.v4.jsonl \
 *     --session-id session-4f117741-269b-464e-a2cc-4c121c50531c \
 *     [--cwd /path/to/workspace] [--system-text "..."] [--created-at <epoch-ms>] [--out /tmp/seed.json]
 */
import { createHash } from 'node:crypto'
import { existsSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const DEFAULT_OFFICIAL_REPO =
  '/Users/leilangsheng/Documents/Codex/2026-08-14/https-github-com-deepseek-ai-deepseek/deepseek-harness'
const SYSTEM_TEXT_DEFAULT = 'You are an AI agent powered by DeepSeek Harness.'
const SESSION_LOG_PATTERN = /^session(\.[1-9]\d*)?(\.v[1-9]\d*)?\.jsonl(\.zstd)?$/
/**
 * Text-only placeholders some recorded fixtures keep for the snapshot reader.
 *
 * `apps/web/tests/scaffold.ts:realizeSeedFixture` only substitutes the identity,
 * cwd and harness-home tokens; it deliberately leaves the sampled clock, browser
 * zone, elapsed duration, checkout root and GUI URL verbatim, because those
 * values belong to the recording environment, not to the replay target. They sit
 * inside runtime-context / time-context messages, which the transcript projects
 * as folded context rows, so they do not reach the visible answer/plan surface.
 *
 * Keeping them literal (instead of inventing values) preserves what the official
 * fixture actually recorded. Unknown placeholders still fail the seed.
 */
const RECORDED_PRESENTATION_PLACEHOLDERS = [
  'clientTimeZone',
  'elapsed',
  'sourceRoot',
  'timeContextTimestamp',
  'webUrl',
]

function parseArgs(argv) {
  const args = {
    officialRepo: process.env.DSH_OFFICIAL_REPO ?? DEFAULT_OFFICIAL_REPO,
    home: null,
    fixture: null,
    sessionId: null,
    cwd: null,
    systemText: SYSTEM_TEXT_DEFAULT,
    out: null,
    createdAt: null,
    allowRealHome: false,
  }
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i]
    const next = () => {
      i += 1
      if (i >= argv.length) throw new Error(`missing value for ${key}`)
      return argv[i]
    }
    switch (key) {
      case '--official-repo': args.officialRepo = next(); break
      case '--home': args.home = next(); break
      case '--fixture': args.fixture = next(); break
      case '--session-id': args.sessionId = next(); break
      case '--cwd': args.cwd = next(); break
      case '--system-text': args.systemText = next(); break
      case '--created-at': args.createdAt = Number(next()); break
      case '--out': args.out = next(); break
      case '--allow-real-home': args.allowRealHome = true; break
      default: throw new Error(`unknown argument: ${key}`)
    }
  }
  if (!args.home) throw new Error('--home is required (throwaway DSH_HOME copy)')
  if (!args.fixture) throw new Error('--fixture is required (path to session.v4.jsonl)')
  if (!args.sessionId) throw new Error('--session-id is required')
  if (args.createdAt !== null && (!Number.isSafeInteger(args.createdAt) || args.createdAt <= 0)) {
    throw new Error('--created-at must be a positive epoch-millisecond integer')
  }
  return args
}

function die(message) {
  console.error(`[seed-official-session] FAILED: ${message}`)
  process.exit(1)
}

function sha256(buffer) {
  return createHash('sha256').update(buffer).digest('hex')
}

/**
 * Import one built module from the official checkout. The packages are ESM
 * workspace builds: importing the package entry by absolute path keeps every
 * internal bare import resolving inside the official node_modules tree.
 */
async function importBuilt(repo, candidates) {
  for (const relative of candidates) {
    const absolute = join(repo, relative)
    if (!existsSync(absolute)) continue
    return { module: await import(pathToFileURL(absolute).href), path: absolute }
  }
  throw new Error(`none of these official builds exist under ${repo}: ${candidates.join(', ')}`)
}

/** Deterministic UUID used when a seed fixture's typed identity token is materialized. */
function fixtureIdentity(kind, ordinal) {
  const hex = createHash('sha256').update(`${kind}:${ordinal}`).digest('hex').slice(0, 32).split('')
  hex[12] = '4'
  hex[16] = ['8', '9', 'a', 'b'][Number.parseInt(hex[16], 16) % 4]
  return `${hex.slice(0, 8).join('')}-${hex.slice(8, 12).join('')}-${hex.slice(12, 16).join('')}-${hex.slice(16, 20).join('')}-${hex.slice(20).join('')}`
}

/** Apply a string transform to every string value of a parsed JSON document. */
function mapJsonStringValues(value, transform) {
  if (typeof value === 'string') return transform(value)
  if (Array.isArray(value)) return value.map((item) => mapJsonStringValues(item, transform))
  if (value !== null && typeof value === 'object') {
    const mapped = {}
    for (const [key, item] of Object.entries(value)) mapped[key] = mapJsonStringValues(item, transform)
    return mapped
  }
  return value
}

/**
 * Realize the fixture against the target session the way
 * `apps/web/tests/scaffold.ts:realizeSeedFixture` does: substitute the identity
 * placeholders with the target id/cwd/harness home, rewrite the recorded cwd,
 * and materialize typed ids deterministically. `{{tools}}` deliberately
 * survives: the format reader deletes it for validation and restores it, so it
 * must still be present when the fixture text is parsed.
 */
function realizeFixture(fixtureText, { sessionId, cwd, home, systemText }) {
  const headerLine = fixtureText.split(/\r?\n/).find((line) => line.trim().length > 0)
  const fixtureCwd = JSON.parse(headerLine).cwd
  return fixtureText.split(/\r?\n/).map((line) => {
    if (line.trim() === '') return line
    const realized = mapJsonStringValues(JSON.parse(line), (value) => {
      let result = typeof fixtureCwd === 'string' ? value.split(fixtureCwd).join(cwd) : value
      result = result
        .split('{{sessionId}}').join(sessionId)
        .split('{{session:1}}').join(sessionId)
        .replace(/\{\{session:([2-9]\d*)\}\}/g, (_token, ordinal) => `${sessionId}-child-${ordinal}`)
        .replace(/\{\{(message|approval|workflow|command|rpc|retry|id):([1-9]\d*)\}\}/g,
          (_token, kind, ordinal) => fixtureIdentity(kind, Number(ordinal)))
        .split('{{harnessHome}}').join(home)
        .split('{{cwd}}').join(cwd)
        .split('{{system}}').join(systemText)
      return result
    })
    return JSON.stringify(realized)
  }).join('\n')
}

/** Re-anchor one embedded stream at `startAt`, preserving every intra-stream gap. */
function rebaseStream(stream, startAt) {
  const first = stream?.[0]
  if (first === undefined) return stream
  const sourceStart = 'time' in first ? first.time : first.time0
  const delta = startAt - sourceStart
  return stream.map((record) => ('time' in record
    ? { ...record, time: record.time + delta }
    : { ...record, time0: record.time0 + delta }))
}

/** Last logical timestamp carried by an embedded assistant stream. */
function streamEnd(stream) {
  let end
  for (const record of stream ?? []) {
    const recordEnd = 'time' in record
      ? record.time
      : record.time0 + record.dt.reduce((total, delta) => total + delta, 0)
    end = end === undefined ? recordEnd : Math.max(end, recordEnd)
  }
  return end
}

/**
 * Materialize the fixture rows exactly like
 * `apps/web/tests/scaffold.ts:seedSession`: every event is anchored one
 * millisecond after the previous one, and an assistant message's embedded
 * stream is rebased onto its own event time so the projection sees a coherent
 * clock instead of raw recording wall times.
 */
function materializeEvents(events, timeAnchor) {
  let nextTime = timeAnchor
  return events.map((event) => {
    const time = nextTime
    if (event.type === 'assistant/message' || event.type === 'assistant/attempt') {
      const stream = rebaseStream(event.data?.stream, time)
      const completedAt = Math.max(time, streamEnd(stream) ?? time)
      nextTime = completedAt + 1
      return { ...event, time: completedAt, data: { ...event.data, stream } }
    }
    nextTime = time + 1
    return { ...event, time }
  })
}

/** Read the projcache identity cwd for the target session, when one is present. */
function cwdFromProjcache(home, sessionId) {
  const cachePath = join(home, 'storages', 'session_projcache', 'sessions', `${sessionId}.json`)
  if (!existsSync(cachePath)) return null
  try {
    const cache = JSON.parse(readFileSync(cachePath, 'utf8'))
    const cwd = cache?.record?.identity?.cwd
    return typeof cwd === 'string' && cwd.length > 0 ? { cwd, source: 'projcache' } : null
  } catch {
    return null
  }
}

/**
 * Resolve the cwd of the session being replaced. The seeded header must keep it
 * or the sidebar row would move to a workspace group that matches no directory.
 */
function resolveCwd(home, sessionId, sessionDir) {
  const cached = cwdFromProjcache(home, sessionId)
  if (cached) return cached
  // The existing log may be v3; decompress the first line with the Node zstd
  // implementation the backend already links (no zstd CLI dependency).
  for (const name of readdirSync(sessionDir)) {
    if (!SESSION_LOG_PATTERN.test(name)) continue
    const path = join(sessionDir, name)
    try {
      const text = name.endsWith('.zstd')
        ? requireZstd().zstdDecompressSync(readFileSync(path)).toString('utf8')
        : readFileSync(path, 'utf8')
      const firstLine = text.split('\n').find((line) => line.trim().length > 0)
      const header = JSON.parse(firstLine)
      if (typeof header.cwd === 'string' && header.cwd.length > 0) return { cwd: header.cwd, source: `header:${name}` }
    } catch {
      /* try the next generation */
    }
  }
  return null
}

let zstdModule = null
function requireZstd() {
  if (zstdModule === null) {
    if (typeof process.getBuiltinModule === 'function') {
      zstdModule = process.getBuiltinModule('node:zlib')
    } else {
      throw new Error('node:zlib zstd support is required (Node >= 22.15)')
    }
  }
  return zstdModule
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  const home = resolve(args.home)
  const fixture = resolve(args.fixture)
  const repo = resolve(args.officialRepo)
  const realHome = resolve(homedir(), '.dsh')

  if (!existsSync(home) || !statSync(home).isDirectory()) die(`DSH_HOME to seed does not exist: ${home}`)
  if (!existsSync(fixture)) die(`fixture not found: ${fixture}`)
  if (home === realHome && !args.allowRealHome) {
    die(`refusing to seed the real DSH_HOME (${home}); copy it to a temporary directory first (or pass --allow-real-home)`)
  }
  if (!args.sessionId.startsWith('session-')) die(`session id must start with "session-": ${args.sessionId}`)

  const sessionsRoot = join(home, 'sessions')
  if (!existsSync(sessionsRoot)) die(`seeded DSH_HOME has no sessions/: ${sessionsRoot}`)

  // The sidebar groups by the header cwd, so the target session must already
  // have a directory (and thus a workspace group) in the copied home.
  const sessionDirs = []
  for (const encoded of readdirSync(sessionsRoot)) {
    const candidate = join(sessionsRoot, encoded, args.sessionId)
    if (existsSync(candidate) && statSync(candidate).isDirectory()) sessionDirs.push(candidate)
  }
  if (sessionDirs.length !== 1) {
    die(`expected exactly one session directory named ${args.sessionId} under ${sessionsRoot}, found ${sessionDirs.length}`)
  }
  const sessionDir = sessionDirs[0]

  const resolvedCwd = args.cwd === null
    ? resolveCwd(home, args.sessionId, sessionDir)
    : { cwd: resolve(args.cwd), source: 'argument' }
  if (!resolvedCwd) die(`could not resolve the seeded session's cwd from the projcache or its log header; pass --cwd`)
  const cwd = resolvedCwd.cwd

  // Resolve the official built modules. The persistence plugin and its peers
  // are ESM builds; importing the package entries by path keeps their internal
  // bare imports inside the official workspace's node_modules tree.
  const cordis = await importBuilt(repo, [
    'vendor/cordis/lib/index.js',
    'packages/session/session-persistence-jsonl/node_modules/@deepseek-ai/cordis/lib/index.js',
  ])
  const jsonl = await importBuilt(repo, ['packages/session/session-persistence-jsonl/lib/index.js'])
  const replay = await importBuilt(repo, [
    'packages/test-support/llm-replay/lib/index.js',
    'node_modules/@deepseek-ai/dsh-llm-replay/lib/index.js',
  ])
  const sessionPackage = await importBuilt(repo, [
    'packages/core/session/lib/index.js',
    'packages/session/session-persistence-jsonl/node_modules/@deepseek-ai/dsh-session/lib/index.js',
  ])
  const { Context } = cordis.module
  if (typeof Context !== 'function') die(`official cordis build has no Context export: ${cordis.path}`)
  if (typeof jsonl.module.apply !== 'function') die(`official JSONL persistence build has no apply(): ${jsonl.path}`)
  if (typeof sessionPackage.module.SESSION_FORMAT_VERSION !== 'number') {
    die(`official Session build has no SESSION_FORMAT_VERSION: ${sessionPackage.path}`)
  }

  const fixtureText = readFileSync(fixture, 'utf8')
  const realized = realizeFixture(fixtureText, {
    sessionId: args.sessionId,
    cwd,
    home,
    systemText: args.systemText,
  })
  const leftover = [...realized.matchAll(/\{\{([^}]*)\}\}/g)].map((match) => match[1])
  const unknown = [...new Set(leftover)].filter(
    (name) => name !== 'tools' && !RECORDED_PRESENTATION_PLACEHOLDERS.includes(name),
  )
  if (unknown.length > 0) die(`unreplaced placeholder(s) remain: ${unknown.map((name) => `{{${name}}}`).join(', ')}`)
  const keptLiteral = [...new Set(leftover)].filter((name) => RECORDED_PRESENTATION_PLACEHOLDERS.includes(name))

  // Same two steps as the official scaffold: migrate the authored fixture to
  // the current physical format, then decode it into logical events. This is
  // where released-format validation and row admission happen.
  let current
  let events
  try {
    current = replay.module.prepareSessionSnapshotFixtureForComparison(realized)
    events = replay.module.parseSessionLog(current)
  } catch (error) {
    die(`the official format reader rejected the fixture: ${error.message}`)
  }
  if (events.length === 0) die('fixture has no events')
  const last = events[events.length - 1]
  if (last.type !== 'turn/end') die(`fixture must end in turn/end, got ${last.type}`)

  const parsedHeader = JSON.parse(current.split(/\r?\n/).find((line) => line.trim().length > 0))
  if (parsedHeader.id !== args.sessionId) die(`fixture header id ${JSON.stringify(parsedHeader.id)} does not match ${args.sessionId}`)
  if (parsedHeader.cwd !== cwd) die(`fixture header cwd ${JSON.stringify(parsedHeader.cwd)} does not match ${JSON.stringify(cwd)}`)
  if (parsedHeader.version !== 4) die(`fixture must be a v4 log, got version ${parsedHeader.version}`)

  // Clock anchor. A fixture that recorded a real `createdAt` keeps it; a
  // migrated fixture whose header was reset to 0 gets "now - 60s" exactly like
  // the official scaffold, unless the caller pins `--created-at` (the plan
  // review v4 header is 0 while its official v2 sibling recorded the value).
  const createdAtFallback = Date.now() - 60_000
  const fixtureCreatedAt = Number.isSafeInteger(parsedHeader.createdAt) && parsedHeader.createdAt > 0
    ? parsedHeader.createdAt
    : null
  let createdAt
  let createdAtSource
  if (args.createdAt !== null) {
    createdAt = args.createdAt
    createdAtSource = 'argument'
  } else if (fixtureCreatedAt !== null) {
    createdAt = fixtureCreatedAt
    createdAtSource = 'fixture-header'
  } else {
    createdAt = createdAtFallback
    createdAtSource = 'fallback-now-minus-60s'
  }
  const materialized = materializeEvents(events, createdAt)
  const meta = {
    version: sessionPackage.module.SESSION_FORMAT_VERSION,
    id: args.sessionId,
    createdAt,
    isSeeded: false,
    cwd,
    delegationDepth: 0,
  }

  // Replace the previous generation in the copy only. Leaving it next to the
  // new log would make the served transcript depend on generation selection.
  const replacedFiles = []
  for (const name of readdirSync(sessionDir)) {
    if (!SESSION_LOG_PATTERN.test(name) && name !== 'session.lock') continue
    rmSync(join(sessionDir, name), { force: true })
    replacedFiles.push(name)
  }
  const projcachePath = join(home, 'storages', 'session_projcache', 'sessions', `${args.sessionId}.json`)
  const projcacheRemoved = existsSync(projcachePath)
  if (projcacheRemoved) rmSync(projcachePath, { force: true })

  // The real seam: create -> append -> close, with the plugin's own default
  // compression, so header framing, seq assignment and encoding are the
  // backend's, not this script's.
  const ctx = new Context()
  let listed
  let stored
  try {
    await ctx.plugin(jsonl.module, { root: sessionsRoot })
    if (!ctx.sessionPersistence) die('the JSONL persistence plugin did not provide ctx.sessionPersistence')
    const handle = await ctx.sessionPersistence.create(meta)
    try {
      await handle.append(materialized)
    } finally {
      await handle.close()
    }
    listed = await ctx.sessionPersistence.list()
    const read = await ctx.sessionPersistence.open(args.sessionId, 'read')
    try {
      stored = await read.read()
    } finally {
      await read.close()
    }
  } finally {
    await ctx.fiber.dispose()
  }

  // The lease leaves an unlocked placeholder behind; a fresh reader must not
  // treat it as a live writer.
  const lockPath = join(sessionDir, 'session.lock')
  if (existsSync(lockPath)) rmSync(lockPath, { force: true })

  // ------------------------------------------------ verification + provenance
  const listedEntry = listed.find((entry) => entry.header?.id === args.sessionId)
  if (!listedEntry) die(`the JSONL backend did not list ${args.sessionId} after seeding`)
  if (stored.events.length !== materialized.length) {
    die(`re-read returned ${stored.events.length} events, expected ${materialized.length}`)
  }

  const titleEvent = stored.events.find((event) => event.type === 'session/title')
  const title = typeof titleEvent?.data?.title === 'string' ? titleEvent.data.title : null
  if (title === null) die('the stored log has no session/title event; the sidebar would show 未命名')

  const byType = {}
  for (const event of stored.events) byType[event.type] = (byType[event.type] ?? 0) + 1
  for (const required of ['user/message', 'assistant/message', 'tool/call', 'tool/result', 'turn/end']) {
    if ((byType[required] ?? 0) === 0) die(`the stored log has no ${required} event; the transcript would be incomplete`)
  }
  const assistantText = stored.events
    .filter((event) => event.type === 'assistant/message')
    .flatMap((event) => event.data?.message?.content ?? [])
    .filter((block) => block.type === 'text')
    .map((block) => block.text)
  if (assistantText.length === 0) die('the stored log has no assistant text block')

  // Settled tool calls are the evidence a capture labels its state from: a
  // question/plan fixture that carries a `tool/result` renders the answered /
  // approved artifact, not the live review takeover.
  const toolCalls = stored.events
    .filter((event) => event.type === 'tool/call')
    .map((event) => {
      const callId = String(event.data.callId)
      const result = stored.events.find((candidate) => candidate.type === 'tool/result'
        && String(candidate.data?.message?.source?.callId ?? '') === callId)
      const resultText = result === undefined
        ? null
        : (result.data?.message?.content ?? [])
          .filter((block) => block.type === 'text')
          .map((block) => block.text)
          .join('\n')
      return {
        name: event.data.name,
        callId,
        hasResult: result !== undefined,
        resultText,
      }
    })
  const turnEnd = stored.events.at(-1)

  const seededLog = join(sessionDir, 'session.v4.jsonl.zstd')
  if (!existsSync(seededLog)) die(`the JSONL backend did not write ${seededLog}`)
  const seededBuffer = readFileSync(seededLog)

  const summary = {
    generatedAt: new Date().toISOString(),
    officialRepo: repo,
    modules: {
      cordis: cordis.path,
      jsonlPersistence: jsonl.path,
      llmReplay: replay.path,
      session: sessionPackage.path,
    },
    home,
    fixture,
    fixtureSha256: sha256(fixtureText),
    fixtureBytes: Buffer.byteLength(fixtureText),
    fixtureRows: fixtureText.split('\n').filter((line) => line.trim().length > 0).length,
    presentationPlaceholdersKeptLiteral: keptLiteral,
    sessionId: args.sessionId,
    cwd,
    cwdSource: resolvedCwd.source,
    createdAtSource,
    sessionDir,
    meta,
    events: {
      parsed: events.length,
      stored: stored.events.length,
      byType,
      firstSeq: stored.events[0]?.seq ?? null,
      lastSeq: stored.events.at(-1)?.seq ?? null,
      firstTime: stored.events[0]?.time ?? null,
      lastTime: stored.events.at(-1)?.time ?? null,
    },
    title,
    assistantText,
    toolCalls,
    turnEnd: {
      type: turnEnd?.type ?? null,
      reason: turnEnd?.data?.reason?.kind ?? null,
    },
    seededLog,
    seededLogSha256: sha256(seededBuffer),
    seededLogBytes: seededBuffer.length,
    listStatus: listedEntry.formatStatus,
    replacedFiles,
    projcache: { path: projcachePath, removed: projcacheRemoved },
    lockRemoved: true,
  }

  if (args.out) {
    const outPath = resolve(args.out)
    writeFileSync(outPath, `${JSON.stringify(summary, null, 2)}\n`)
  }
  console.log(`[seed-official-session] seeded ${args.sessionId} from ${fixture}`)
  console.log(`[seed-official-session] ${stored.events.length} event(s) seq ${summary.events.firstSeq}..${summary.events.lastSeq} ` +
    `title=${JSON.stringify(title)} cwd=${cwd}`)
  console.log(`[seed-official-session] types=${JSON.stringify(byType)}`)
  console.log(`[seed-official-session] log=${seededLog} sha256=${summary.seededLogSha256}`)
  return 0
}

main().then((code) => {
  process.exit(code ?? 0)
}).catch((error) => {
  die(error?.message ?? String(error))
})
