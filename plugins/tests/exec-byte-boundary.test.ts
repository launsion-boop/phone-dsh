// SPDX-License-Identifier: MIT
// G2-FIX-43: one byte boundary, one decode.
//
// The real-model phone batch corrupted non-ASCII bytes on several Worker exec
// paths because they disagreed about what a JS string at the boundary meant:
// `read` left the stdin byte string in its variables, the WASI toolbox
// returned its stdout byte string as text, and the accelerator bridge decoded
// and re-encoded what it forwarded. A CJK+emoji fixture is round-tripped
// through every boundary named by the defect and compared byte for byte.
//
// The tests drive the real `WorkerShell` and the real `VfsFileSystem` over a
// real temporary directory (the desktop face of the Worker VFS), the real
// accelerator dispatcher and the real toolbox command bridge. The python3
// program is the same byte-echo stub the other toolbox tests use, so no wasm
// artifact is needed: the boundary under test is the shell ↔ toolbox stream,
// not CPython itself.
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { after, test } from 'node:test'
import type { CustomCommand } from 'just-bash'
import type { ExecClient, ExecEvent, ExecRequest, EventStream, Hello } from '@phone-dsh/dsh-exec-bridge'
import { toolCallStorage } from '../exec-bridge/src/index.ts'
import type { ToolboxRunRequest, WorkerToolbox } from '@phone-dsh/dsh-wasi-toolbox'
import { createGitCommand } from '@phone-dsh/dsh-wasi-toolbox/git'
import {
  VfsFileSystem,
  WorkerShell,
  createAcceleratorCommands,
  createExecBridgeAccelerators,
  createToolboxCommands,
} from '../shell-ext/src/index.ts'

const encoder = new TextEncoder()
const roots: string[] = []

after(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true })
})

/** The virtual cwd every shell invocation runs in. */
const CWD = '/dsh/workspace'

/** A CJK + emoji + Latin-1-accented line: every byte width of UTF-8. */
const WIDE_TEXT = '王敏 市场部 🙂 café\n'

interface Fixture {
  readonly root: string
  readonly fs: VfsFileSystem
  readonly shell: WorkerShell
}

/** One Worker shell over a real temporary tree. */
async function fixture(commands: readonly CustomCommand[] = []): Promise<Fixture> {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-byte-boundary-'))
  roots.push(root)
  const fs = new VfsFileSystem({ root })
  await fs.mkdir(CWD, { recursive: true })
  return { root, fs, shell: new WorkerShell({ fs, commands }) }
}

/** The bytes of a virtual file. */
async function fileBytes(fs: VfsFileSystem, path: string): Promise<number[]> {
  return [...await fs.readFileBuffer(path)]
}

/** The bytes of a real file below the fixture root. */
function realBytes(root: string, path: string): number[] {
  return [...readFileSync(join(root, path))]
}

/**
 * A `python3` program that echoes its stdin bytes to stdout.
 *
 * `python3 -c 'sys.stdout.buffer.write(sys.stdin.buffer.read())'` is the exact
 * stdio shape the scenario used; the stub exercises the shell ↔ toolbox byte
 * boundary (heredoc stdin in, stdout out) without a real interpreter.
 */
function byteEchoToolbox(): WorkerToolbox {
  const preopens = [{ guestPath: CWD, hostPath: CWD }]
  return {
    preopenTable: preopens,
    list: () => [{ program: 'python3', aliases: ['python'], description: 'byte echo stub' }],
    has: (program: string) => program === 'python3' || program === 'python',
    run: async (request: ToolboxRunRequest) => {
      const stdin = request.stdin ?? new Uint8Array(0)
      if (stdin.byteLength > 0) request.onStdout?.(Uint8Array.from(stdin))
      return {
        program: 'python3',
        exitCode: 0,
        cancelled: false,
        memoryExceeded: false,
        memoryPeakBytes: 0,
        stdoutBytes: stdin.byteLength,
        stderrBytes: 0,
      }
    },
  } as unknown as WorkerToolbox
}

test('shell read into a variable and write it back keeps every byte', async () => {
  const { fs, shell } = await fixture()
  await fs.writeFile(`${CWD}/source.txt`, WIDE_TEXT)
  const result = await shell.runScript('read -r line < source.txt; printf "%s\\n" "$line" > copy.txt', { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.deepEqual(await fileBytes(fs, `${CWD}/copy.txt`), [...encoder.encode(WIDE_TEXT)])
})

test('a while-IFS-read loop keeps CJK fields and CJK file names byte-identical', async () => {
  const { root, fs, shell } = await fixture()
  await fs.writeFile(
    `${CWD}/recipients.csv`,
    '姓名,部门,金额,截止日期\n王敏,市场部,1280.00,2026-12-05\n李强,研发部,960.00,2026-12-05\n',
  )
  const result = await shell.runScript(`mkdir -p letters
tail -n +2 recipients.csv | while IFS=, read -r name dept amount deadline; do
  printf '%s,%s,%s,%s\\n' "$name" "$dept" "$amount" "$deadline" >> rows.txt
  printf '%s\\n' "$name" > "letters/$name.md"
done
`, { cwd: CWD })
  assert.equal(result.exitCode, 0, result.stderr)
  // The CSV rows keep their exact field text: no field was decoded twice.
  assert.deepEqual(
    await fileBytes(fs, `${CWD}/rows.txt`),
    [...encoder.encode('王敏,市场部,1280.00,2026-12-05\n李强,研发部,960.00,2026-12-05\n')],
  )
  // The redirect target is built from the same variable: file names stay the
  // exact bytes the CSV carried (the G2-E03 `C3A7 C28E C28B` path).
  assert.deepEqual(readdirSync(join(root, 'dsh/workspace/letters')).sort(), ['李强.md', '王敏.md'])
  assert.deepEqual(
    realBytes(root, 'dsh/workspace/letters/王敏.md'),
    [...encoder.encode('王敏\n')],
  )
})

test('read status survives the decode shim (`if`, `!`, `&&`, `while` termination)', async () => {
  const { fs, shell } = await fixture()
  await fs.writeFile(`${CWD}/empty.txt`, '')
  await fs.writeFile(`${CWD}/source.txt`, WIDE_TEXT)
  const result = await shell.runScript(
    'if read -r line < empty.txt; then echo yes; else echo no; fi; '
    + 'read -r line < empty.txt && echo taken || echo refused; '
    + 'n=0; while read -r row < empty.txt; do n=$((n+1)); done; echo count=$n',
    { cwd: CWD },
  )
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(result.stdout, 'no\nrefused\ncount=0\n')

  // A negated pipeline is still decoded: `! read` inverts the status the
  // helper replays, and the variable it assigned keeps its bytes.
  const negated = await shell.runScript(
    'if ! read -r negated < source.txt; then echo neg-fail; else printf "%s" "$negated" > negated.txt; fi',
    { cwd: CWD },
  )
  assert.equal(negated.exitCode, 0, negated.stderr)
  assert.equal(negated.stdout, '')
  assert.deepEqual(await fileBytes(fs, `${CWD}/negated.txt`), [...encoder.encode(WIDE_TEXT.trimEnd())])

  // The `read || [ -n "$line" ]` idiom keeps decoding: the read is the first
  // command of its chain and therefore always runs.
  await fs.writeFile(`${CWD}/lines.txt`, '王敏\n李强\n周洁')
  const chain = await shell.runScript(
    'while IFS= read -r row || [ -n "$row" ]; do printf "%s|" "$row" >> chain.txt; done < lines.txt',
    { cwd: CWD },
  )
  assert.equal(chain.exitCode, 0, chain.stderr)
  assert.deepEqual(await fileBytes(fs, `${CWD}/chain.txt`), [...encoder.encode('王敏|李强|周洁|')])

  // A read that a short circuit skipped must not be decoded: the variable was
  // never assigned by `read`, so its existing text has to stay untouched.
  const skipped = await shell.runScript(
    'kept=中文保持不变; false && read -r kept < source.txt; printf "%s" "$kept" > kept.txt',
    { cwd: CWD },
  )
  assert.equal(skipped.exitCode, 0, skipped.stderr)
  assert.deepEqual(await fileBytes(fs, `${CWD}/kept.txt`), [...encoder.encode('中文保持不变')])
})

test('a heredoc piped to python3 keeps the stdin/stdout bytes', async () => {
  const { fs, shell } = await fixture(createToolboxCommands(byteEchoToolbox()))
  const body = '中文🙂 café 王敏\nsecond 行'
  const result = await shell.runScript(
    `python3 -c 'import sys; sys.stdout.buffer.write(sys.stdin.buffer.read())' <<'PY' > echo.txt\n${body}\nPY`,
    { cwd: CWD },
  )
  assert.equal(result.exitCode, 0, result.stderr)
  assert.deepEqual(await fileBytes(fs, `${CWD}/echo.txt`), [...encoder.encode(`${body}\n`)])

  // The same bytes through a pipeline stage (`python3 | cat`) and a redirect.
  const piped = await shell.runScript(`python3 - <<'PY' | cat > piped.txt\n${body}\nPY`, { cwd: CWD })
  assert.equal(piped.exitCode, 0, piped.stderr)
  assert.deepEqual(await fileBytes(fs, `${CWD}/piped.txt`), [...encoder.encode(`${body}\n`)])
})

test('a sourced script printing CJK writes the same bytes it printed', async () => {
  const { fs, shell } = await fixture()
  const notice = '通知：本轮截止 2026-11-28 🙂\n第二行 café\n'
  await fs.writeFile(`${CWD}/notice.sh`, `printf '%s\\n' '通知：本轮截止 2026-11-28 🙂'\nprintf '%s\\n' '第二行 café'\n`)
  const printed = await shell.runScript('. ./notice.sh', { cwd: CWD })
  assert.equal(printed.exitCode, 0, printed.stderr)
  assert.equal(printed.stdout, notice)

  const redirected = await shell.runScript('. ./notice.sh > sourced.txt', { cwd: CWD })
  assert.equal(redirected.exitCode, 0, redirected.stderr)
  assert.deepEqual(await fileBytes(fs, `${CWD}/sourced.txt`), [...encoder.encode(notice)])
})

/** One exec-bridge SSE client that replays fixed events. */
class FakeClient implements Pick<ExecClient, 'exec' | 'cancel'> {
  readonly requests: ExecRequest[] = []
  events: ExecEvent[] = []

  async exec(request: ExecRequest, _signal?: AbortSignal): Promise<EventStream> {
    this.requests.push(request)
    const events = this.events
    return {
      async *[Symbol.asyncIterator](): AsyncGenerator<ExecEvent> {
        for (const event of events) yield event
      },
      close(): void {},
    }
  }

  async cancel(): Promise<void> {}
}

/** Host HELLO advertising one accelerator. */
function hello(accelerators: string[]): Hello {
  return {
    protocol: 'pdsh-exec-bridge/1',
    provider: { name: 'test-host', version: '1' },
    guest: { platform: 'posix', mounts: [] },
    capabilities: { exec: true, accelerators },
    limits: {},
  }
}

test('an accelerator forwards stdin and stdout as bytes, not re-encoded text', async () => {
  const { fs } = await fixture()
  // Bytes that are not valid UTF-8 at all plus a UTF-8 CJK sequence: a
  // decode/re-encode path can never reproduce this stream.
  const payload = new Uint8Array([0x00, 0xff, 0xfe, 0x80, 0xc3, 0x28, 0xe7, 0x8e, 0x8b, 0x0a])
  await fs.writeFile(`${CWD}/input.bin`, payload)
  const client = new FakeClient()
  client.events = [
    { type: 'output', exec_id: 'x', seq: 1, stream: 'stdout', data: Buffer.from(payload).toString('base64') },
    { type: 'exit', exec_id: 'x', seq: 2, code: 0, signal: null, status: 'exited', quiescent: true },
  ]
  const host = createExecBridgeAccelerators({ client, hello: hello(['rg']), revision: () => 0n })
  const shellWithAccelerator = new WorkerShell({ fs, commands: createAcceleratorCommands(host) })
  const key = 'xl1-0f1e2d3c4b5a69788796a5b4c3d2e1f0'
  const result = await toolCallStorage().run(
    { sessionId: 's', callId: 'c', key, turnId: '1', stepId: '1', spawns: 0 },
    () => shellWithAccelerator.run(['bash', '-c', 'rg needle < input.bin > output.bin'], { cwd: CWD }),
  )
  assert.equal(result.exitCode, 0, result.stderr)
  assert.equal(client.requests.length, 1)
  const stdin = (client.requests[0] as ExecRequest).stdin
  assert.equal(stdin?.mode, 'data')
  assert.deepEqual(
    [...Buffer.from(stdin?.mode === 'data' ? stdin.data : '', 'base64')],
    [...payload],
    'the accelerator receives the exact stdin bytes',
  )
  assert.deepEqual(await fileBytes(fs, `${CWD}/output.bin`), [...payload], 'the redirection keeps the exact stdout bytes')
})

test('git stdout over a CJK path keeps every byte in a redirection', async () => {
  const root = mkdtempSync(join(tmpdir(), 'pdsh-byte-git-'))
  roots.push(root)
  mkdirSync(join(root, 'repo'))
  const shell = new WorkerShell({
    fs: new VfsFileSystem({ root: '' }),
    commands: [createGitCommand()],
  })
  const repo = join(root, 'repo')
  const init = await shell.run(['bash', '-c', 'git init -b main && git config user.email dev@example.invalid && git config user.name dev'], { cwd: repo })
  assert.equal(init.exitCode, 0, init.stderr)
  writeFileSync(join(repo, '王敏.txt'), 'content\n')
  // The redirect target stays outside the repository so it does not become an
  // extra untracked entry in git's own output.
  const result = await shell.run(['bash', '-c', 'git add -A && git status --porcelain > ../status.txt'], { cwd: repo })
  assert.equal(result.exitCode, 0, result.stderr)
  assert.deepEqual([...readFileSync(join(root, 'status.txt'))], [...encoder.encode('A  王敏.txt\n')])
})
