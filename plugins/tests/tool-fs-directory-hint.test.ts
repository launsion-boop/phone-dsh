// SPDX-License-Identifier: MIT
/**
 * R2 (2026-11-13): DSH's `read` says only "not a regular file" for a
 * directory. The phone appends the next tool to that exact failed result via
 * the supported post-execute waterfall; these tests keep the append narrow and
 * preserve the error identity for every other read outcome.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import type { PostToolDecision, ToolExecution, ToolExecutionResult } from '@deepseek-ai/dsh-tools'
import { HINT, apply, isDirectoryReadError, withHint } from '../tool-fs-directory-hint/src/index.ts'

type Listener = (
  exec: ToolExecution,
  result: Readonly<ToolExecutionResult>,
  next: () => Promise<PostToolDecision>,
) => Promise<PostToolDecision>

function listener(): Listener {
  let registered: Listener | undefined
  const ctx = { on(event: string, fn: Listener) { if (event === 'tools/post-execute') registered = fn } }
  apply(ctx as never)
  assert.ok(registered, 'the post-execute listener registered')
  return registered
}

function failure(text: string): ToolExecutionResult {
  return {
    isError: true,
    error: {
      message: text,
      info: { name: 'FS_NOT_REGULAR_FILE', code: 'FS_NOT_REGULAR_FILE' },
    },
    content: [{ type: 'text', text }],
  }
}

function readExec(): ToolExecution {
  return { name: 'read' } as ToolExecution
}

test('a directory read error gains one hint block', async () => {
  const result = failure('cannot read "/dsh/workspace": not a regular file')
  const decision = await listener()(readExec(), result, async () => ({ kind: 'accept' }))
  assert.equal(decision.kind, 'accept')
  if (decision.kind !== 'accept') return
  assert.deepEqual(decision.content?.at(-1), { type: 'text', text: HINT })
  assert.match(decision.content?.[0]?.type === 'text' ? decision.content[0].text : '', /not a regular file/u)
  // The structured error identity is untouched.
  assert.equal(result.isError ? result.error.info?.code : undefined, 'FS_NOT_REGULAR_FILE')
})

test('another tool or a non-error result is unchanged', async () => {
  const list = listener()
  const otherTool = await list({ name: 'bash' } as ToolExecution,
                              failure('cannot read "/x": not a regular file'),
                              async () => ({ kind: 'accept' }))
  assert.equal(otherTool.kind === 'accept' ? otherTool.content : undefined, undefined)
  const success = await list(readExec(), { isError: false, value: null, content: [] },
                             async () => ({ kind: 'accept' }))
  assert.equal(success.kind === 'accept' ? success.content : undefined, undefined)
})

test('a result that already has the hint is not duplicated', async () => {
  const result = failure(`cannot read "/x": not a regular file\n${HINT}`)
  assert.equal(isDirectoryReadError(result), false)
  const decision = await listener()(readExec(), result, async () => ({ kind: 'accept' }))
  assert.equal(decision.kind === 'accept' ? decision.content : undefined, undefined)
})

test('withHint only appends; it does not rewrite the original block', () => {
  const original = failure('cannot read "/x": not a regular file').content
  const next = withHint(original)
  assert.equal(next.length, original.length + 1)
  assert.deepEqual(next[0], original[0])
  assert.deepEqual(next.at(-1), { type: 'text', text: HINT })
})
