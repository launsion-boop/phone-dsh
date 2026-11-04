// SPDX-License-Identifier: MIT
// L51: the `ubuntu` command in the Worker's production table.
//
// What these tests pin, and why each one is a fact the Agent depends on:
//
//   1. **Absent unless advertised.** With no boot-probe answer there is no
//      `ubuntu` command, and the shell answers 127 rather than a timeout or a
//      silent success (design §4.3).
//   2. **Present when the probe answered.** The command is one ordinary entry
//      next to `rg`/`jq`, and `which` reports it.
//   3. **The description carries the cost.** The text the model reads is the
//      manifest section and `ubuntu --help`; both must say what it costs and
//      that this build's backend is a mock.
//   4. **The job renderer is honest.** `backend=mock`, the exit code, the log
//      tail and the mock seal are all visible, and a mock `succeeded` keeps the
//      job's own exit code.
//   5. **The host call shape is the contract.** `run` sends
//      `phone ubuntu run --env ... -- <argv...>` with the command unparsed, so
//      no shell re-splits it.
//   6. **The approval gate is fed, not trusted.** The Worker forwards the
//      ambient session id out of band (the dispatch's `sessionId` field, which
//      the bridge writes into the EXEC_REQ `env`), never as an argv flag, and
//      renders the host's decision; a script cannot choose the session, and
//      `--session` is refused by name rather than silently ignored.
//   7. **`fetch` writes through the standard VFS mutation shape.** One complete
//      write of at most 15 MiB, then appended suffixes, and a refusal before
//      the first byte — never a truncated file.
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import { toolCallStorage } from '@phone-dsh/dsh-exec-bridge'
import { VfsFileSystem, WorkerShell } from '../src/index.ts'
import type { IFileSystem } from 'just-bash'
import type { AcceleratorHost, AcceleratorRequest } from '../src/bridge.ts'
import { createWorkerCommands } from '../src/commands.ts'
import {
  UBUNTU_DESCRIPTION,
  UBUNTU_FETCH_CHUNK_BYTES,
  UBUNTU_MUTATION_MAX_BYTES,
  UBUNTU_USAGE,
  exitOfReply,
  getUbuntuCapability,
  renderUbuntuReply,
  setUbuntuCapability,
} from '../src/ubuntu.ts'
import type { UbuntuCapability } from '../src/ubuntu.ts'
import { configureSingleFileLimit, MAX_FILE_SIZE } from '../../wasi-toolbox/src/limits.ts'

/** vfs cwd every invocation runs in. */
const CWD = '/dsh/workspace'

/** The capability a host with a mock environment answers with. */
const CAPABILITY: UbuntuCapability = {
  env: 'ubuntu-24.04',
  backend: 'mock',
  commands: ['run', 'status', 'close'],
}

/** One mock job record as the host tool answers it on stdout. */
const JOB_REPLY = JSON.stringify({
  backend: 'mock',
  env: 'ubuntu-24.04',
  jobId: 'uj-abc',
  state: 'succeeded',
  seq: 4,
  exitCode: 0,
  logTail: 'mock ubuntu-24.04: uj-abc\n',
  artifacts: [{ name: 'tiny.txt', bytes: 12, state: 'available' }],
  failure: null,
  internalAccessObserved: false,
  seal: { state: 'restored', reason: null },
  sealMock: true,
  egress: false,
  authorityExited: 'worker-vfs',
})

const roots: string[] = []

/** A disposable VFS + shell over an explicit command table. */
async function fixture(options: {
  readonly withUbuntu: boolean
  readonly host?: AcceleratorHost
  readonly capability?: UbuntuCapability
}): Promise<{ shell: WorkerShell; calls: AcceleratorRequest[] }> {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-shell-ubuntu-'))
  roots.push(root)
  const fs = new VfsFileSystem({ root })
  await fs.mkdir(CWD, { recursive: true })
  const calls: AcceleratorRequest[] = []
  const host: AcceleratorHost = options.host ?? {
    names: ['phone'],
    async exec(request) {
      calls.push(request)
      return { stdout: Buffer.from(`${JOB_REPLY}\n`, 'utf8').toString('latin1'), stderr: '', exitCode: 0 }
    },
  }
  const commands = createWorkerCommands({
    accelerators: host,
    git: false,
    curl: false,
    gzip: false,
    toolbox: false,
    ...options.withUbuntu ? { ubuntu: options.capability ?? CAPABILITY } : { ubuntu: false },
  })
  return { shell: new WorkerShell({ fs, commands }), calls }
}

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

/**
 * Run one command the way the Agent's calls run: inside a tool call.
 *
 * The session id is identity, so `run`/`status`/`fetch`/`close` refuse to
 * dispatch without one — the host would have no session to bind an approval (or
 * a denial) to. A test that exercises an op therefore has to look like a call.
 * A test that needs the no-context shape (the refusal case) calls `shell.run`
 * directly.
 */
function asToolCall<T>(body: () => Promise<T>, sessionId = 'sess-test'): Promise<T> {
  return toolCallStorage().run(
    { sessionId, callId: 'call-1', key: 'k'.repeat(64), turnId: '1', stepId: '1', spawns: 0 },
    body,
  )
}

test('with no probe answer the command does not exist: exit 127, not a timeout', async () => {
  setUbuntuCapability(undefined)
  const { shell } = await fixture({ withUbuntu: false })
  const result = await shell.run(['bash', '-c', `ubuntu run -- echo hi`], { cwd: CWD })
  assert.equal(result.exitCode, 127)
  assert.match(result.stderr, /ubuntu: (command not found|not found)/iu)
})

test('a host probe answer registers the command and `which` reports it', async () => {
  const { shell } = await fixture({ withUbuntu: true })
  const which = await shell.run(['bash', '-c', 'command -v ubuntu || which ubuntu'], { cwd: CWD })
  assert.equal(which.exitCode, 0)
  assert.match(which.stdout, /ubuntu/u)
})

test('the description states the cost, the approval gate and the mock backend', () => {
  // The Agent reads the manifest section and `--help`; both are this constant.
  // Match across the render's line wraps, which are not part of the facts.
  const text = UBUNTU_DESCRIPTION.replace(/\s+/gu, ' ')
  for (const fact of [
    /separate local Linux environment/u,
    /does not run DSH/u,
    /takes time, uses disk and battery/u,
    // The gate exists now, so the description must describe it: one approval
    // per session, and a refusal that starts nothing.
    /first `run` of a session asks the user to approve it/u,
    /One approval covers every later `run` in the same session/u,
    /cause=approval_denied/u,
    /Close it when you are/u,
    /must not start this environment/u,
    /MOCK adapter/u,
    // The fetch surface and its refusal rule.
    /ubuntu fetch <jobId> <name>/u,
    /VFS_REFUSED/u,
    /never a truncated file/u,
  ]) {
    assert.match(text, fact)
  }
  // The old sentence claimed the gate was absent; it must not come back.
  assert.doesNotMatch(text, /no approval/u)
})

test('a proot backend description states the real environment and never claims a mock', async () => {
  const { shell } = await fixture({
    withUbuntu: true,
    capability: { ...CAPABILITY, backend: 'proot' },
  })
  const result = await shell.run(['ubuntu', '--help'], { cwd: CWD })
  assert.equal(result.exitCode, 0)
  assert.match(result.stdout, /real local Ubuntu environment/u)
  assert.match(result.stdout, /backend=proot/u)
  assert.match(result.stdout, /Ubuntu Base 24\.04\.5/u)
  assert.doesNotMatch(result.stdout, /MOCK adapter/u)
  assert.doesNotMatch(result.stdout, /exit code is synthetic/u)
})

test('ubuntu --help prints the description and usage, exit 0', async () => {
  const { shell } = await fixture({ withUbuntu: true })
  const result = await shell.run(['ubuntu', '--help'], { cwd: CWD })
  assert.equal(result.exitCode, 0)
  assert.equal(result.stderr, '')
  assert.equal(result.stdout, `${UBUNTU_DESCRIPTION}\n${UBUNTU_USAGE}\n`)
})

test('ubuntu with no arguments prints the description but is a usage error', async () => {
  const { shell } = await fixture({ withUbuntu: true })
  const result = await shell.run(['ubuntu'], { cwd: CWD })
  assert.equal(result.exitCode, 2)
  assert.equal(result.stdout, `${UBUNTU_DESCRIPTION}\n`)
  assert.equal(result.stderr, `${UBUNTU_USAGE}\n`)
})

test('run sends the command unparsed after -- and renders the job', async () => {
  const { shell, calls } = await fixture({ withUbuntu: true })
  const result = await asToolCall(() => shell.run(
    ['ubuntu', 'run', '--cwd', '/dsh/workspace', '--label', 'fib', '--', 'gcc', '-o', 'a', 'a.c'],
    { cwd: CWD },
  ))
  assert.equal(result.exitCode, 0, result.stderr)
  const argv = calls[0]?.argv ?? []
  assert.deepEqual(
    [...argv],
    ['phone', 'ubuntu', 'run', '--env', 'ubuntu-24.04', '--cwd', '/dsh/workspace', '--label', 'fib', '--', 'gcc', '-o', 'a', 'a.c'],
  )
  assert.match(result.stdout, /ubuntu: run job=uj-abc state=succeeded exit=0 env=ubuntu-24\.04 backend=mock/u)
  assert.match(result.stdout, /ubuntu: egress=false authorityExited=worker-vfs/u)
  assert.match(result.stdout, /seal=restored.*mock: this adapter seals no workspace.*internalAccessObserved=false/u)
  assert.match(result.stdout, /--- log tail ---\nmock ubuntu-24\.04: uj-abc/u)
  assert.match(result.stdout, /tiny\.txt 12 B available/u)
})

test('run requires the -- separator and a command', async () => {
  const { shell, calls } = await fixture({ withUbuntu: true })
  const missing = await asToolCall(() => shell.run(['ubuntu', 'run', 'gcc', '-o', 'a', 'a.c'], { cwd: CWD }))
  assert.equal(missing.exitCode, 2)
  assert.match(missing.stderr, /put the command after `--`/u)
  const noCommand = await asToolCall(() => shell.run(['ubuntu', 'run', '--'], { cwd: CWD }))
  assert.equal(noCommand.exitCode, 2)
  assert.match(noCommand.stderr, /needs a command after `--`/u)
  assert.equal(calls.length, 0)
})

test('a proot close says the cached rootfs stays, never that files were discarded', async () => {
  const { shell } = await fixture({
    withUbuntu: true,
    capability: { ...CAPABILITY, backend: 'proot' },
  })
  const result = await asToolCall(() => shell.run(['ubuntu', 'close'], { cwd: CWD }))
  assert.equal(result.exitCode, 0)
  assert.match(result.stdout, /cached Ubuntu rootfs stays on disk/u)
  assert.doesNotMatch(result.stdout, /not kept/u)
})

test('status sends exactly the job id and renders the record', async () => {
  const { shell, calls } = await fixture({ withUbuntu: true })
  const result = await asToolCall(() => shell.run(['ubuntu', 'status', 'uj-abc'], { cwd: CWD }))
  assert.equal(result.exitCode, 0)
  assert.deepEqual([...(calls[0]?.argv ?? [])], ['phone', 'ubuntu', 'status', 'uj-abc'])
  assert.match(result.stdout, /ubuntu: status job=uj-abc/u)
  const bad = await asToolCall(() => shell.run(['ubuntu', 'status'], { cwd: CWD }))
  assert.equal(bad.exitCode, 2)
  assert.match(bad.stderr, /status needs exactly one job id/u)
})

test('close reports that files are not kept', async () => {
  const { shell, calls } = await fixture({ withUbuntu: true })
  const result = await asToolCall(() => shell.run(['ubuntu', 'close'], { cwd: CWD }))
  assert.equal(result.exitCode, 0)
  assert.deepEqual([...(calls[0]?.argv ?? [])], ['phone', 'ubuntu', 'close'])
  assert.match(result.stdout, /closed\. Files inside the environment are not kept/u)
})

test('a host refusal is 127 with the reason, not a fake success', async () => {
  const { shell } = await fixture({
    withUbuntu: true,
    host: {
      names: ['phone'],
      async exec() {
        return {
          stdout: '',
          stderr: 'phone: ubuntu: this host does not provide that phone tool; nothing executed\n',
          exitCode: 127,
        }
      },
    },
  })
  const result = await asToolCall(() => shell.run(['ubuntu', 'run', '--', 'true'], { cwd: CWD }))
  assert.equal(result.exitCode, 127)
  assert.match(result.stderr, /this host cannot answer that job/u)
  assert.match(result.stderr, /does not provide the local environment/u)
})

test('an unknown job is non-zero and its open window is rendered null', () => {
  const text = renderUbuntuReply({
    state: 'unknown',
    jobId: 'uj-missing',
    internalAccessObserved: null,
    seal: { state: 'pending' },
  }, 'status')
  assert.match(text, /state=unknown/u)
  assert.match(text, /seal=pending internalAccessObserved=null/u)
  assert.equal(exitOfReply({ state: 'unknown' }), 1)
  assert.equal(exitOfReply({ state: 'succeeded', exitCode: 0 }), 0)
  assert.equal(exitOfReply({ state: 'succeeded', exitCode: 3 }), 3)
})

test('a mock ingestRefused job is non-zero even when the command exited 0', () => {
  assert.equal(
    exitOfReply({ state: 'ingestRefused', exitCode: 0 }),
    1,
  )
  assert.match(
    renderUbuntuReply({
      state: 'ingestRefused',
      exitCode: 0,
      artifacts: [{ name: 'huge.bin', bytes: 20 * 1024 * 1024, state: 'refused' }],
    }, 'run'),
    /huge\.bin 20 MiB refused/u,
  )
})

test('the published capability is what the table reads and is cleared again', async () => {
  try {
    setUbuntuCapability(CAPABILITY)
    assert.deepEqual(getUbuntuCapability(), CAPABILITY)
    const { shell } = await fixture({ withUbuntu: true })
    const result = await shell.run(['ubuntu', '--help'], { cwd: CWD })
    assert.equal(result.exitCode, 0)
  } finally {
    setUbuntuCapability(undefined)
  }
  assert.equal(getUbuntuCapability(), undefined)
  // A table built after the answer was cleared has no command again.
  const { shell } = await fixture({ withUbuntu: false })
  const result = await shell.run(['bash', '-c', 'ubuntu'], { cwd: CWD })
  assert.equal(result.exitCode, 127)
})

// ---------------------------------------------------------------------------
// The approval gate: the Worker forwards identity, the host decides
// ---------------------------------------------------------------------------

test('run forwards the trusted session id out of band, never as an argv word', async () => {
  const { shell, calls } = await fixture({ withUbuntu: true })
  const result = await asToolCall(() => shell.run(['ubuntu', 'run', '--', 'true'], { cwd: CWD }))
  assert.equal(result.exitCode, 0, result.stderr)
  // The session is identity: it rides the dispatch field, and the host argv a
  // script can also type (`phone ubuntu run ...`) carries no way to choose one.
  assert.deepEqual(
    [...(calls[0]?.argv ?? [])],
    ['phone', 'ubuntu', 'run', '--env', 'ubuntu-24.04', '--', 'true'],
  )
  assert.equal((calls[0]?.argv ?? []).includes('--session'), false)
  assert.equal(calls[0]?.sessionId, 'sess-test')
})

test('a script cannot choose the session: --session is refused by name, not ignored', async () => {
  const { shell, calls } = await fixture({ withUbuntu: true })
  const forged = await asToolCall(() => shell.run(['ubuntu', 'run', '--session', 'sess-forged', '--', 'true'], { cwd: CWD }))
  assert.equal(forged.exitCode, 2)
  assert.match(forged.stderr, /--session is not a flag/u)
  assert.equal(calls.length, 0)
})

test('a run with no tool-call context is refused in the Worker and never reaches the host', async () => {
  // No ambient tool-call context means no session to bind an approval to. The
  // honest answer is a refusal that starts nothing, not a dispatch the host has
  // to guess about — and definitely not a prompt the user cannot attribute.
  const { shell, calls } = await fixture({ withUbuntu: true })
  // Deliberately NOT `asToolCall`: this is the shape the Worker shell produces
  // when no tool-call context exists.
  const result = await shell.run(['ubuntu', 'run', '--', 'true'], { cwd: CWD })
  assert.equal(result.exitCode, 1)
  assert.match(result.stderr, /needs the session of the tool call/u)
  assert.equal(calls.length, 0)
})

test('a denied run renders the decision and the honest cause', () => {
  const text = renderUbuntuReply({
    state: 'failed',
    jobId: 'uj-denied',
    approval: { state: 'denied', sessionId: 'sess-a' },
    failure: {
      code: 'cancelled',
      outcome: 'not_started',
      cause: 'approval_denied',
      message: 'the user declined the local environment for this session; nothing was started',
    },
    seal: { state: 'pending' },
    internalAccessObserved: null,
    egress: false,
  }, 'run')
  assert.match(text, /ubuntu: approval=denied/u)
  assert.match(text, /failure code=cancelled outcome=not_started cause=approval_denied/u)
  assert.match(text, /the user declined the local environment for this session/u)
  assert.equal(exitOfReply({ state: 'failed' }), 1)
})

// ---------------------------------------------------------------------------
// `ubuntu fetch`: chunks in, one complete write plus appends out
// ---------------------------------------------------------------------------

interface RecordedWrite {
  readonly op: 'writeFile' | 'appendFile'
  readonly path: string
  readonly size: number
}

interface FetchHostOptions {
  readonly total: number
  readonly fileLimitBytes?: number
  readonly workspaceLimitBytes?: number
  readonly refusal?: { readonly name: string; readonly reason: string; readonly limit: number; readonly bytes: number }
}

/** A host that serves one deterministic artifact in 512 KiB chunks. */
function artifactHost(options: FetchHostOptions): AcceleratorHost & { calls: AcceleratorRequest[] } {
  const calls: AcceleratorRequest[] = []
  const limits = {
    fileLimitBytes: options.fileLimitBytes ?? 128 * 1024 * 1024,
    workspaceLimitBytes: options.workspaceLimitBytes ?? 288 * 1024 * 1024,
    rssLimitBytes: null,
  }
  const reply = (payload: Record<string, unknown>): { stdout: string; stderr: string; exitCode: number } => ({
    stdout: Buffer.from(`${JSON.stringify(payload)}\n`, 'utf8').toString('latin1'),
    stderr: '',
    exitCode: 0,
  })
  return {
    names: ['phone'],
    calls,
    async exec(request) {
      calls.push(request)
      const argv = request.argv
      if (argv[2] !== 'fetch') {
        return reply(JSON.parse(JOB_REPLY) as Record<string, unknown>)
      }
      const name = argv[4] ?? ''
      const offsetIndex = argv.indexOf('--offset')
      const offset = offsetIndex >= 0 ? Number(argv[offsetIndex + 1] ?? 0) : 0
      if (options.refusal !== undefined && name === options.refusal.name) {
        return reply({
          backend: 'mock',
          jobId: argv[3] ?? 'uj-abc',
          name,
          offset: 0,
          bytes: options.refusal.bytes,
          eof: false,
          chunk: null,
          refusal: {
            code: 'VFS_REFUSED',
            reason: options.refusal.reason,
            limit: options.refusal.limit,
            bytes: options.refusal.bytes,
          },
          failure: null,
          limits,
        })
      }
      const size = Math.min(UBUNTU_FETCH_CHUNK_BYTES, options.total - offset)
      const data = Buffer.alloc(size)
      for (let index = 0; index < size; index++) data[index] = (offset + index) & 0xff
      return reply({
        backend: 'mock',
        jobId: argv[3] ?? 'uj-abc',
        name,
        offset,
        bytes: options.total,
        eof: offset + size >= options.total,
        chunk: data.toString('base64'),
        refusal: null,
        failure: null,
        limits,
      })
    },
  }
}

/** A VFS that records every write the command performs. */
function recordingFs(inner: IFileSystem): { fs: IFileSystem; writes: RecordedWrite[] } {
  const writes: RecordedWrite[] = []
  const proxy = new Proxy(inner, {
    get(target, property) {
      if (property === 'writeFile' || property === 'appendFile') {
        return async (path: string, content: string | Uint8Array) => {
          const size = typeof content === 'string' ? Buffer.byteLength(content) : content.byteLength
          writes.push({ op: property, path, size })
          const method = target[property] as (p: string, c: string | Uint8Array) => Promise<void>
          return await method.call(target, path, content)
        }
      }
      const value = Reflect.get(target, property)
      return typeof value === 'function' ? value.bind(target) : value
    },
  }) as IFileSystem
  return { fs: proxy, writes }
}

/** A shell whose VFS is a fresh temp root and whose writes are recorded. */
function fetchFixture(options: FetchHostOptions): {
  readonly root: string
  readonly fs: VfsFileSystem
  readonly shell: WorkerShell
  readonly host: AcceleratorHost & { calls: AcceleratorRequest[] }
  readonly writes: RecordedWrite[]
} {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-shell-ubuntu-fetch-'))
  roots.push(root)
  const rawFs = new VfsFileSystem({ root })
  const { fs, writes } = recordingFs(rawFs)
  const host = artifactHost(options)
  const commands = createWorkerCommands({
    accelerators: host,
    git: false,
    curl: false,
    gzip: false,
    toolbox: false,
    ubuntu: CAPABILITY,
  })
  return { root, fs: rawFs, shell: new WorkerShell({ fs, commands }), host, writes }
}

/** The temp-root path of a VFS path. */
function onDisk(root: string, vfsPath: string): string {
  return join(root, vfsPath.replace(/^\//u, ''))
}

/**
 * The writes that landed under the workspace.
 *
 * The shell materializes `/dsh/home/capabilities.json` on first use; that is
 * not the artifact being tested, and counting it would make every assertion
 * about mutations wrong for a reason unrelated to `fetch`.
 */
function artifactWrites(fixture: { readonly writes: readonly RecordedWrite[] }): RecordedWrite[] {
  return fixture.writes.filter(write => write.path.startsWith('/dsh/workspace/'))
}

test('fetch writes a small artifact as one complete mutation', async () => {
  const fixture = fetchFixture({ total: 12 })
  const result = await asToolCall(() => fixture.shell.run(['ubuntu', 'fetch', 'uj-abc', 'tiny.txt'], { cwd: CWD }))
  assert.equal(result.exitCode, 0, result.stderr)
  assert.match(result.stdout, /ubuntu: fetch job=uj-abc artifact=tiny\.txt bytes=12/u)
  assert.match(result.stdout, /ubuntu: wrote \/dsh\/workspace\/\.ubuntu\/uj-abc\/tiny\.txt/u)
  // One complete write, no append: the ordinary case is one mutation.
  assert.deepEqual(
    artifactWrites(fixture).map(write => [write.op, write.size]),
    [['writeFile', 12]],
  )
  const written = readFileSync(onDisk(fixture.root, '/dsh/workspace/.ubuntu/uj-abc/tiny.txt'))
  assert.equal(written.byteLength, 12)
  assert.equal(written[3], 3)
})

test('fetch splits 15 MiB + 512 KiB into a complete write and one appended suffix', async () => {
  const total = UBUNTU_MUTATION_MAX_BYTES + UBUNTU_FETCH_CHUNK_BYTES
  const fixture = fetchFixture({ total })
  const result = await asToolCall(() => fixture.shell.run(['ubuntu', 'fetch', 'uj-abc', 'mid.bin'], { cwd: CWD }))
  assert.equal(result.exitCode, 0, result.stderr)
  assert.match(result.stdout, /chunks=31 mutations=2/u)
  assert.deepEqual(
    artifactWrites(fixture).map(write => [write.op, write.size]),
    [['writeFile', UBUNTU_MUTATION_MAX_BYTES], ['appendFile', UBUNTU_FETCH_CHUNK_BYTES]],
  )
  const written = readFileSync(onDisk(fixture.root, '/dsh/workspace/.ubuntu/uj-abc/mid.bin'))
  assert.equal(written.byteLength, total)
  assert.equal(written[total - 1], (total - 1) & 0xff)
})

test('fetch refuses an over-limit artifact before writing a byte', async () => {
  const fixture = fetchFixture({
    total: 20 * 1024 * 1024,
    refusal: {
      name: 'huge.bin',
      reason: 'file-too-large',
      limit: 16 * 1024 * 1024,
      bytes: 20 * 1024 * 1024,
    },
  })
  const result = await asToolCall(() => fixture.shell.run(['ubuntu', 'fetch', 'uj-abc', 'huge.bin'], { cwd: CWD }))
  assert.equal(result.exitCode, 1)
  assert.match(result.stdout, /VFS_REFUSED reason=file-too-large limit=16777216 bytes=20971520/u)
  assert.match(result.stdout, /nothing was written/u)
  assert.deepEqual(artifactWrites(fixture), [])
})

test('fetch preflights the workspace bucket before writing', async () => {
  const fixture = fetchFixture({ total: 200, workspaceLimitBytes: 100 })
  const result = await asToolCall(() => fixture.shell.run(['ubuntu', 'fetch', 'uj-abc', 'tiny.txt'], { cwd: CWD }))
  assert.equal(result.exitCode, 1)
  assert.match(result.stdout, /VFS_REFUSED reason=quota-exceeded limit=100 bytes=200/u)
  assert.deepEqual(artifactWrites(fixture), [])
})

test('fetch preflights the Worker single-file budget before writing', async () => {
  const before = MAX_FILE_SIZE
  try {
    configureSingleFileLimit(1024 * 1024)
    const fixture = fetchFixture({ total: 2 * 1024 * 1024 })
    const result = await asToolCall(() => fixture.shell.run(['ubuntu', 'fetch', 'uj-abc', 'big.bin'], { cwd: CWD }))
    assert.equal(result.exitCode, 1)
    assert.match(result.stdout, /VFS_REFUSED reason=file-too-large limit=1048576/u)
    assert.deepEqual(artifactWrites(fixture), [])
  } finally {
    configureSingleFileLimit(before)
  }
})

test('fetch preflights the launch-published single-file budget before writing', async () => {
  // The device publishes its tier limit as PDSH_SINGLE_FILE_LIMIT_BYTES; the VFS
  // enforces it, and the CLI must use the same number. Using the process-wide
  // default here would write 15 MiB and only then fail on the append.
  const before = process.env.PDSH_SINGLE_FILE_LIMIT_BYTES
  process.env.PDSH_SINGLE_FILE_LIMIT_BYTES = String(16 * 1024 * 1024)
  try {
    const fixture = fetchFixture({ total: 20 * 1024 * 1024 })
    const result = await asToolCall(() => fixture.shell.run(['ubuntu', 'fetch', 'uj-abc', 'huge.bin'], { cwd: CWD }))
    assert.equal(result.exitCode, 1)
    assert.match(result.stdout, /VFS_REFUSED reason=file-too-large limit=16777216 bytes=20971520/u)
    assert.match(result.stdout, /nothing was written/u)
    assert.deepEqual(artifactWrites(fixture), [])
  } finally {
    if (before === undefined) delete process.env.PDSH_SINGLE_FILE_LIMIT_BYTES
    else process.env.PDSH_SINGLE_FILE_LIMIT_BYTES = before
  }
})

test('fetch --offset resumes at the accepted prefix instead of rewriting it', async () => {
  const fixture = fetchFixture({ total: 12 })
  // The chain stopped after 4 bytes; resuming must append, not rewrite.
  await fixture.fs.mkdir('/dsh/workspace/.ubuntu/uj-abc', { recursive: true })
  await fixture.fs.writeFile('/dsh/workspace/.ubuntu/uj-abc/tiny.bin', new Uint8Array([0, 1, 2, 3]))
  const result = await asToolCall(() => fixture.shell.run(
    ['ubuntu', 'fetch', 'uj-abc', 'tiny.bin', '--offset', '4'],
    { cwd: CWD },
  ))
  assert.equal(result.exitCode, 0, result.stderr)
  assert.deepEqual(
    artifactWrites(fixture).map(write => [write.op, write.size]),
    [['appendFile', 8]],
  )
  const written = readFileSync(onDisk(fixture.root, '/dsh/workspace/.ubuntu/uj-abc/tiny.bin'))
  assert.deepEqual([...written], [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
})

test('fetch --offset refuses a file that is not the stated prefix', async () => {
  const fixture = fetchFixture({ total: 12 })
  await fixture.fs.mkdir('/dsh/workspace/.ubuntu/uj-abc', { recursive: true })
  await fixture.fs.writeFile('/dsh/workspace/.ubuntu/uj-abc/tiny.bin', new Uint8Array([0, 1, 2]))
  const result = await asToolCall(() => fixture.shell.run(
    ['ubuntu', 'fetch', 'uj-abc', 'tiny.bin', '--offset', '4'],
    { cwd: CWD },
  ))
  assert.equal(result.exitCode, 1)
  assert.match(result.stderr, /--offset 4 does not match/u)
  assert.deepEqual(artifactWrites(fixture), [])
})

test('fetch resolves --path under the cwd and refuses a non-mutation path', async () => {
  const fixture = fetchFixture({ total: 12 })
  const result = await asToolCall(() => fixture.shell.run(
    ['ubuntu', 'fetch', 'uj-abc', 'tiny.txt', '--path', 'out/tiny.txt'],
    { cwd: CWD },
  ))
  assert.equal(result.exitCode, 0, result.stderr)
  assert.match(result.stdout, /wrote \/dsh\/workspace\/out\/tiny\.txt/u)
  assert.deepEqual(artifactWrites(fixture).map(write => write.path), ['/dsh/workspace/out/tiny.txt'])
  assert.equal(readFileSync(onDisk(fixture.root, '/dsh/workspace/out/tiny.txt')).byteLength, 12)

  const before = fixture.host.calls.length
  const refused = await asToolCall(() => fixture.shell.run(
    ['ubuntu', 'fetch', 'uj-abc', 'tiny.txt', '--path', '/dsh/home/tiny.txt'],
    { cwd: CWD },
  ))
  assert.equal(refused.exitCode, 2)
  assert.match(refused.stderr, /not a \/dsh\/workspace mutation path/u)
  assert.equal(fixture.host.calls.length, before)
})

test('fetch refuses to overwrite an explicit path it did not write', async () => {
  const fixture = fetchFixture({ total: 12 })
  await fixture.fs.mkdir('/dsh/workspace/out', { recursive: true })
  await fixture.fs.writeFile('/dsh/workspace/out/existing.txt', new Uint8Array([9, 9, 9]))
  const result = await asToolCall(() => fixture.shell.run(
    ['ubuntu', 'fetch', 'uj-abc', 'tiny.txt', '--path', 'out/existing.txt'],
    { cwd: CWD },
  ))
  assert.equal(result.exitCode, 1)
  assert.match(result.stderr, /refusing to overwrite a file this job did not write/u)
  assert.deepEqual(artifactWrites(fixture), [])
})

test('fetch rejects a malformed invocation as a usage error', async () => {
  const { shell, calls } = await fixture({ withUbuntu: true })
  const missing = await asToolCall(() => shell.run(['ubuntu', 'fetch', 'uj-abc'], { cwd: CWD }))
  assert.equal(missing.exitCode, 2)
  assert.match(missing.stderr, /fetch needs exactly one job id and one artifact name/u)
  const badOffset = await asToolCall(() => shell.run(['ubuntu', 'fetch', 'uj-abc', 'tiny.txt', '--offset', '-1'], { cwd: CWD }))
  assert.equal(badOffset.exitCode, 2)
  assert.match(badOffset.stderr, /--offset takes a non-negative decimal integer/u)
  assert.equal(calls.length, 0)
})
