// SPDX-License-Identifier: MIT
/**
 * Truth gate for the `write`/`edit` refusal diagnostics (P24).
 *
 * The device delivered two fixed decorations and nothing else:
 *
 *   Error: [sandbox: file access denied under workspace-write mode]
 *   [sandbox: escalation available — retry this exact operation once with ...]
 *
 * The pinned tool layer builds that text and the phone cannot un-build it, so
 * this module appends the missing facts. These tests pin the four refusal shapes
 * (image path, `/dsh/home`, read-only, tool-writable), the three diagnosed codes,
 * that the appended text reuses bash's one writable-roots sentence verbatim, that
 * the decorations survive untouched, and that nothing else in the tree (bash's
 * own denial, `read`'s own not-found, a success, another failure code, a
 * downstream block) is rewritten.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { WORKER_VFS_NAMESPACE } from '../../wasi-toolbox/src/vfs-namespace.ts'
import {
  DEFAULT_TOOL_WORKSPACE_ROOT,
  FS_DENIAL_CODE,
  FS_DENIAL_MARKER,
  FS_DENIAL_PLUGIN,
  FS_DENIAL_PLUGIN_NAME,
  FS_DENIAL_TOOLS,
  FS_DIAGNOSED_CODES,
  TOOL_TEMP_ROOTS,
  annotateFsDenial,
  fsDenialDiagnostic,
  installFsDenialDiagnostics,
  isWithinRoot,
  phoneWritableRootOf,
  toolFenceAccepts,
  type FsDenialFacts,
} from './fs-denial-diagnostics.ts'

/**
 * The exact sentence bash prints for the same refusal (P2/P21). Hard-coded here
 * on purpose: the fs diagnosis must reuse it, not paraphrase it, so a change to
 * the root table or to the wording has to update both surfaces or fail here.
 */
const BASH_ROOTS_LINE = 'pdsh-shell: writable roots are /dsh/workspace, /dsh/home, /tmp, /dsh/tmp, /dev/null (TMPDIR=/dsh/tmp)'

/** The four paths the P24 device probe asked `write` to create. */
const PROBED_PATHS = ['/dsh/config/x', '/dsh/bin/x', '/x', '/dsh/home/x'] as const

/** Build facts for one path exactly as the listener resolves them. */
function factsFor(
  path: string,
  code = FS_DENIAL_CODE,
  overrides: Partial<FsDenialFacts> = {},
): FsDenialFacts {
  return {
    code,
    toolName: 'write',
    path,
    mode: 'workspace-write',
    root: phoneWritableRootOf(path),
    toolWritable: toolFenceAccepts(path, DEFAULT_TOOL_WORKSPACE_ROOT),
    ...overrides,
  }
}

/** The harness marker the pinned `FsSandboxController.mapError` writes. */
function harnessText(mode = 'workspace-write'): string {
  return `Error: [sandbox: file access denied under ${mode} mode]\n`
    + '[sandbox: escalation available — retry this exact operation once with sandbox_permissions '
    + '(the narrowest wider mode that suffices) + justification; the approval prompt asks the user]'
}

/** A failed `write`/`edit` result exactly as the registry materializes it. */
function failedResult(code: string, path: string, mode = 'workspace-write'): Record<string, unknown> {
  if (code === FS_DENIAL_CODE) {
    return {
      isError: true,
      content: [{ type: 'text', text: harnessText(mode) }],
      error: {
        message: `[sandbox: file access denied under ${mode} mode]\n[sandbox: escalation available ...]`,
        info: { name: 'FsError', code },
      },
    }
  }
  const message = code === 'FS_NOT_OBSERVED'
    ? `cannot modify "${path}": file has not been read — read the file, then retry`
    : `cannot edit "${path}": not found`
  return {
    isError: true,
    content: [{ type: 'text', text: `Error: ${message}` }],
    error: { message, info: { name: 'FsError', code } },
  }
}

/** A host context double with an optional policy/filesystem service. */
function fakeContext(options: {
  sandboxPolicy?: unknown
  fs?: unknown
  registrations?: string[]
} = {}): {
  on(name: string, listener: unknown): void
  get(name: string): unknown
} {
  const registrations = options.registrations
  return {
    on(name: string): void { registrations?.push(name) },
    get(name: string): unknown {
      if (name === 'sandboxPolicy') return options.sandboxPolicy
      if (name === 'fs') return options.fs
      return undefined
    },
  }
}

test('the root table sentence the fs diagnosis prints is the one bash prints', () => {
  assert.equal(WORKER_VFS_NAMESPACE.writableRootsLine(), BASH_ROOTS_LINE)
})

test('phoneWritableRootOf names the containing root, and nothing outside the table', () => {
  assert.equal(phoneWritableRootOf('/dsh/workspace/a.txt'), '/dsh/workspace')
  assert.equal(phoneWritableRootOf('/dsh/home/AGENTS.md'), '/dsh/home')
  assert.equal(phoneWritableRootOf('/tmp/a.txt'), '/tmp')
  assert.equal(phoneWritableRootOf('/dsh/tmp/a.txt'), '/dsh/tmp')
  assert.equal(
    phoneWritableRootOf('/dsh/workspace/../workspace/a.txt'),
    '/dsh/workspace',
    'the root table canonicalises before matching (the legacy /home spelling folds there too)',
  )
  assert.equal(phoneWritableRootOf('/dev/null'), '/dev/null')
  assert.equal(phoneWritableRootOf('/dsh/config/x'), undefined)
  assert.equal(phoneWritableRootOf('/'), undefined)
})

test('the tool fence is the workspace root plus the temp roots, and it is not the root table', () => {
  assert.equal(isWithinRoot('/dsh/workspace/a', '/dsh/workspace'), true)
  assert.equal(isWithinRoot('/dsh/workspace', '/dsh/workspace'), true)
  assert.equal(isWithinRoot('/dsh/workspacex/a', '/dsh/workspace'), false, 'a sibling prefix is not containment')
  for (const root of TOOL_TEMP_ROOTS) assert.equal(toolFenceAccepts(`${root}/a`, '/dsh/workspace'), true)
  assert.equal(toolFenceAccepts('/dsh/workspace/a', '/dsh/workspace'), true)
  assert.equal(toolFenceAccepts('/dsh/home/a', '/dsh/workspace'), false, 'the documented gap')
  assert.equal(toolFenceAccepts('/x', '/dsh/workspace'), false)
  assert.equal(toolFenceAccepts('/dsh/workspace/a', '/custom/ws'), false, 'the workspace root is a parameter')
  assert.equal(toolFenceAccepts('/custom/ws/a', '/custom/ws'), true)
})

test('an image path is diagnosed as outside every root, with the roots and a way out', () => {
  for (const path of ['/dsh/config/x', '/dsh/bin/x', '/x']) {
    const text = fsDenialDiagnostic(factsFor(path), BASH_ROOTS_LINE)
    assert.ok(text.startsWith(`${FS_DENIAL_MARKER}cannot write "${path}"`), `names the path: ${text}`)
    assert.ok(text.includes(`"${path}"`))
    assert.ok(text.includes(BASH_ROOTS_LINE), 'the bash sentence appears verbatim, not as a third wording')
    assert.ok(text.includes('the image is read-only in every mode'), 'the reason is stated')
    assert.ok(text.includes('next: retry with a path under one of those roots'), 'the next step is actionable')
    assert.ok(text.includes('/dsh/workspace'), 'the next step names a root that actually works')
    assert.ok(text.includes('escalation is always refused'), 'the unfulfillable escalation hint is rebutted')
    assert.ok(text.includes('say so instead of retrying'), 'the model is told what to do when the path is required')
  }
})

test('/dsh/home is inside the root table but outside the tool fence, and the diagnosis says so', () => {
  const text = fsDenialDiagnostic(factsFor('/dsh/home/x', FS_DENIAL_CODE, { toolName: 'edit' }), BASH_ROOTS_LINE)
  assert.ok(text.startsWith(`${FS_DENIAL_MARKER}cannot change "/dsh/home/x"`), 'the verb follows the tool')
  assert.ok(text.includes('"/dsh/home" is writable from `bash`, not from `write`/`edit`'))
  assert.ok(text.includes(BASH_ROOTS_LINE))
  assert.ok(text.includes('next: change it with `bash`'))
  assert.doesNotMatch(text, /outside the phone's writable roots/u, 'the /dsh/home answer must not contradict the root list')
})

test('a read-only session is diagnosed as read-only, not as an image path', () => {
  const text = fsDenialDiagnostic(factsFor('/dsh/workspace/x', FS_DENIAL_CODE, { mode: 'read-only' }), BASH_ROOTS_LINE)
  assert.ok(text.includes('this session is in read-only mode'))
  assert.ok(text.includes(BASH_ROOTS_LINE))
  assert.ok(text.includes('report the intended content to the user instead'))
  assert.doesNotMatch(text, /is writable from `bash`/u, 'bash cannot write in read-only either')
})

test('the diagnosis is appended beside the decorations and leaves them intact', async () => {
  for (const path of PROBED_PATHS) {
    const result = failedResult(FS_DENIAL_CODE, path)
    const decision = await annotateFsDenial(
      fakeContext(),
      { name: 'write', arguments: { file_path: path, content: 'x' } },
      result,
      { kind: 'accept' },
      BASH_ROOTS_LINE,
    )
    const content = decision.content as { type: string; text: string }[]
    assert.equal(decision.kind, 'accept')
    assert.equal(content.length, 2, 'one appended block, nothing replaced')
    assert.equal(content[0]?.text, harnessText(), 'the harness decorations are untouched')
    assert.ok(content[1]?.text.startsWith(FS_DENIAL_MARKER))
    assert.ok(content[1]?.text.includes(`"${path}"`))
    assert.ok(content[1]?.text.includes(BASH_ROOTS_LINE))
    assert.ok(content[1]?.text.includes('next:'))
  }
})

test('not-found and not-observed get the same three answers without the escalation rebuttal', () => {
  for (const code of ['FS_NOT_FOUND', 'FS_NOT_OBSERVED']) {
    for (const path of ['/dsh/config/x', '/dsh/bin/x', '/x', '/dsh/home/x']) {
      const text = fsDenialDiagnostic(factsFor(path, code), BASH_ROOTS_LINE)
      assert.ok(text.startsWith(`${FS_DENIAL_MARKER}cannot write "${path}"`), `${code} ${path}: ${text}`)
      assert.ok(text.includes(BASH_ROOTS_LINE), `${code} ${path} names the writable roots`)
      assert.ok(text.includes('next:'), `${code} ${path} has a next step`)
      assert.doesNotMatch(
        text,
        /sandbox_permissions|escalat/iu,
        `${code} ${path}: neither code ever showed the escalation hint, so warning about it would be noise`,
      )
    }
  }
  // The advice differs by code where it must: absence is not a policy refusal.
  const absent = fsDenialDiagnostic(factsFor('/dsh/config/x', 'FS_NOT_FOUND'), BASH_ROOTS_LINE)
  const unobserved = fsDenialDiagnostic(factsFor('/dsh/config/x', 'FS_NOT_OBSERVED'), BASH_ROOTS_LINE)
  assert.ok(absent.includes('nothing can create that path'), 'not-found on an image path is final')
  assert.ok(unobserved.includes('reading it first does not help'), 'the provider advice is corrected, not repeated')
})

test('a tool-writable path gets the code-specific next step, not a fence warning', () => {
  const absent = fsDenialDiagnostic(factsFor('/dsh/workspace/x', 'FS_NOT_FOUND'), BASH_ROOTS_LINE)
  assert.ok(absent.includes('"/dsh/workspace/x" is writable but does not exist yet'))
  assert.ok(absent.includes('`edit` only changes an existing file, while `write` creates one'))
  assert.ok(absent.includes('next: use `write` with the full content'))
  assert.ok(absent.includes(BASH_ROOTS_LINE))

  const unobserved = fsDenialDiagnostic(factsFor('/dsh/workspace/x', 'FS_NOT_OBSERVED'), BASH_ROOTS_LINE)
  assert.ok(unobserved.includes('was not read in this session'))
  assert.ok(unobserved.includes('next: read "/dsh/workspace/x" once, then repeat the same `edit`'))
  assert.doesNotMatch(unobserved, /outside the phone's writable roots/u, 'a writable path is not a fence refusal')
})

test('a read-only session with a not-found target is still diagnosed as read-only', async () => {
  const decision = await annotateFsDenial(
    fakeContext({ sandboxPolicy: { resolve: () => ({ mode: 'read-only', workspaceRoot: '/dsh/workspace' }) } }),
    { name: 'write', arguments: { file_path: '/dsh/workspace/x' } },
    // The provider text for this code has no marker, so the policy is the only mode source.
    failedResult('FS_NOT_FOUND', '/dsh/workspace/x'),
    { kind: 'accept' },
    BASH_ROOTS_LINE,
  )
  const text = (decision.content as { text: string }[])[1]?.text ?? ''
  assert.ok(text.includes('this session is in read-only mode'))
  assert.ok(text.includes('and the file does not exist yet'))
  assert.ok(text.includes('report the intended content to the user'))
})

test('the workspace root comes from the session policy, so a composed workspace is not assumed', async () => {
  const decision = await annotateFsDenial(
    fakeContext({ sandboxPolicy: { resolve: () => ({ mode: 'workspace-write', workspaceRoot: '/custom/ws' }) } }),
    { name: 'write', arguments: { file_path: '/custom/ws/x' } },
    failedResult('FS_NOT_OBSERVED', '/custom/ws/x'),
    { kind: 'accept' },
    BASH_ROOTS_LINE,
  )
  const text = (decision.content as { text: string }[])[1]?.text ?? ''
  assert.ok(text.includes('"/custom/ws/x" is writable but was not read in this session'))
  assert.doesNotMatch(text, /outside the phone's writable roots|writable from `bash`/u)
})

test('a second pass does not append the diagnosis twice', async () => {
  const result = failedResult(FS_DENIAL_CODE, '/dsh/config/x')
  const once = await annotateFsDenial(
    fakeContext(), { name: 'write', arguments: { file_path: '/dsh/config/x' } }, result, { kind: 'accept' }, BASH_ROOTS_LINE,
  )
  const twice = await annotateFsDenial(
    fakeContext(),
    { name: 'write', arguments: { file_path: '/dsh/config/x' } },
    { ...result, content: once.content },
    { kind: 'accept' },
    BASH_ROOTS_LINE,
  )
  // An already-annotated result is handed back unchanged: the decision carries
  // no replacement content, so the registry keeps the result's own (annotated)
  // content instead of appending a second copy.
  assert.equal((twice as { content?: unknown }).content, undefined)
  assert.deepEqual(twice, { kind: 'accept' })
})

test('bash, read, success, another failure code and a downstream block are left alone', async () => {
  const bash = await annotateFsDenial(
    fakeContext(),
    { name: 'bash', arguments: { command: 'echo hi > /x', description: 'probe' } },
    failedResult(FS_DENIAL_CODE, '/x'),
    { kind: 'accept' },
    BASH_ROOTS_LINE,
  )
  assert.deepEqual(bash, { kind: 'accept' }, 'the bash regression: its own EACCES answer is not rewritten')

  const read = await annotateFsDenial(
    fakeContext(),
    { name: 'read', arguments: { file_path: '/dsh/config/x' } },
    failedResult('FS_NOT_FOUND', '/dsh/config/x'),
    { kind: 'accept' },
    BASH_ROOTS_LINE,
  )
  assert.deepEqual(read, { kind: 'accept' }, 'read keeps its own not-found answer')

  const success = await annotateFsDenial(
    fakeContext(),
    { name: 'write', arguments: { file_path: '/dsh/workspace/x' } },
    { isError: false, content: [{ type: 'text', text: '<path>/dsh/workspace/x</path>' }] },
    { kind: 'accept' },
    BASH_ROOTS_LINE,
  )
  assert.deepEqual(success, { kind: 'accept' })

  const otherCode = await annotateFsDenial(
    fakeContext(),
    { name: 'write', arguments: { file_path: '/dsh/config/x' } },
    failedResult('FS_PERMISSION_DENIED', '/dsh/config/x'),
    { kind: 'accept' },
    BASH_ROOTS_LINE,
  )
  assert.deepEqual(otherCode, { kind: 'accept' }, 'a code the provider already explained is not doubled')

  const blocked = await annotateFsDenial(
    fakeContext(),
    { name: 'write', arguments: { file_path: '/dsh/config/x' } },
    failedResult(FS_DENIAL_CODE, '/dsh/config/x'),
    { kind: 'block', feedback: [{ type: 'text', text: 'blocked by policy' }] },
    BASH_ROOTS_LINE,
  )
  assert.deepEqual(blocked, { kind: 'block', feedback: [{ type: 'text', text: 'blocked by policy' }] })
})

test('the registered listener annotates the real waterfall arguments and survives a broken fs', async () => {
  let listener: ((...args: any[]) => Promise<unknown>) | undefined
  const ctx = {
    on(name: string, registered: (...args: any[]) => Promise<unknown>): void {
      assert.equal(name, 'tools/post-execute')
      listener = registered
    },
    // A filesystem service that throws on resolve: the fallback must still answer.
    get(name: string): unknown {
      return name === 'fs'
        ? { resolve(): Promise<unknown> { throw new Error('resolve exploded') } }
        : undefined
    },
  }
  installFsDenialDiagnostics(ctx)
  assert.ok(listener !== undefined)
  const decision = await listener(
    { name: 'edit', arguments: { file_path: '/dsh/bin/x', old_string: 'a', new_string: 'b' } },
    failedResult(FS_DENIAL_CODE, '/dsh/bin/x'),
    async () => ({ kind: 'accept' }),
  ) as { content: { text: string }[] }
  assert.equal(decision.content.length, 2)
  assert.ok(decision.content[1]?.text.includes('"/dsh/bin/x"'))
  assert.ok(decision.content[1]?.text.includes(BASH_ROOTS_LINE))
})

test('the plugin is named, claims the two tools and the three codes', () => {
  assert.equal(FS_DENIAL_PLUGIN.name, FS_DENIAL_PLUGIN_NAME)
  assert.deepEqual([...FS_DENIAL_TOOLS].sort(), ['edit', 'write'])
  assert.deepEqual([...FS_DIAGNOSED_CODES].sort(), ['FS_NOT_FOUND', 'FS_NOT_OBSERVED', 'FS_SANDBOX_DENIED'])
  const registrations: string[] = []
  FS_DENIAL_PLUGIN.apply(fakeContext({ registrations }) as never)
  assert.deepEqual(registrations, ['tools/post-execute'])
})
