// SPDX-License-Identifier: MIT
// The Worker half of the execution read policy: an accelerator request that
// names DSH-internal state must be refused before it becomes an EXEC_REQ, with
// the same sentence the host and the shell render.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { EXEC_INTERNAL_ROOTS, execReadDeniedMessage } from '@phone-dsh/dsh-wasi-toolbox'
import { execReadDenialForRequest, execReadRefusalLine, refusedExecStream } from './exec-read-guard.ts'

/** The exact denial text for one path, built from the one authority. */
function expected(path: string, root: string): string {
  return `EACCES: ${execReadDeniedMessage(path, root)}`
}

/** One EXEC_REQ-shaped request. */
function request(argv: string[], cwd = '/dsh/workspace'): { argv: string[]; cwd: string } {
  return { argv, cwd }
}

test('policy: rg is refused for every internal root, as typed and as a descendant', () => {
  for (const root of EXEC_INTERNAL_ROOTS) {
    for (const operand of [root, `${root}/project/session.v4.jsonl`]) {
      const refusal = execReadDenialForRequest(request(['rg', '-n', 'session_', operand]))
      assert.notEqual(refusal, undefined, `${operand} must be refused`)
      assert.equal(refusal?.root, root)
      assert.equal(refusal?.path, operand)
      assert.equal(refusal?.operand, operand)
      assert.equal(refusal?.denial, expected(operand, root))
      assert.equal(refusal?.exitCode, 2)
      assert.equal(execReadRefusalLine(refusal!), `rg: ${operand}: ${expected(operand, root)}\n`)
    }
  }
})

test('policy: rg --files is refused for every internal root', () => {
  for (const root of EXEC_INTERNAL_ROOTS) {
    const refusal = execReadDenialForRequest(request(['rg', '--files', root]))
    assert.equal(refusal?.denial, expected(root, root))
  }
})

test('policy: a path named through a flag is refused too', () => {
  const viaLong = execReadDenialForRequest(request(['rg', '--files-from=/dsh/home/sessions/list.txt', 'x']))
  assert.equal(viaLong?.path, '/dsh/home/sessions/list.txt')
  const viaShort = execReadDenialForRequest(request(['rg', '-f/dsh/home/tool-journal/p.txt', 'x']))
  assert.equal(viaShort?.path, '/dsh/home/tool-journal/p.txt')
})

test('policy: jaq is refused and answers its runtime exit code', () => {
  for (const root of EXEC_INTERNAL_ROOTS) {
    const refusal = execReadDenialForRequest(request(['jaq', '-r', '.type', `${root}/x.json`]))
    assert.equal(refusal?.denial, expected(`${root}/x.json`, root))
    assert.equal(refusal?.exitCode, 5)
  }
})

test('policy: a relative operand resolves against the request cwd', () => {
  const refusal = execReadDenialForRequest(request(['rg', '-n', 'x', 'sessions'], '/dsh/home'))
  assert.equal(refusal?.path, '/dsh/home/sessions')
  const dotted = execReadDenialForRequest(request(['rg', '-n', 'x', '/dsh/home/notes/../storages']))
  assert.equal(dotted?.root, '/dsh/home/storages')
})

test('policy: a cwd inside internal state is refused even with no path operand', () => {
  for (const root of EXEC_INTERNAL_ROOTS) {
    const refusal = execReadDenialForRequest(request(['rg', 'pattern'], root))
    assert.equal(refusal?.root, root)
    assert.equal(refusal?.path, root)
    assert.equal(refusal?.operand, root)
  }
})

test('policy: patterns, readable home files and the workspace stay allowed', () => {
  for (const argv of [
    ['rg', 'session_'],
    ['rg', '-n', 'capabilities', '/dsh/home/capabilities.json'],
    ['rg', '--files', '/dsh/home'],
    ['rg', '-n', 'capabilities', '/dsh/home'],
    ['rg', '-e', 'needle', '/dsh/workspace/a.txt'],
    ['rg', '-n', 'x', '/dsh/workspace/sessions/a.jsonl'],
    ['jaq', '.capabilities', '/dsh/home/capabilities.json'],
    ['jaq', '.a', '/dsh/workspace/in.json'],
    // A pattern that happens to be an internal spelling is not a path: with no
    // path operand rg searches the cwd, which is not internal state.
    ['rg', '/dsh/home/sessions'],
  ]) {
    assert.equal(execReadDenialForRequest(request(argv)), undefined, argv.join(' '))
  }
})

test('policy: programs without path operands only get the cwd check', () => {
  const json = '{"type":"phone","tool":"info"}'
  assert.equal(execReadDenialForRequest(request(['phone', json])), undefined)
  assert.equal(execReadDenialForRequest(request(['phone', json], '/dsh/home/sessions'))?.root, '/dsh/home/sessions')
})

test('the synthetic stream carries one stderr chunk and the program exit code', async () => {
  const refusal = execReadDenialForRequest(request(['rg', '-n', 'x', '/dsh/home/storages']))
  assert.notEqual(refusal, undefined)
  const events = []
  for await (const event of refusedExecStream('xl-1', refusal!)) events.push(event)
  assert.deepEqual(events.map(event => event.type), ['start', 'output', 'exit'])
  const output = events[1] as { stream: string; data: string }
  assert.equal(output.stream, 'stderr')
  assert.equal(Buffer.from(output.data, 'base64').toString('utf8'), execReadRefusalLine(refusal!))
  const exit = events[2] as { code: number; status: string; quiescent: boolean }
  assert.equal(exit.code, 2)
  assert.equal(exit.status, 'exited')
  assert.equal(exit.quiescent, true)
})
