// SPDX-License-Identifier: MIT
/**
 * Child-process harness for the numeric-open/attachment-store regression.
 *
 * The bundle is built by `tests/attachment-numeric-open.test.ts` against the
 * pinned checkout: `node:fs` and `node:fs/promises` resolve to the runtime's
 * own VFS bridges, `@deepseek-ai/dsh-attachment-local` resolves to its real
 * `store.ts`, and `sharp` is the phone Worker shim over the receiver-checking
 * stand-in. No fake filesystem or fake store stands in for a capability PASS:
 * every assertion below traverses the runtime `MemoryVfs`, the runtime's
 * `fs/promises.open`/`fs.openSync`, and DSH's own save/read/dedup code.
 *
 * The `flushGuard` half installs the real ordered-channel VFS sink on two
 * further runtime VFSs. A selective ack pump retains the level-1 ack only for
 * the directory/setup mutations and withholds it once a staging-file mutation
 * appears, so the failure is proven at the target numeric handle `sync()` (not
 * an earlier directory sync). The stage open is observed at the VFS boundary
 * and must carry the full `O_CREAT | O_EXCL | O_WRONLY` mask (`193`), never the
 * `O_CREAT | O_WRONLY` fallback (`65`) that would silently lose exclusivity.
 * @module @phone-dsh/dsh-plugins/tests/fixtures/attachment-numeric-harness
 */
import { createHash } from 'node:crypto'

import {
  closeSync, constants, createReadStream, openSync, readSync, writeSync,
  promises as fsPromises,
} from 'node:fs'
import * as attachmentModule from '@deepseek-ai/dsh-attachment-local'

// The test's esbuild alias resolves these runtime source paths; the namespace
// imports are the real mounted filesystem implementation, not a test double.
import * as runtimeMemory from '@deepseek-ai/dsh-experimental-webworker-runtime/src/storage/memory.ts'
import { setActiveVfs } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/storage/active.ts'

import {
  createMemoryChannelPair, decodeVfsMutation, encodeVfsAck, FrameType,
  type MemoryChannelPair, type VfsMutation,
} from '../../channel/src/index.ts'
import { installNumericOpenFlags, installNumericOpenHandlers } from '../../worker-entry/src/numeric-open-flags.ts'
import { installSink } from '../../worker-entry/src/entry.ts'
import { createNamespaceVfs, WORKER_VFS_NAMESPACE } from '../../wasi-toolbox/src/index.ts'
import { installFakeImagePlatform } from './fake-image-platform.ts'
import { GOLDEN_JPEG_3X2, GOLDEN_PNG_1X1 } from './golden-images.ts'

/** Structural face of the runtime's in-memory VFS this harness drives. */
interface MemoryVfsLike {
  subscribe(listener: (mutation: never) => void): () => void
  flush(): Promise<void>
  mkdirSync(path: string, options?: { readonly recursive?: boolean; readonly mode?: number }): unknown
  readdirSync(path: string): string[]
  readFileSync(path: string): string | Uint8Array
  statSync(path: string): { readonly mode: number; isFile(): boolean }
}

/** The runtime memory module entry this harness constructs. */
interface RuntimeMemoryModule {
  MemoryVfs: new () => MemoryVfsLike
}

const { MemoryVfs } = runtimeMemory as unknown as RuntimeMemoryModule

interface ImageRef {
  readonly attachmentId: string
  readonly mediaType: string
  readonly width: number
  readonly height: number
  readonly bytes: number
  readonly name?: string
}

interface PreparedImage {
  readonly data: Uint8Array
  readonly ref: ImageRef
}

interface ImageLimits {
  readonly maxImageBytes: number
  readonly maxImagesPerMessage: number
  readonly maxMessageImageBytes: number
  readonly maxImagePixels: number
  readonly maxImageDimension: number
  readonly mediaTypes: readonly string[]
}

interface NormalizationPolicy {
  readonly maxPixels: number
  readonly maxDimension: number
  readonly maxBytes: number
}

/** The real DSH store faces this harness calls. */
interface AttachmentStoreModule {
  prepareImageFile(
    input: { readonly data: Uint8Array; readonly mediaType: string; readonly name?: string },
    limits: ImageLimits,
    policy: NormalizationPolicy,
  ): Promise<PreparedImage>
  saveImageFile(
    root: string,
    input: { readonly data: Uint8Array; readonly mediaType: string; readonly name?: string },
    limits: ImageLimits,
    policy: NormalizationPolicy,
  ): Promise<ImageRef>
  readImageFile(root: string, ref: ImageRef, signal?: AbortSignal): Promise<{ readonly ref: ImageRef; readonly data: Uint8Array }>
  publishImmutableObjectStream(
    root: string,
    data: AsyncIterable<Uint8Array>,
    targetFor: (sha256: string, bytes: number) => string,
    signal?: AbortSignal,
  ): Promise<{ readonly sha256: string; readonly bytes: number }>
}

const {
  prepareImageFile, publishImmutableObjectStream, readImageFile, saveImageFile,
} = attachmentModule as unknown as AttachmentStoreModule

const LIMITS = {
  maxImageBytes: 20 * 1024 * 1024,
  maxImagesPerMessage: 20,
  maxMessageImageBytes: 200 * 1024 * 1024,
  maxImagePixels: 64_000_000,
  maxImageDimension: 8192,
  mediaTypes: ['image/png', 'image/jpeg', 'image/webp', 'image/gif'],
}
const POLICY = {
  maxPixels: 2048 * 2048,
  maxDimension: 8192,
  maxBytes: 4 * 1024 * 1024,
}
const ROOT = '/dsh/home/attachments/v1'
const GUARD_ROOT = '/dsh/home/guard-attachments/v1'
const FLUSH_TIMEOUT_MS = 25

function hex(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString('hex')
}

function digest(bytes: Uint8Array): string {
  return createHash('sha256').update(bytes).digest('hex')
}

function errorFacts(error: unknown): Record<string, unknown> {
  const value = error as { name?: unknown; code?: unknown; message?: unknown; cause?: unknown } | null
  return {
    name: typeof value?.name === 'string' ? value.name : 'Error',
    code: typeof value?.code === 'string' ? value.code : undefined,
    message: typeof value?.message === 'string' ? value.message : String(error),
    cause: errorFactsOfCause(value?.cause),
  }
}

function errorFactsOfCause(cause: unknown): Record<string, unknown> | undefined {
  if (cause === undefined) return undefined
  const value = cause as { name?: unknown; code?: unknown; message?: unknown } | null
  return {
    name: typeof value?.name === 'string' ? value.name : 'Error',
    code: typeof value?.code === 'string' ? value.code : undefined,
    message: typeof value?.message === 'string' ? value.message : String(cause),
  }
}

function bytesOf(data: Uint8Array | string): Uint8Array {
  if (typeof data !== 'string') return data
  return new TextEncoder().encode(data)
}

async function read(face: { readFile(path: string): Promise<Uint8Array | string> }, path: string): Promise<Uint8Array> {
  return bytesOf(await face.readFile(path))
}

interface SaveReport {
  readonly ref?: Record<string, unknown>
  readonly error?: Record<string, unknown>
}

async function save(data: Uint8Array, mediaType: string, name: string): Promise<SaveReport> {
  try {
    const ref = await saveImageFile(ROOT, { data, mediaType, name }, LIMITS, POLICY)
    return { ref: { ...ref } }
  } catch (error) {
    return { error: errorFacts(error) }
  }
}

function objectPath(sha: string): string {
  return `${ROOT}/objects/${sha.slice(0, 2)}/${sha}`
}

function listFiles(vfs: MemoryVfsLike, directory: string): string[] {
  try {
    return vfs.readdirSync(directory)
  } catch {
    return []
  }
}

interface NumericOpenObservation {
  readonly face: 'sync' | 'promise'
  readonly path: string
  readonly flags: number
}

interface SelectiveAck {
  readonly withheld: readonly string[]
  readonly dispose: () => void
}

/** True for a file directly inside the store's staging directory. */
function isStagingFile(path: string, root: string): boolean {
  const staging = `${root}/tmp`
  return path.startsWith(`${staging}/`) && !path.slice(staging.length + 1).includes('/')
}

/**
 * Record numeric masks at the mounted VFS boundary (after the adapter has been
 * installed, so this wrapper is the outermost face both `openSync` and
 * `fs/promises.open` reach). The returned handle is a transparent proxy whose
 * only change is observing `sync`; byte, stat, chmod and close calls still go
 * to the runtime object.
 */
function observeNumericOpens(
  source: MemoryVfsLike,
  opens: NumericOpenObservation[],
  syncPaths: string[],
): () => void {
  const target = source as unknown as {
    openFileSync?: (this: unknown, path: string, flags?: string | number, mode?: number) => unknown
    open?: (this: unknown, path: string, flags?: string | number, mode?: number) => unknown
  }
  const originalOpenFileSync = target.openFileSync
  const originalOpen = target.open
  const observeHandle = (handle: unknown, path: string): unknown => {
    if (handle === null || typeof handle !== 'object') return handle
    try {
      return new Proxy(handle as Record<PropertyKey, unknown>, {
        get(object, property) {
          if (property === 'sync') {
            const sync = Reflect.get(object, property, object)
            if (typeof sync !== 'function') return sync
            return (...args: unknown[]): unknown => {
              syncPaths.push(path)
              return (sync as (...syncArgs: unknown[]) => unknown).apply(object, args)
            }
          }
          const value = Reflect.get(object, property, object)
          return typeof value === 'function'
            ? (value as (...methodArgs: unknown[]) => unknown).bind(object)
            : value
        },
      })
    } catch {
      return handle
    }
  }
  const wrap = (
    face: NumericOpenObservation['face'],
    original: (this: unknown, path: string, flags?: string | number, mode?: number) => unknown,
  ) => function numericOpenObservation(
    this: unknown,
    path: string,
    flags?: string | number,
    mode?: number,
  ): unknown {
    if (typeof flags === 'number') opens.push({ face, path, flags })
    const result = original.call(this, path, flags, mode)
    if (result !== null && typeof result === 'object' && typeof (result as PromiseLike<unknown>).then === 'function') {
      return (result as Promise<unknown>).then(handle => observeHandle(handle, path))
    }
    return observeHandle(result, path)
  }

  let wrappedOpenFileSync: ReturnType<typeof wrap> | undefined
  if (typeof originalOpenFileSync === 'function') {
    wrappedOpenFileSync = wrap('sync', originalOpenFileSync)
    target.openFileSync = wrappedOpenFileSync
  }
  let wrappedOpen: ReturnType<typeof wrap> | undefined
  if (typeof originalOpen === 'function') {
    wrappedOpen = wrap('promise', originalOpen)
    target.open = wrappedOpen
  }
  return () => {
    if (wrappedOpenFileSync !== undefined && target.openFileSync === wrappedOpenFileSync) {
      target.openFileSync = originalOpenFileSync
    }
    if (wrappedOpen !== undefined && target.open === wrappedOpen) target.open = originalOpen
  }
}

/**
 * A real host-side ack pump with `autoAck: false`: it acknowledges every
 * received `VFS_MUT` until the withholding predicate matches one, then stops
 * acknowledging so every later cumulative wait fails with `ACK_TIMEOUT`.
 */
function installSelectiveLevel1Ack(
  pair: MemoryChannelPair,
  withhold: (mutation: VfsMutation) => boolean,
): SelectiveAck {
  const withheld: string[] = []
  let frozen = false
  const dispose = pair.host.onFrame((frame) => {
    if (frame.type !== FrameType.VFS_MUT) return
    const mutation = decodeVfsMutation(frame.payload)
    if (withhold(mutation)) {
      if (!frozen) withheld.push(mutation.path)
      frozen = true
      return
    }
    if (frozen) return
    pair.host.send(FrameType.VFS_ACK, encodeVfsAck({ level: 1, uptoMseq: mutation.mseq }))
  })
  return { withheld, dispose }
}

interface GuardRuntime {
  readonly opens: readonly NumericOpenObservation[]
  readonly syncPaths: readonly string[]
  readonly withheld: readonly string[]
  dispose(): Promise<void>
}

/**
 * Build one independent guard runtime over the real `MemoryVfs`. Directories
 * and (when supplied) the first durable save run before the sink exists, so
 * the subsequent selective ack starts from a clean mutation watermark.
 */
async function openGuardRuntime(options: {
  readonly root: string
  readonly withhold: (mutation: VfsMutation) => boolean
  readonly beforeSink?: () => Promise<void>
}): Promise<GuardRuntime> {
  const raw = new MemoryVfs()
  const disposeNumeric = installNumericOpenHandlers(raw)
  const opens: NumericOpenObservation[] = []
  const syncPaths: string[] = []
  const disposeObservation = observeNumericOpens(raw, opens, syncPaths)
  raw.mkdirSync('/dsh', { recursive: true })
  raw.mkdirSync('/dsh/home', { recursive: true })
  raw.mkdirSync(options.root, { recursive: true })
  raw.mkdirSync(`${options.root}/tmp`, { recursive: true })
  const namespace = createNamespaceVfs(raw, WORKER_VFS_NAMESPACE)
  setActiveVfs(namespace)
  if (options.beforeSink !== undefined) {
    await options.beforeSink()
    // Only opens made after the sink exists belong to the withheld-ack half.
    opens.length = 0
    syncPaths.length = 0
  }
  const pair = createMemoryChannelPair({ autoConnect: true, nextMseq: 1n, ackedMseq: 0n, autoAck: false })
  const disposeSink = installSink(namespace, pair.worker, { ackTimeoutMs: FLUSH_TIMEOUT_MS })
  const ack = installSelectiveLevel1Ack(pair, options.withhold)
  // The durability timer is deliberately unref'ed in production (the Worker
  // channel is the live handle); a standalone harness needs one referenced
  // handle for the bounded ACK_TIMEOUT rejection to run.
  const keepAlive = setInterval(() => {}, 1_000)
  return {
    opens,
    syncPaths,
    get withheld() { return ack.withheld },
    async dispose() {
      clearInterval(keepAlive)
      ack.dispose()
      disposeSink()
      await pair.worker.close()
      disposeObservation()
      disposeNumeric()
    },
  }
}

async function main(): Promise<void> {
  installFakeImagePlatform()
  const runtimeConstants: Record<string, number | undefined> = constants
  const disposeConstants = installNumericOpenFlags({ constants: runtimeConstants })
  const report: Record<string, unknown> = {
    constants: {
      O_EXCL: runtimeConstants['O_EXCL'],
      target: (runtimeConstants['O_CREAT'] ?? 0) | (runtimeConstants['O_EXCL'] ?? 0) | (runtimeConstants['O_WRONLY'] ?? 0),
    },
  }

  const png = new Uint8Array(Buffer.from(GOLDEN_PNG_1X1, 'base64'))
  const jpeg = new Uint8Array(Buffer.from(GOLDEN_JPEG_3X2, 'base64'))

  // ---- real DSH store over the real runtime VFS ---------------------------
  const raw = new MemoryVfs()
  const disposeNumeric = installNumericOpenHandlers(raw)
  const vfs = createNamespaceVfs(raw, WORKER_VFS_NAMESPACE)
  setActiveVfs(vfs)
  try {
    const pngSaved = await save(png, 'image/png', 'one.png')
    const jpegSaved = await save(jpeg, 'image/jpeg', 'clean.jpg')
    report.save = { png: pngSaved, jpeg: jpegSaved }

    const pngSha = digest(png)
    const jpegSha = digest(jpeg)
    report.objects = {
      png: {
        path: objectPath(pngSha),
        mode: vfs.statSync(objectPath(pngSha)).mode & 0o777,
        bytes: hex(asBytes(vfs.readFileSync(objectPath(pngSha)))),
      },
      jpeg: {
        path: objectPath(jpegSha),
        mode: vfs.statSync(objectPath(jpegSha)).mode & 0o777,
        bytes: hex(asBytes(vfs.readFileSync(objectPath(jpegSha)))),
      },
      staging: listFiles(vfs, `${ROOT}/tmp`),
    }

    // Read back through DSH's digest-verifying reader.
    const readBack: Record<string, unknown> = {}
    for (const [name, saved, source] of [
      ['png', pngSaved, png],
      ['jpeg', jpegSaved, jpeg],
    ] as const) {
      if (saved.ref === undefined) {
        readBack[name] = { error: saved.error }
        continue
      }
      try {
        const stored = await readImageFile(ROOT, saved.ref as never)
        readBack[name] = {
          ref: { ...stored.ref },
          bytesMatch: hex(stored.data) === hex(source),
          sha256: digest(stored.data),
        }
      } catch (error) {
        readBack[name] = { error: errorFacts(error) }
      }
    }
    report.readBack = readBack

    for await (const chunk of createReadStream(objectPath(pngSha))) void chunk
    const objectsBefore = [...listFiles(vfs, `${ROOT}/objects`)].sort()
    const dedup = await save(png, 'image/png', 'one.png')
    report.dedup = {
      ref: dedup.ref,
      error: dedup.error,
      prefixesBefore: objectsBefore,
      prefixesAfter: [...listFiles(vfs, `${ROOT}/objects`)].sort(),
      staging: listFiles(vfs, `${ROOT}/tmp`),
    }

    // ---- numeric open/read/write/append/sync/callback-free faces ----------
    const direct = `${ROOT}/tmp/numeric-direct.bin`
    const payload = Uint8Array.from([0x00, 0x01, 0xfe, 0xff, 0x80, 0x0a])
    const secondPayload = Uint8Array.from([0x7f, 0x00, 0x42])
    const wx = await fsPromises.open(
      direct,
      (runtimeConstants['O_CREAT'] ?? 0) | (runtimeConstants['O_EXCL'] ?? 0) | (runtimeConstants['O_WRONLY'] ?? 0),
      0o600,
    )
    await wx.writeFile(payload)
    await wx.sync()
    await wx.close()
    let collision: Record<string, unknown>
    try {
      const again = await fsPromises.open(
        direct,
        (runtimeConstants['O_CREAT'] ?? 0) | (runtimeConstants['O_EXCL'] ?? 0) | (runtimeConstants['O_WRONLY'] ?? 0),
        0o600,
      )
      await again.close()
      collision = { name: 'None', message: 'resolved without an error' }
    } catch (error) {
      collision = errorFacts(error)
    }
    report.wx = {
      collision,
      bytes: hex(await read(fsPromises, direct)),
      mode: vfs.statSync(direct).mode & 0o777,
    }

    const appendHandle = await fsPromises.open(direct, (runtimeConstants['O_WRONLY'] ?? 0) | (runtimeConstants['O_APPEND'] ?? 0))
    await appendHandle.writeFile(secondPayload)
    await appendHandle.close()
    report.append = {
      bytes: hex(await read(fsPromises, direct)),
      expected: hex(concat(payload, secondPayload)),
    }

    const createNoTrunc = await fsPromises.open(
      direct,
      (runtimeConstants['O_CREAT'] ?? 0) | (runtimeConstants['O_WRONLY'] ?? 0),
    )
    await createNoTrunc.writeFile(Uint8Array.from([0xaa, 0xbb]))
    await createNoTrunc.close()
    report.createNoTrunc = {
      bytes: hex(await read(fsPromises, direct)),
      length: (await read(fsPromises, direct)).byteLength,
    }

    const truncHandle = await fsPromises.open(direct, (runtimeConstants['O_WRONLY'] ?? 0) | (runtimeConstants['O_TRUNC'] ?? 0))
    await truncHandle.writeFile(Uint8Array.from([0x11, 0x22, 0x33]))
    await truncHandle.close()
    report.truncate = { bytes: hex(await read(fsPromises, direct)) }

    const readOnly = await fsPromises.open(direct, runtimeConstants['O_RDONLY'] ?? 0)
    report.readOnly = { bytes: hex(bytesOf(await readOnly.readFile())) }
    await readOnly.close()

    const writeOnly = openSync(direct, (runtimeConstants['O_WRONLY'] ?? 0) | (runtimeConstants['O_APPEND'] ?? 0))
    writeSync(writeOnly, Uint8Array.from([0x44]))
    closeSync(writeOnly)
    const syncWritten = openSync(direct, runtimeConstants['O_RDONLY'] ?? 0)
    const syncBuffer = new Uint8Array(64)
    const syncCount = readSync(syncWritten, syncBuffer)
    closeSync(syncWritten)
    report.syncFace = { bytes: hex(syncBuffer.subarray(0, syncCount)) }

    const syncCreate = openSync(
      `${ROOT}/tmp/numeric-sync.bin`,
      (runtimeConstants['O_CREAT'] ?? 0) | (runtimeConstants['O_EXCL'] ?? 0) | (runtimeConstants['O_WRONLY'] ?? 0),
      0o600,
    )
    let syncCollision: Record<string, unknown>
    try {
      const duplicate = openSync(
        `${ROOT}/tmp/numeric-sync.bin`,
        (runtimeConstants['O_CREAT'] ?? 0) | (runtimeConstants['O_EXCL'] ?? 0) | (runtimeConstants['O_WRONLY'] ?? 0),
      )
      closeSync(duplicate)
      syncCollision = { name: 'None', message: 'returned without an error' }
    } catch (error) {
      syncCollision = errorFacts(error)
    }
    closeSync(syncCreate)
    report.syncCollision = syncCollision

    const unsupported: Record<string, Record<string, unknown>> = {}
    for (const [name, flags] of [
      ['exclusiveWithoutCreate', runtimeConstants['O_EXCL'] ?? 0],
      ['unknownBit', (runtimeConstants['O_WRONLY'] ?? 0) | 0o400000],
      ['appendReadOnly', (runtimeConstants['O_RDONLY'] ?? 0) | (runtimeConstants['O_APPEND'] ?? 0)],
    ] as const) {
      try {
        const handle = await fsPromises.open(`${ROOT}/tmp/invalid-${name}.bin`, flags)
        await handle.close()
        unsupported[name] = { name: 'None', message: 'resolved without an error' }
      } catch (error) {
        unsupported[name] = errorFacts(error)
      }
    }
    report.unsupported = unsupported

    // ---- cancellation cleans the store's staging name ---------------------
    const cancel = await (async (): Promise<Record<string, unknown>> => {
      const controller = new AbortController()
      const before = listFiles(vfs, `${ROOT}/tmp`).sort()
      const iterable = (async function* (): AsyncIterable<Uint8Array> {
        yield Uint8Array.from([0x01, 0x02, 0x03])
        controller.abort(new Error('cancelled by regression'))
        yield Uint8Array.from([0x04, 0x05])
      })()
      try {
        await publishImmutableObjectStream(ROOT, iterable, () => `${ROOT}/objects/ab/cancelled`, controller.signal)
        return { name: 'None', message: 'resolved without an error', staging: listFiles(vfs, `${ROOT}/tmp`) }
      } catch (error) {
        return {
          ...errorFacts(error),
          stagingBefore: before,
          stagingAfter: listFiles(vfs, `${ROOT}/tmp`).sort(),
        }
      }
    })()
    report.cancel = cancel

    // `prepareImageFile` must return bytes identical to the source for the
    // clean pass-through vectors; this is the store's admission boundary.
    const prepared = await prepareImageFile({ data: png, mediaType: 'image/png' }, LIMITS, POLICY)
    report.prepared = { sha256: digest(prepared.data), bytesMatch: hex(prepared.data) === hex(png), ref: { ...prepared.ref } }
  } finally {
    disposeNumeric()
  }

  // ---- selective level-1 ack: the store's staging sync must fail loud -----
  // The constants stay installed for this half: the observed staging open must
  // be the real target mask 193, not a degraded 65 after a premature dispose.
  const targetFlags = (runtimeConstants['O_CREAT'] ?? 0)
    | (runtimeConstants['O_EXCL'] ?? 0)
    | (runtimeConstants['O_WRONLY'] ?? 0)
  const flushGuard: Record<string, unknown> = { targetFlags }
  report.flushGuard = flushGuard

  // Directory setup and the first durable save happen before the sink exists.
  // The second save then acks the staging-directory setup/sync mutations but
  // withholds the ack from the moment the numeric stage file is created, so
  // the store must fail at that stage handle's write/sync path, not earlier.
  const storeGuard = await openGuardRuntime({
    root: GUARD_ROOT,
    beforeSink: async () => {
      await saveImageFile(GUARD_ROOT, { data: jpeg, mediaType: 'image/jpeg' }, LIMITS, POLICY)
    },
    withhold: mutation => isStagingFile(mutation.path, GUARD_ROOT),
  })
  try {
    let storeError: Record<string, unknown>
    try {
      await saveImageFile(GUARD_ROOT, { data: png, mediaType: 'image/png' }, LIMITS, POLICY)
      storeError = { name: 'None', message: 'store resolved without an ack' }
    } catch (error) {
      storeError = errorFacts(error)
    }
    flushGuard['storeError'] = storeError
    flushGuard['storeOpenFlags'] = storeGuard.opens
      .filter(open => open.flags === targetFlags)
      .map(open => open.flags)
    flushGuard['storeStagingOpens'] = storeGuard.opens
      .filter(open => isStagingFile(open.path, GUARD_ROOT))
      .map(open => ({ path: open.path, flags: open.flags }))
    flushGuard['storeSyncPaths'] = [...storeGuard.syncPaths]
    flushGuard['storeWithheld'] = [...storeGuard.withheld]
  } finally {
    await storeGuard.dispose()
  }

  // ---- a direct numeric wx handle sync must also fail loud ----------------
  const directRoot = '/dsh/home/guard-direct/v1'
  const directFile = `${directRoot}/tmp/durability.bin`
  const directGuard = await openGuardRuntime({
    root: directRoot,
    withhold: mutation => mutation.path === directFile,
  })
  try {
    const handle = await fsPromises.open(directFile, targetFlags, 0o600)
    await handle.writeFile(Uint8Array.from([1, 2, 3, 4]))
    let syncError: Record<string, unknown>
    try {
      await handle.sync()
      syncError = { name: 'None', message: 'sync resolved without an ack' }
    } catch (error) {
      syncError = errorFacts(error)
    }
    await handle.close()
    flushGuard['syncError'] = syncError
    flushGuard['directOpenFlags'] = directGuard.opens
      .filter(open => open.path === directFile)
      .map(open => open.flags)
    flushGuard['directSyncPaths'] = [...directGuard.syncPaths]
    flushGuard['directWithheld'] = [...directGuard.withheld]
  } finally {
    await directGuard.dispose()
  }

  // Dispose only after both guard halves so every staging mask is still 193.
  disposeConstants()

  console.log(`__PDSH_ATTACHMENT_NUMERIC_RESULT__ ${JSON.stringify(report)}`)
}

function asBytes(value: string | Uint8Array): Uint8Array {
  return typeof value === 'string' ? new TextEncoder().encode(value) : value
}

function concat(left: Uint8Array, right: Uint8Array): Uint8Array {
  const joined = new Uint8Array(left.byteLength + right.byteLength)
  joined.set(left)
  joined.set(right, left.byteLength)
  return joined
}

await main()
