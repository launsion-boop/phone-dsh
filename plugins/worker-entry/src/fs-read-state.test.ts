// SPDX-License-Identifier: MIT
// G2-FIX-36 regression: after a park/resume rebuild the Worker must restore the
// fs observation policy's read-before-write state from the durable session log.
//
// Before the fix, a session resumed from its JSONL log started with the
// policy's in-memory WeakMap empty: the first `write`/`edit` of a file read in
// an earlier turn decided `createIfAbsent`, so the provider refused it with
// `file has not been read — read the file, then retry` and the model had to
// re-read everything. The tests mount the pinned
// `@deepseek-ai/dsh-fs-observation-policy` through the worker-entry shim: the
// session object is new (the rebuild), its durable `snapshotEvents()` still
// contains the earlier `read` tool call and result, and no live observation
// exists in this Worker.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { Context } from '@deepseek-ai/cordis'
import * as pinnedPolicy from '@deepseek-ai/dsh-fs-observation-policy'
import { FsTargetKey, FsVersion } from '@deepseek-ai/dsh-fs'
import {
  APP_BOOT_SPECIFIER, createAppBootShim, installDurableReadState,
  loadPinnedModule, observedPathsFromSessionEvents, READ_STATE_PLUGIN_NAME, selectPackageEntry,
} from './fs-read-state.ts'
import { composePhoneStaticModules } from './static-modules.ts'

interface Target {
  readonly targetKey: ReturnType<typeof FsTargetKey>
  readonly displayPath: string
}

type WriteIntent = { kind: 'createIfAbsent' } | { kind: 'replaceIfVersion'; version: string }

/** In-memory provider with the same version token shape the policy records. */
function createFileSystem(files: Map<string, string>): {
  resolve(path: string): Promise<Target>
  stat(target: Target): Promise<{ version: string; type: 'file'; size: number } | undefined>
} {
  return {
    async resolve(path: string): Promise<Target> {
      return { targetKey: FsTargetKey(path), displayPath: path }
    },
    async stat(target: Target) {
      const text = files.get(target.targetKey)
      if (text === undefined) return undefined
      return { version: `v:${text.length}:${text}`, type: 'file', size: text.length }
    },
  }
}

function target(path: string): Target {
  return { targetKey: FsTargetKey(path), displayPath: path }
}

/** One persisted successful tool call plus its result, as Session stores them. */
function callAndResult(
  name: string,
  path: string,
  options: { callId?: string; isError?: boolean; metaPath?: string } = {},
): unknown[] {
  const callId = options.callId ?? `call-${name}`
  return [{
    type: 'tool/call',
    seq: 0,
    time: 1,
    data: { turn: 1, step: 1, callId, name, arguments: JSON.stringify({ file_path: path }) },
  }, {
    type: 'tool/result',
    seq: 1,
    time: 2,
    data: {
      turn: 1,
      step: 1,
      message: { role: 'tool', toolCallId: callId, ...options.isError === true ? { isError: true } : {} },
      ...options.isError === true ? {} : { meta: { path: options.metaPath ?? path, offset: 1, lines: [], totalLines: 1 } },
    },
  }]
}

function sessionWith(...groups: readonly (readonly unknown[])[]): { snapshotEvents(): readonly unknown[] } {
  return { snapshotEvents: () => groups.flat() }
}

const actorFor = (session: object): { agent: { session: object } } => ({ agent: { session } })

async function mount(
  files: Map<string, string>,
  session: { snapshotEvents(): readonly unknown[] },
): Promise<Context> {
  // Production order: the read-state plugin mounts before the profile tree,
  // so its prepended intent listeners are registered before the real policy's.
  const ctx = new Context()
  ctx.provide('fs', createFileSystem(files) as never)
  await ctx.plugin({ name: READ_STATE_PLUGIN_NAME, apply: (c: Context) => { installDurableReadState(c) } })
  await ctx.plugin(pinnedPolicy as never, undefined as never)
  return ctx
}

function writeIntent(ctx: Context, path: string, session: object): Promise<WriteIntent | undefined> {
  return ctx.waterfall('fs/write-intent', target(path), actorFor(session), () => undefined) as Promise<WriteIntent | undefined>
}

function editIntent(ctx: Context, path: string, session: object): Promise<{ version: string } | undefined> {
  return ctx.waterfall('fs/edit-intent', target(path), actorFor(session), () => undefined) as Promise<{ version: string } | undefined>
}

/**
 * The provider's guarded write, reduced to the contract that matters here:
 * `createIfAbsent` refuses an existing target with `FS_NOT_OBSERVED`; a
 * version-guarded replace refuses a changed target with `FS_STALE_VERSION`.
 */
function guardedWrite(files: Map<string, string>, path: string, intent: WriteIntent | undefined): void {
  if (intent === undefined) throw new Error('no write intent')
  if (intent.kind === 'createIfAbsent') {
    if (files.has(path)) throw new Error(`cannot modify "${path}": file has not been read — read the file, then retry`)
    files.set(path, 'created')
    return
  }
  const current = files.get(path)
  if (current === undefined) throw new Error(`cannot modify "${path}": the file changed since it was read — re-read the file, then retry`)
  if (`v:${current.length}:${current}` !== intent.version) {
    throw new Error(`cannot modify "${path}": the file changed since it was read — re-read the file, then retry`)
  }
  files.set(path, 'updated')
}

test('post-resume write to a file read in an earlier turn succeeds without a re-read', async () => {
  const path = '/dsh/workspace/billing.py'
  const files = new Map([[path, 'abc']])
  const session = sessionWith(callAndResult('read', path))
  const ctx = await mount(files, session)

  const intent = await writeIntent(ctx, path, session)
  assert.deepEqual(intent, { kind: 'replaceIfVersion', version: 'v:3:abc' })
  guardedWrite(files, path, intent)
  assert.equal(files.get(path), 'updated')
})

test('post-resume edit to a file read in an earlier turn is accepted', async () => {
  const path = '/dsh/workspace/main.py'
  const files = new Map([[path, 'print(1)\n']])
  const session = sessionWith(callAndResult('read', path))
  const ctx = await mount(files, session)

  assert.deepEqual(await editIntent(ctx, path, session), { version: 'v:9:print(1)\n' })
})

test('a target never read or written in the session is still refused after resume', async () => {
  const readPath = '/dsh/workspace/billing.py'
  const neverRead = '/dsh/workspace/secrets.env'
  const files = new Map([[readPath, 'abc'], [neverRead, 'token']])
  const session = sessionWith(callAndResult('read', readPath))
  const ctx = await mount(files, session)

  const intent = await writeIntent(ctx, neverRead, session)
  assert.deepEqual(intent, { kind: 'createIfAbsent' }, 'the restored state must not authorize an unread target')
  assert.throws(() => guardedWrite(files, neverRead, intent), /file has not been read — read the file, then retry/)
  await assert.rejects(
    editIntent(ctx, neverRead, session),
    (error: unknown) => (error as { code?: string }).code === 'FS_NOT_OBSERVED',
  )
})

test('the resume snapshot pins versions before later commands run', async () => {
  const path = '/dsh/workspace/billing.py'
  const files = new Map([[path, 'abc']])
  const session = sessionWith(callAndResult('read', path))
  const ctx = await mount(files, session)

  // Resume publishes the agent/session; restoring here captures the version
  // the model saw, before the new Worker executes any command.
  await ctx.serial('agent/created', { agent: { session }, source: 'resume' } as never)
  files.set(path, 'abcd')

  const intent = await writeIntent(ctx, path, session)
  assert.deepEqual(intent, { kind: 'replaceIfVersion', version: 'v:3:abc' })
  assert.throws(
    () => guardedWrite(files, path, intent),
    /the file changed since it was read — re-read the file, then retry/,
  )
})

test('restored observations are scoped to the session that read the file', async () => {
  const path = '/dsh/workspace/billing.py'
  const files = new Map([[path, 'abc']])
  const reader = sessionWith(callAndResult('read', path))
  const other = sessionWith()
  const ctx = await mount(files, reader)

  assert.deepEqual(await writeIntent(ctx, path, other), { kind: 'createIfAbsent' })
  assert.deepEqual(await writeIntent(ctx, path, reader), { kind: 'replaceIfVersion', version: 'v:3:abc' })
})

test('a live observation in the rebuilt Worker outranks the replayed log', async () => {
  const path = '/dsh/workspace/billing.py'
  const files = new Map([[path, 'abc']])
  const session = sessionWith(callAndResult('read', path))
  const ctx = await mount(files, session)

  // A read in this Worker records the exact live version; replay must not
  // overwrite it with the version derived from the durable log's old content.
  ctx.emit('fs/observed', target(path), { kind: 'present', version: FsVersion('v-live') }, actorFor(session))
  assert.deepEqual(await writeIntent(ctx, path, session), { kind: 'replaceIfVersion', version: 'v-live' })
})

test('the replay only trusts successful observing tools', () => {
  const read = '/dsh/workspace/read.txt'
  const written = '/dsh/workspace/written.txt'
  const searched = '/dsh/workspace/searched.txt'
  const failed = '/dsh/workspace/failed.txt'
  const globCall = {
    type: 'tool/call',
    seq: 4,
    time: 1,
    data: { turn: 1, step: 1, callId: 'glob-1', name: 'glob', arguments: '{"pattern":"*"}' },
  }
  const globResult = {
    type: 'tool/result',
    seq: 5,
    time: 2,
    data: { turn: 1, step: 1, message: { role: 'tool', toolCallId: 'glob-1' }, meta: { path: searched } },
  }
  assert.deepEqual(
    observedPathsFromSessionEvents([
      ...callAndResult('read', read, { callId: 'read-1' }),
      ...callAndResult('read', failed, { callId: 'read-2', isError: true }),
      ...callAndResult('write', written, { callId: 'write-1' }),
      globCall,
      globResult,
    ]),
    [read, written],
  )
})

test('the pinned package entry is selected from exports or main', () => {
  assert.equal(selectPackageEntry({ exports: { '.': { default: './lib/index.js' } } }), './lib/index.js')
  assert.equal(selectPackageEntry({ exports: './entry.js' }), './entry.js')
  assert.equal(selectPackageEntry({ main: 'lib/main.js' }), 'lib/main.js')
  assert.equal(selectPackageEntry(undefined), 'lib/index.js')
})

test('the loader is asked for the package directory, never for the overridden specifier', () => {
  const requests: Array<[string, string]> = []
  const loaded = loadPinnedModule({
    resolve(specifier: string, fromDirectory: string) {
      requests.push([specifier, fromDirectory])
      return { specifier, fromDirectory }
    },
    load(resolution: unknown) {
      const { specifier } = resolution as { specifier: string }
      return specifier === './package.json' ? { main: 'lib/index.js' } : { boot() {} }
    },
  }, '/dsh', APP_BOOT_SPECIFIER, 'boot')
  assert.equal(typeof loaded.boot, 'function')
  assert.deepEqual(requests[0], ['./package.json', `/dsh/node_modules/${APP_BOOT_SPECIFIER}`])
  assert.deepEqual(requests[1], ['./lib/index.js', `/dsh/node_modules/${APP_BOOT_SPECIFIER}`])
})

test('the app-boot shim mounts the replay before prepare and forwards the other exports', async () => {
  const path = '/dsh/workspace/billing.py'
  const files = new Map([[path, 'abc']])
  const ctx = new Context()
  ctx.provide('fs', createFileSystem(files) as never)
  let prepared = false
  const real = {
    marker: 'real-app-boot',
    async boot(
      _binName: string,
      _configPath: string,
      _patches: unknown[] | undefined,
      prepare?: (context: Context) => unknown,
    ): Promise<unknown> {
      await prepare?.(ctx)
      return 'booted'
    },
  }
  const shim = createAppBootShim(real as never) as unknown as typeof real
  assert.equal(shim.marker, 'real-app-boot')
  assert.equal(await shim.boot('dsh', '/cfg', [], async () => { prepared = true }), 'booted')
  assert.equal(prepared, true)

  // Production mounts the pinned policy row after app-boot; by then the replay
  // plugin's listeners exist, so a session whose durable log has the read
  // decides the guarded write.
  await ctx.plugin(pinnedPolicy as never, undefined as never)
  const session = sessionWith(callAndResult('read', path))
  assert.deepEqual(await writeIntent(ctx, path, session), { kind: 'replaceIfVersion', version: 'v:3:abc' })
})

test('the static-module table installs the app-boot override when the runtime binding supplies one', () => {
  const table = composePhoneStaticModules({}, {
    sharp: (() => ({})) as never,
    appBoot: () => 'wrapped-app-boot',
  })
  assert.equal(table[APP_BOOT_SPECIFIER]?.(), 'wrapped-app-boot')
  const without = composePhoneStaticModules({}, { sharp: (() => ({})) as never })
  assert.equal(without[APP_BOOT_SPECIFIER], undefined)
})
