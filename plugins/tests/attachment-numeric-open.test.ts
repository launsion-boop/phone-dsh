// SPDX-License-Identifier: MIT
/**
 * Numeric `open(2)` flags on the real attachment persistence path.
 *
 * The pinned webworker runtime implements only Node's string open flags and
 * its virtual `fs.constants` omits `O_EXCL`. DSH's attachment-local store
 * stages every immutable object with
 * `open(tmp, O_CREAT | O_EXCL | O_WRONLY, 0o600)`, so the missing capability
 * turns a valid PNG/JPEG into `ATTACHMENT_WRITE_FAILED` before any object is
 * published.
 *
 * The child harness bundled here drives the pinned runtime's own `MemoryVfs`,
 * the runtime's `node:fs`/`node:fs/promises` bridges, and the real
 * `@deepseek-ai/dsh-attachment-local` `store.ts` from the checkout. It saves
 * and digest-verifies the known PNG/JPEG vectors, repeats the save for dedup,
 * exercises the numeric mask through the promise and sync faces, cancels a
 * streamed publication, and withholds the ordered-channel level-1 ack to prove
 * `handle.sync()`/the store cannot report success. Only the pixel decoder is a
 * Linux stand-in; the filesystem, store, metadata reader and sink are real.
 *
 * WebKit/Apple execution is NOT_RUN here (Linux has no WKWebView).
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { after, test } from 'node:test'

import { build } from 'esbuild'

import { GOLDEN_JPEG_3X2, GOLDEN_PNG_1X1 } from './fixtures/golden-images.ts'
import { createMemoryChannelPair } from '../channel/src/index.ts'
import { startPhoneWorker, type PhoneWorkerRuntime, type WorkerEntrySynthesize } from '../worker-entry/src/entry.ts'
import { seedNamespaceRoots } from '../worker-entry/src/namespace-boot.ts'
import { createNamespaceVfs, WORKER_VFS_NAMESPACE } from '../wasi-toolbox/src/index.ts'
import { TreeVfs } from './tree-vfs.ts'

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')
const checkout = process.env.PDSH_DSH_CHECKOUT
const skip = checkout === undefined || checkout === ''
  ? 'PDSH_DSH_CHECKOUT is unset; the runtime, VFS and DSH store come from the pinned checkout'
  : false

const RUNTIME_PREFIX = '@deepseek-ai/dsh-experimental-webworker-runtime/src/'

const scratch: string[] = []
after(() => {
  for (const directory of scratch) rmSync(directory, { recursive: true, force: true })
})

interface OpenResult {
  name: string
  code?: string
  message: string
  cause?: { name: string; code?: string; message: string }
}

interface NumericResult {
  constants: { O_EXCL?: number; target: number }
  save: {
    png: { ref?: Record<string, unknown>; error?: OpenResult }
    jpeg: { ref?: Record<string, unknown>; error?: OpenResult }
  }
  objects: {
    png: { path: string; mode: number; bytes: string }
    jpeg: { path: string; mode: number; bytes: string }
    staging: string[]
  }
  readBack: Record<'png' | 'jpeg', {
    ref?: Record<string, unknown>
    bytesMatch?: boolean
    sha256?: string
    error?: OpenResult
  }>
  dedup: {
    ref?: Record<string, unknown>
    error?: OpenResult
    prefixesBefore: string[]
    prefixesAfter: string[]
    staging: string[]
  }
  wx: { collision: OpenResult; bytes: string; mode: number }
  append: { bytes: string; expected: string }
  createNoTrunc: { bytes: string; length: number }
  truncate: { bytes: string }
  readOnly: { bytes: string }
  syncFace: { bytes: string }
  syncCollision: OpenResult
  unsupported: Record<string, OpenResult>
  cancel: OpenResult & { stagingBefore?: string[]; stagingAfter?: string[] }
  prepared: { sha256: string; bytesMatch: boolean; ref: Record<string, unknown> }
  flushGuard: {
    targetFlags: number
    storeOpenFlags: number[]
    storeStagingOpens: { path: string; flags: number }[]
    storeSyncPaths: string[]
    storeWithheld: string[]
    directOpenFlags: number[]
    directSyncPaths: string[]
    directWithheld: string[]
    syncError: OpenResult
    storeError: OpenResult
  }
}

function digest(bytes: Uint8Array): string {
  return createHash('sha256').update(bytes).digest('hex')
}

function hex(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString('hex')
}

/**
 * Bundle the harness against the pinned checkout's runtime sources and real
 * attachment-local store. `node:fs` is redirected to the runtime's VFS bridge,
 * never the host process's filesystem.
 */
async function bundleHarness(options: { outfile: string; checkout: string }): Promise<void> {
  const runtimeSrc = join(options.checkout, 'packages/experimental/webworker-runtime/src')
  const runtimeFs = join(runtimeSrc, 'node/builtin_modules/implemented/fs.ts')
  const runtimeFsPromises = join(runtimeSrc, 'node/builtin_modules/implemented/fs/promises.ts')
  const attachmentStore = join(options.checkout, 'packages/attachment/attachment-local/src/store.ts')
  const sharpShim = join(root, 'worker-entry', 'src', 'sharp-shim.ts')
  const runtimeBinding = join(root, 'worker-entry', 'src', 'runtime-binding.ts')
  const virtualFs = 'pdsh-runtime-fs'
  const virtualFsPromises = 'pdsh-runtime-fs-promises'
  const virtualLazyRequire = 'pdsh-lazy-require'
  const virtualRuntimeBinding = 'pdsh-runtime-binding'
  const virtualReadableStream = 'pdsh-readable-stream'
  await build({
    entryPoints: [join(root, 'tests', 'fixtures', 'attachment-numeric-harness.ts')],
    outfile: options.outfile,
    bundle: true,
    format: 'esm',
    platform: 'node',
    target: 'node22',
    external: ['node:*'],
    banner: {
      js: "import { createRequire as __pdshCreateRequire } from 'node:module'; const require = __pdshCreateRequire(import.meta.url);",
    },
    absWorkingDir: root,
    nodePaths: [join(root, 'node_modules')],
    logLevel: 'silent',
    plugins: [{
      name: 'pdsh-real-runtime-and-store',
      setup(builder) {
        builder.onResolve({ filter: /^@deepseek-ai\/dsh-experimental-webworker-runtime\/src\// }, args => ({
          path: join(runtimeSrc, args.path.slice(RUNTIME_PREFIX.length)),
        }))
        builder.onResolve({ filter: /^@deepseek-ai\/dsh-attachment-local(\/store)?$/ }, () => ({
          path: attachmentStore,
        }))
        // The checkout's stream bridge expects readable-stream 4.x, but the
        // phone workspace lock carries 3.x for other packages. Node's own
        // stream module is the same maintained implementation on this host;
        // this substitution is test scaffolding only (the packed image gets
        // the runtime's declared dependency from the checkout).
        builder.onResolve({ filter: /^readable-stream$/ }, () => ({
          path: virtualReadableStream,
          namespace: 'pdsh-virtual',
        }))
        builder.onResolve({ filter: /^@deepseek-ai\/dsh-lazy-require$/ }, () => ({
          path: virtualLazyRequire,
          namespace: 'pdsh-virtual',
        }))
        // `entry.ts` dynamically imports the full worker binding; the harness
        // only needs its pure sink/vfs helpers, so keep the runtime's browser
        // graph out of this Node bundle.
        builder.onResolve({ filter: /runtime-binding\.ts$/ }, args => (
          args.path === runtimeBinding || args.path === './runtime-binding.ts'
            ? { path: virtualRuntimeBinding, namespace: 'pdsh-virtual' }
            : undefined
        ))
        builder.onResolve({ filter: /^node:fs$/ }, () => ({ path: virtualFs, namespace: 'pdsh-virtual' }))
        builder.onResolve({ filter: /^node:fs\/promises$/ }, () => ({ path: virtualFsPromises, namespace: 'pdsh-virtual' }))
        builder.onLoad({ filter: /.*/, namespace: 'pdsh-virtual' }, args => {
          if (args.path === virtualFs) {
            return {
              loader: 'ts',
              resolveDir: dirname(runtimeFs),
              contents: 'export * from \'./fs.ts\'\nexport { default } from \'./fs.ts\'\n',
            }
          }
          if (args.path === virtualFsPromises) {
            return {
              loader: 'ts',
              resolveDir: dirname(runtimeFsPromises),
              contents: 'export * from \'./promises.ts\'\nexport { default } from \'./promises.ts\'\n',
            }
          }
          if (args.path === virtualRuntimeBinding) return { loader: 'ts', contents: 'export {}\n' }
          if (args.path === virtualReadableStream) {
            return { loader: 'ts', contents: 'export * from \'node:stream\'\nexport { default } from \'node:stream\'\n' }
          }
          if (args.path === virtualLazyRequire) {
            return {
              loader: 'ts',
              resolveDir: root,
              contents: `import { createSharpModule } from ${JSON.stringify(`./${sharpShim.slice(root.length + 1)}`)}
export function createLazyRequire(): () => unknown {
  const sharp = createSharpModule()
  return () => sharp
}
`,
            }
          }
          return undefined
        })
      },
    }],
  })
}

test('numeric O_EXCL persists real attachments through the pinned store (Linux decoder stand-in)', { skip }, async () => {
  assert.notEqual(checkout, undefined)
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-attachment-numeric-'))
  scratch.push(directory)
  const harness = join(directory, 'harness.mjs')
  await bundleHarness({ outfile: harness, checkout: checkout as string })
  const harnessText = readFileSync(harness, 'utf8')
  // The bundle must carry the phone adapter and the real store, and must not
  // pull a host `node:fs` implementation into the attachment path.
  assert.match(harnessText, /O_EXCL requires O_CREAT/, 'the numeric adapter is bundled')
  assert.match(harnessText, /ensureDurableDirectory|publishImmutableObjectStream/, 'the real DSH store is bundled')
  assert.match(harnessText, /pdsh-sharp-shim\/1/, 'the phone sharp shim is bundled for the Linux decoder stand-in')

  const child = spawnSync(
    process.execPath,
    [harness],
    { encoding: 'utf8', timeout: 180_000, env: { ...process.env, PDSH_DSH_CHECKOUT: checkout } },
  )
  const output = `${child.stdout ?? ''}${child.stderr ?? ''}`
  assert.equal(child.status, 0, `harness exited ${String(child.status)}:\n${output}`)
  const line = (child.stdout ?? '').split('\n').find(entry => entry.startsWith('__PDSH_ATTACHMENT_NUMERIC_RESULT__ '))
  assert.notEqual(line, undefined, `harness printed no result line:\n${output}`)
  const result = JSON.parse((line as string).slice('__PDSH_ATTACHMENT_NUMERIC_RESULT__ '.length)) as NumericResult

  const png = new Uint8Array(Buffer.from(GOLDEN_PNG_1X1, 'base64'))
  const jpeg = new Uint8Array(Buffer.from(GOLDEN_JPEG_3X2, 'base64'))
  const pngSha = digest(png)
  const jpegSha = digest(jpeg)

  // ---- virtual constants: the missing capability is real, not the Mac table.
  assert.equal(result.constants.O_EXCL, 128, 'O_EXCL is added to the runtime virtual constants')
  assert.equal(result.constants.target, 64 | 128 | 1, 'the store mask is a real O_CREAT|O_EXCL|O_WRONLY mask')

  // ---- save PNG/JPEG through DSH's store, not a mock.
  assert.equal(result.save.png.error, undefined, `PNG save failed: ${JSON.stringify(result.save.png.error)}`)
  assert.equal(result.save.jpeg.error, undefined, `JPEG save failed: ${JSON.stringify(result.save.jpeg.error)}`)
  assert.deepEqual(result.save.png.ref, {
    attachmentId: `sha256:${pngSha}`,
    mediaType: 'image/png',
    width: 1,
    height: 1,
    bytes: png.byteLength,
    name: 'one.png',
  })
  assert.deepEqual(result.save.jpeg.ref, {
    attachmentId: `sha256:${jpegSha}`,
    mediaType: 'image/jpeg',
    width: 3,
    height: 2,
    bytes: jpeg.byteLength,
    name: 'clean.jpg',
  })

  // ---- immutable object bytes/mode and staging cleanup.
  assert.equal(result.objects.png.bytes, hex(png), 'published PNG bytes are byte-identical')
  assert.equal(result.objects.jpeg.bytes, hex(jpeg), 'published JPEG bytes are byte-identical')
  assert.equal(result.objects.png.mode, 0o400, 'the published object is read-only')
  assert.equal(result.objects.jpeg.mode, 0o400, 'the published object is read-only')
  assert.deepEqual(result.objects.staging, [], 'the staging file is unlinked after publication')

  // ---- digest-verifying read-back returns the exact bytes and metadata.
  for (const [name, sha, bytes] of [
    ['png', pngSha, png],
    ['jpeg', jpegSha, jpeg],
  ] as const) {
    const stored = result.readBack[name]
    assert.equal(stored.error, undefined, `${name} read-back failed: ${JSON.stringify(stored.error)}`)
    assert.equal(stored.bytesMatch, true, `${name} read-back bytes are byte-identical`)
    assert.equal(stored.sha256, sha, `${name} read-back digest matches`)
    assert.equal(stored.ref?.['attachmentId'], `sha256:${sha}`)
  }

  // ---- the second identical save takes the store's EEXIST dedup path.
  assert.equal(result.dedup.error, undefined, `dedup save failed: ${JSON.stringify(result.dedup.error)}`)
  assert.equal(result.dedup.ref?.['attachmentId'], `sha256:${pngSha}`)
  assert.deepEqual(result.dedup.prefixesAfter, result.dedup.prefixesBefore, 'dedup creates no second object')
  assert.deepEqual(result.dedup.staging, [], 'dedup leaves no staging name')

  // ---- target numeric mask: real write + sync + close, then EEXIST.
  assert.equal(result.wx.collision.code, 'EEXIST', `second wx open must collide: ${JSON.stringify(result.wx.collision)}`)
  assert.equal(result.wx.bytes, '0001feff800a', 'the staged binary bytes are unchanged')
  assert.equal(result.wx.mode, 0o600, 'the creation mode is applied')

  // ---- numeric read/write/append/create/truncate combinations.
  assert.equal(result.append.bytes, result.append.expected, 'O_APPEND appends, not overwrites')
  assert.equal(result.createNoTrunc.length, 9, 'O_CREAT without O_TRUNC keeps the existing length')
  assert.equal(result.createNoTrunc.bytes.slice(0, 4), 'aabb', 'O_WRONLY starts writing at the beginning')
  assert.equal(result.truncate.bytes, '112233', 'O_TRUNC truncates before writing')
  assert.equal(result.readOnly.bytes, '112233', 'O_RDONLY reads the same bytes')
  assert.equal(result.syncFace.bytes, '11223344', 'the sync open/write/read face preserves append bytes')
  assert.equal(result.syncCollision.code, 'EEXIST', 'the sync face also refuses a second wx open')

  // ---- unsupported bits and contradictory combinations fail loud.
  assert.equal(result.unsupported.exclusiveWithoutCreate?.code, 'ERR_INVALID_ARG_VALUE')
  assert.equal(result.unsupported.unknownBit?.code, 'ERR_INVALID_ARG_VALUE')
  assert.equal(result.unsupported.appendReadOnly?.code, 'ERR_INVALID_ARG_VALUE')
  assert.match(result.unsupported.unknownBit?.message ?? '', /unsupported numeric open bit/)

  // ---- cancellation releases the staging name and never publishes.
  assert.notEqual(result.cancel.message, 'resolved without an error')
  assert.match(result.cancel.message, /cancelled by regression/)
  assert.deepEqual(result.cancel.stagingAfter, result.cancel.stagingBefore, 'abort removes the staging name')

  // ---- admission's prepared bytes equal the source for the clean vector.
  assert.equal(result.prepared.bytesMatch, true)
  assert.equal(result.prepared.sha256, pngSha)

  // ---- no fictional durability: an unacked VFS_MUT flush fails the handle.
  assert.equal(result.flushGuard.targetFlags, 193, 'the guard half still uses the full virtual wx mask')
  assert.deepEqual(result.flushGuard.directOpenFlags, [193],
    'the direct guard handle reaches the VFS with O_CREAT|O_EXCL|O_WRONLY, not 65')
  assert.deepEqual(result.flushGuard.directWithheld, ['/dsh/home/guard-direct/v1/tmp/durability.bin'],
    'the sink withholds the direct staging-file mutation')
  assert.deepEqual(result.flushGuard.storeOpenFlags, [193],
    'the real DSH store stages with O_CREAT|O_EXCL|O_WRONLY, not the preCreate 65 mask')
  assert.equal(result.flushGuard.storeStagingOpens.length, 1)
  assert.match(result.flushGuard.storeStagingOpens[0]?.path ?? '', /^\/dsh\/home\/guard-attachments\/v1\/tmp\/[^/]+$/)
  assert.equal(result.flushGuard.storeStagingOpens[0]?.flags, 193)
  assert.equal(result.flushGuard.storeWithheld.length, 1,
    'the directory syncs were acked; only the stage file is withheld')
  assert.match(result.flushGuard.storeWithheld[0] ?? '', /^\/dsh\/home\/guard-attachments\/v1\/tmp\/[^/]+$/)
  assert.equal(result.flushGuard.syncError.code, 'ACK_TIMEOUT', `handle.sync rejects without a level-1 ack: ${JSON.stringify(result.flushGuard.syncError)}`)
  assert.notEqual(result.flushGuard.syncError.name, 'None')
  assert.equal(result.flushGuard.storeError.cause?.code, 'ACK_TIMEOUT',
    `the store fails at the withheld stage sync, not a directory sync: ${JSON.stringify(result.flushGuard.storeError)}`)
  assert.notEqual(result.flushGuard.storeError.name, 'None', 'the store cannot report a durable ref without an ack')
  assert.match(result.flushGuard.storeError.message, /persist/i)
})


test('the Worker boot installs numeric open flags before the runtime host', async () => {
  const pair = createMemoryChannelPair({ autoConnect: true })
  const base = new TreeVfs()
  const vfs = createNamespaceVfs(base, WORKER_VFS_NAMESPACE)
  seedNamespaceRoots(vfs, WORKER_VFS_NAMESPACE)
  const events: string[] = []
  let disposed = 0
  const synthesize: WorkerEntrySynthesize = (_request, sink) => {
    const res: Record<string, unknown> = {
      writeHead: () => res,
      write: () => true,
      end: () => { sink.end({ status: 200, headers: {}, body: new Uint8Array(0) }); return res },
      destroy: () => { sink.fail('destroyed') },
    }
    return { req: {}, res, aborted: false, abort: () => {} }
  }
  const runtime: PhoneWorkerRuntime = {
    createHost: () => ({
      handleMessage: () => {},
      start: async () => { events.push('host.start') },
      stop: async () => {},
      vfs,
    }),
    whenRequestListener: async () => () => {},
    createChannel: () => pair.worker,
    synthesize,
    installNumericOpenFlags: () => {
      events.push('numeric-open-flags')
      return () => { disposed += 1 }
    },
  }
  const handle = await startPhoneWorker({
    channelURL: 'ws://127.0.0.1:1/channel',
    imageURL: 'image.tar.gz',
    runtime,
    python: false,
    pagePost: () => {},
  })
  try {
    assert.deepEqual(events.slice(0, 2), ['numeric-open-flags', 'host.start'],
      'the constants bridge is installed before the runtime host starts')
    assert.equal(disposed, 0)
  } finally {
    await handle.stop()
    pair.setDrop(() => true)
    pair.disconnect()
  }
  assert.equal(disposed, 1, 'stop restores the virtual constants table')
})
