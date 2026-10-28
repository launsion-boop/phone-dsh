// SPDX-License-Identifier: MIT
/**
 * Real VFS file service behind the `phone/import*` Remotes.
 *
 * The service operates on the Worker runtime's `node:fs/promises` (the
 * in-memory VFS). It never materializes the workspace itself: appending bytes
 * to the VFS is what feeds the existing sink/WAL/materialized path, exactly
 * like any other Worker write.
 *
 * Layout per import:
 *
 *   <target>/.imports/<importId>/...   staged chunks
 *   <target>/imports/<entryName>/...   final tree after commit
 *
 * `.imports` is private staging; `imports` is the user-visible result. A
 * failed or aborted import never leaves a final directory behind, and an
 * existing `imports/<name>` is never overwritten: the next free
 * `<name>-2`, `<name>-3`, ... is used.
 *
 * @module @phone-dsh/dsh-phone-directory-import/import-service
 */

import { randomUUID } from 'node:crypto'
import { appendFile, mkdir, readdir, rename, rm, stat, writeFile } from 'node:fs/promises'
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { Buffer } from 'node:buffer'
import {
  DIRECTORY_IMPORT_LIMITS,
  type DirectoryImportBeginRequest,
  type DirectoryImportCommitResponse,
  type DirectoryImportWriteResponse,
  type WorkspaceImportErrorCode,
} from './types.ts'

/** Injected durability/observation hooks; production defaults use the Worker VFS. */
export interface WorkspaceImportHooks {
  /** Flush the Worker VFS after the final rename and verification. */
  readonly flush?: () => Promise<void> | void
  /** Verify the committed directory through the host filesystem service. */
  readonly verify?: (absolutePath: string) => Promise<void> | void
}

/** Typed service failure the Remote maps onto the existing Gateway vocabulary. */
export class WorkspaceImportError extends Error {
  readonly code: WorkspaceImportErrorCode

  constructor(code: WorkspaceImportErrorCode, message: string) {
    super(message)
    this.name = 'WorkspaceImportError'
    this.code = code
  }
}

interface ImportFileState {
  readonly size: number
  received: number
}

/**
 * Lifecycle of one import. `active` accepts writes; `committing` is the atomic
 * point of no return; `aborting` refuses new writes while the deletion runs.
 */
type ImportState = 'active' | 'committing' | 'aborting'

interface ActiveImport {
  readonly importId: string
  readonly targetDirectory: string
  readonly entryName: string
  readonly stagingDirectory: string
  readonly dotImportsDirectory: string
  /** Whether this import created `<target>/.imports`; only then may abort remove it. */
  readonly dotImportsCreated: boolean
  readonly files: Map<string, ImportFileState>
  readonly totalBytes: number
  state: ImportState
  /** Writes that started before the state changed; commit/abort wait for them. */
  pendingWrites: number
  readonly writeWaiters: (() => void)[]
  /**
   * Serializes this import's writes. Two concurrent writes to the same offset
   * must not both pass the `offset === received` check before either append
   * lands; the second one has to observe the first one's `received`.
   */
  writeQueue: Promise<void>
}

/** A committed result retained so a lost commit response can be retried. */
interface CompletedImport {
  readonly result: DirectoryImportCommitResponse
  readonly completedAt: number
}

interface NormalizedManifest {
  readonly targetDirectory: string
  readonly entryName: string
  readonly directories: readonly string[]
  readonly files: readonly { readonly path: string; readonly size: number }[]
  readonly totalBytes: number
}

/** One commit may not hold the session's import queue forever. */
const COMMIT_TIMEOUT_MS = 30_000

/**
 * How long a successful commit stays retryable. A lost response must not turn
 * a published `imports/<name>` into `not-found`, but the cache must stay
 * bounded: it stores only the four result fields, never file bytes.
 */
export const COMPLETED_IMPORT_TTL_MS = 10 * 60_000

/** Upper bound on retained completed results per session service. */
export const MAX_COMPLETED_IMPORTS = 256

/** Strict canonical base64 (padded, no whitespace, no URL alphabet). */
const BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/

const VFS_FLUSH_GLOBAL = '__PDSH_VFS_FLUSH__'

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function byteLength(value: string): number {
  return Buffer.byteLength(value, 'utf8')
}

function fail(message: string): never {
  throw new WorkspaceImportError('bad-request', message)
}

function isMissing(error: unknown): boolean {
  return isRecord(error) && error.code === 'ENOENT'
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

async function pathExists(path: string): Promise<boolean> {
  try {
    await stat(path)
    return true
  } catch (error) {
    if (isMissing(error)) return false
    throw error
  }
}

async function isDirectory(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isDirectory()
  } catch (error) {
    if (isMissing(error)) return false
    throw error
  }
}

/** Validate one `/`-separated relative path against escapes, NUL and the byte cap. */
function assertRelativePath(path: unknown, label: string): asserts path is string {
  if (typeof path !== 'string' || path.length === 0) fail(`${label} must be a non-empty relative path`)
  if (byteLength(path) > DIRECTORY_IMPORT_LIMITS.maxPathBytes) {
    fail(`${label} exceeds ${DIRECTORY_IMPORT_LIMITS.maxPathBytes} bytes: ${JSON.stringify(path)}`)
  }
  if (path.includes('\0')) fail(`${label} contains NUL`)
  if (isAbsolute(path) || path.startsWith('/')) fail(`${label} must be relative: ${JSON.stringify(path)}`)
  const segments = path.split('/')
  for (const segment of segments) {
    if (segment.length === 0 || segment === '.' || segment === '..') {
      fail(`${label} has an unsafe segment: ${JSON.stringify(path)}`)
    }
    if (byteLength(segment) > DIRECTORY_IMPORT_LIMITS.maxEntryNameLength) {
      fail(`${label} has a name exceeding ${DIRECTORY_IMPORT_LIMITS.maxEntryNameLength} UTF-8 bytes: ${JSON.stringify(path)}`)
    }
  }
}

/** Validate the final directory name (one segment, bounded, not a traversal). */
function assertEntryName(name: unknown): asserts name is string {
  if (typeof name !== 'string' || name.length === 0) fail('entryName must be a non-empty string')
  if (name === '.' || name === '..' || name.includes('/') || name.includes('\0')) {
    fail(`entryName is not one safe path segment: ${JSON.stringify(name)}`)
  }
  if (byteLength(name) > DIRECTORY_IMPORT_LIMITS.maxEntryNameLength) {
    fail(`entryName exceeds ${DIRECTORY_IMPORT_LIMITS.maxEntryNameLength} bytes`)
  }
}

/** Lexical containment under the session workspace root. */
function assertTargetDirectory(target: unknown, workspaceRoot: string): string {
  if (typeof target !== 'string' || target.length === 0) fail('targetDirectory must be a non-empty absolute path')
  if (target.includes('\0')) fail('targetDirectory contains NUL')
  if (!isAbsolute(target)) fail(`targetDirectory must be absolute: ${JSON.stringify(target)}`)
  const root = resolve(workspaceRoot)
  const candidate = resolve(target)
  const prefix = root.endsWith(sep) ? root : `${root}${sep}`
  if (candidate !== root && !candidate.startsWith(prefix)) {
    fail('targetDirectory is outside the session workspace root')
  }
  return candidate
}

function normalizeManifest(request: unknown, workspaceRoot: string): NormalizedManifest {
  if (!isRecord(request)) fail('importBegin request must be an object')
  if (request.v !== 1) fail('importBegin request.v must be 1')
  if (typeof request.sessionId !== 'string' || request.sessionId.length === 0) fail('sessionId must be a non-empty string')
  const targetDirectory = assertTargetDirectory(request.targetDirectory, workspaceRoot)
  const entryName = request.entryName
  assertEntryName(entryName)

  const rawDirectories = request.directories
  if (!Array.isArray(rawDirectories)) fail('directories must be an array')
  if (rawDirectories.length > DIRECTORY_IMPORT_LIMITS.maxDirectories) {
    fail(`directories exceeds ${DIRECTORY_IMPORT_LIMITS.maxDirectories} entries`)
  }
  const directories: string[] = []
  const directorySet = new Set<string>()
  for (const raw of rawDirectories) {
    assertRelativePath(raw, 'directories[]')
    if (directorySet.has(raw)) fail(`duplicate directory: ${JSON.stringify(raw)}`)
    directorySet.add(raw)
    directories.push(raw)
  }

  const rawFiles = request.files
  if (!Array.isArray(rawFiles)) fail('files must be an array')
  if (rawFiles.length > DIRECTORY_IMPORT_LIMITS.maxFiles) {
    fail(`files exceeds ${DIRECTORY_IMPORT_LIMITS.maxFiles} entries`)
  }
  const files: { path: string; size: number }[] = []
  const filePaths = new Set<string>()
  let totalBytes = 0
  for (const raw of rawFiles) {
    if (!isRecord(raw)) fail('files[] must be an object')
    assertRelativePath(raw.path, 'files[].path')
    if (directorySet.has(raw.path)) fail(`path is both a file and a directory: ${JSON.stringify(raw.path)}`)
    if (filePaths.has(raw.path)) fail(`duplicate file: ${JSON.stringify(raw.path)}`)
    if (!Number.isSafeInteger(raw.size) || (raw.size as number) < 0) {
      fail(`files[].size must be a non-negative safe integer: ${JSON.stringify(raw.path)}`)
    }
    const size = raw.size as number
    if (size > DIRECTORY_IMPORT_LIMITS.maxFileBytes) {
      fail(`file exceeds ${DIRECTORY_IMPORT_LIMITS.maxFileBytes} bytes: ${JSON.stringify(raw.path)}`)
    }
    totalBytes += size
    if (!Number.isSafeInteger(totalBytes) || totalBytes > DIRECTORY_IMPORT_LIMITS.maxTotalBytes) {
      fail(`import exceeds ${DIRECTORY_IMPORT_LIMITS.maxTotalBytes} bytes`)
    }
    filePaths.add(raw.path)
    files.push({ path: raw.path, size })
  }

  for (const path of filePaths) {
    let parent = dirname(path)
    while (parent !== '.' && parent.length > 0) {
      if (filePaths.has(parent)) fail(`file path is also a parent directory: ${JSON.stringify(parent)}`)
      parent = dirname(parent)
    }
  }

  if (!Number.isSafeInteger(request.totalBytes) || request.totalBytes !== totalBytes) {
    fail('totalBytes must equal the sum of file sizes')
  }

  return { targetDirectory, entryName, directories, files, totalBytes }
}

function defaultVerify(absolutePath: string): Promise<void> {
  return (async () => {
    const info = await stat(absolutePath)
    if (!info.isDirectory()) {
      throw new WorkspaceImportError('internal', `committed import is not a directory: ${absolutePath}`)
    }
  })()
}

function defaultFlush(): Promise<void> {
  const flush = (globalThis as { __PDSH_VFS_FLUSH__?: () => Promise<void> | void })[VFS_FLUSH_GLOBAL]
  if (typeof flush !== 'function') return Promise.resolve()
  return (async () => {
    await flush()
  })()
}

/** Run a promise with a bounded wait; the timer is always cleared. */
function withTimeout<T>(work: Promise<T>, milliseconds: number, label: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined
  const timeout = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => {
      reject(new WorkspaceImportError('internal', `${label} timed out after ${milliseconds} ms`))
    }, milliseconds)
  })
  return Promise.race([work, timeout]).finally(() => {
    if (timer !== undefined) clearTimeout(timer)
  })
}

/**
 * One session's import backend over the Worker VFS.
 *
 * Construct it with the session workspace root; every path the manifest names
 * is validated against that root before any directory is created.
 */
export class WorkspaceImportService {
  private readonly workspaceRoot: string
  private readonly verifyCommitted: (absolutePath: string) => Promise<void> | void
  private readonly flushWorkspace: () => Promise<void> | void
  private readonly active = new Map<string, ActiveImport>()
  private readonly completed = new Map<string, CompletedImport>()
  private commitQueue: Promise<void> = Promise.resolve()

  constructor(workspaceRoot: string, hooks: WorkspaceImportHooks = {}) {
    if (typeof workspaceRoot !== 'string' || workspaceRoot.length === 0) {
      throw new WorkspaceImportError('bad-request', 'workspaceRoot must be a non-empty string')
    }
    this.workspaceRoot = resolve(workspaceRoot)
    this.verifyCommitted = hooks.verify ?? defaultVerify
    this.flushWorkspace = hooks.flush ?? defaultFlush
  }

  /**
   * Validate a manifest, create `<target>/.imports/<uuid>` and pre-create every
   * declared directory (so empty directories survive the import).
   */
  async begin(request: DirectoryImportBeginRequest): Promise<string> {
    this.pruneCompleted()
    const manifest = normalizeManifest(request, this.workspaceRoot)
    if (!(await isDirectory(manifest.targetDirectory))) {
      throw new WorkspaceImportError('bad-request', 'targetDirectory is not an existing directory')
    }

    const dotImportsDirectory = join(manifest.targetDirectory, '.imports')
    const dotImportsExisted = await pathExists(dotImportsDirectory)
    if (dotImportsExisted && !(await isDirectory(dotImportsDirectory))) {
      throw new WorkspaceImportError('bad-request', '.imports exists and is not a directory')
    }

    const importId = randomUUID()
    const stagingDirectory = join(dotImportsDirectory, importId)
    let dotImportsCreated = false
    try {
      if (!dotImportsExisted) {
        await mkdir(dotImportsDirectory, { recursive: true })
        dotImportsCreated = true
      }
      await mkdir(stagingDirectory, { recursive: false })
      for (const directory of manifest.directories) {
        await mkdir(join(stagingDirectory, directory), { recursive: true })
      }
      // A zero-byte file never produces a write chunk, so materialize it here
      // instead of relying on appendFile. Commit must never report a file it
      // did not create.
      for (const file of manifest.files) {
        if (file.size !== 0) continue
        const destination = join(stagingDirectory, file.path)
        await mkdir(dirname(destination), { recursive: true })
        await writeFile(destination, new Uint8Array(0))
      }
    } catch (error) {
      await rm(stagingDirectory, { recursive: true, force: true }).catch(() => {})
      if (dotImportsCreated) await this.removeIfEmpty(dotImportsDirectory)
      throw error
    }

    const files = new Map<string, ImportFileState>()
    for (const file of manifest.files) files.set(file.path, { size: file.size, received: 0 })
    this.active.set(importId, {
      importId,
      targetDirectory: manifest.targetDirectory,
      entryName: manifest.entryName,
      stagingDirectory,
      dotImportsDirectory,
      dotImportsCreated,
      files,
      totalBytes: manifest.totalBytes,
      state: 'active',
      pendingWrites: 0,
      writeWaiters: [],
      writeQueue: Promise.resolve(),
    })
    return importId
  }

  /**
   * Append exactly the next chunk of one manifest file.
   *
   * The whole write is serialized on the import's write queue. Only the offset
   * and size checks that depend on previously received bytes run inside the
   * queued section, immediately before `appendFile`; a rejected offset never
   * creates a directory or appends a byte. `pendingWrites` is registered in the
   * same synchronous section as the state check, so a commit that seals the
   * import just afterwards still waits for this write and never publishes a
   * half-written tree.
   */
  async write(importId: string, path: string, offset: number, dataBase64: string): Promise<DirectoryImportWriteResponse> {
    const record = this.requireActive(importId)
    if (record.state !== 'active') {
      fail(`import is not accepting writes while ${record.state}: ${JSON.stringify(importId)}`)
    }
    if (typeof path !== 'string' || path.length === 0) fail('path must be a non-empty string')
    if (!record.files.has(path)) fail(`path is not in the import manifest: ${JSON.stringify(path)}`)
    if (!Number.isSafeInteger(offset) || offset < 0) fail('offset must be a non-negative safe integer')
    if (typeof dataBase64 !== 'string' || dataBase64.length === 0 || dataBase64.length % 4 !== 0 ||
      !BASE64.test(dataBase64)) {
      fail(`dataBase64 is not canonical base64 for ${JSON.stringify(path)}`)
    }
    const data = Buffer.from(dataBase64, 'base64')
    if (data.length === 0) fail('dataBase64 decodes to zero bytes')
    if (data.length > DIRECTORY_IMPORT_LIMITS.chunkBytes) {
      fail(`chunk exceeds ${DIRECTORY_IMPORT_LIMITS.chunkBytes} bytes`)
    }
    // No `await` since the state check above, so this write is registered
    // before a concurrent commit can start waiting for it.
    record.pendingWrites += 1
    const run = record.writeQueue.then(async () => {
      const file = record.files.get(path)
      if (file === undefined) fail(`path is not in the import manifest: ${JSON.stringify(path)}`)
      if (offset !== file.received) {
        fail(`offset ${offset} does not equal received ${file.received} for ${JSON.stringify(path)}`)
      }
      if (file.received + data.length > file.size) {
        fail(`chunk would exceed the declared size for ${JSON.stringify(path)}`)
      }
      const destination = join(record.stagingDirectory, path)
      await mkdir(dirname(destination), { recursive: true })
      await appendFile(destination, data)
      file.received += data.length
      return { received: file.received }
    })
    record.writeQueue = run.then(() => undefined, () => undefined)
    try {
      return await run
    } finally {
      record.pendingWrites -= 1
      if (record.pendingWrites === 0) {
        const waiters = record.writeWaiters.splice(0)
        for (const resolve of waiters) resolve()
      }
    }
  }

  /**
   * Publish the staged tree as `<target>/imports/<unique name>`.
   *
   * `commit` is the atomic point of no return. It runs on the same transaction
   * queue as `abort`, so an abort that arrives while a commit is running waits
   * for the commit and then refuses to touch the published tree. A successful
   * result is retained for a bounded retry window: a lost channel response can
   * repeat the same `importCommit` and receive the same real result instead of
   * `not-found` (which would tempt the native side to import a `-2` copy).
   *
   * Verification and flush complete before the method returns. A failure after
   * the rename removes the final directory this import created, waits for a
   * second flush so recovery cannot resurrect it, and reports an explicit
   * error when even that rollback cannot complete.
   */
  commit(importId: string): Promise<DirectoryImportCommitResponse> {
    this.pruneCompleted()
    const settled = this.completedResult(importId)
    if (settled !== undefined) return Promise.resolve(settled)
    const record = this.active.get(importId)
    if (record === undefined) {
      return Promise.reject(new WorkspaceImportError('not-found', `unknown import: ${JSON.stringify(importId)}`))
    }
    if (record.state === 'aborting') {
      return Promise.reject(new WorkspaceImportError('not-found', `import is being aborted: ${JSON.stringify(importId)}`))
    }
    // Seal the transaction synchronously so no write can start after the
    // caller decided to commit, even before the queued work begins.
    if (record.state === 'active') record.state = 'committing'

    return this.serialize(async () => {
      const completed = this.completedResult(importId)
      if (completed !== undefined) return completed
      const current = this.active.get(importId)
      if (current === undefined) {
        throw new WorkspaceImportError('not-found', `unknown import: ${JSON.stringify(importId)}`)
      }
      await this.waitForWrites(current)
      const completedWhileWaiting = this.completedResult(importId)
      if (completedWhileWaiting !== undefined) return completedWhileWaiting

      const importsDirectory = join(current.targetDirectory, 'imports')
      let missing = 0
      for (const file of current.files.values()) {
        if (file.received !== file.size) missing += 1
      }
      if (missing > 0) {
        return this.failCommit(current, new WorkspaceImportError(
          'bad-request', `${missing} file(s) are not fully written`), {
          importsDirectory,
          importsCreated: false,
          renamed: false,
        })
      }
      // The counters are only bookkeeping: before publishing, prove that every
      // staged file really exists with the manifest's byte length. A missing or
      // short file must never be renamed into `imports/<name>`.
      try {
        for (const [path, file] of current.files) {
          const staged = await stat(join(current.stagingDirectory, path))
          if (!staged.isFile() || staged.size !== file.size) {
            throw new WorkspaceImportError('internal',
              `staged file does not match its manifest size: ${JSON.stringify(path)}`)
          }
        }
      } catch (error) {
        return this.failCommit(current, error, {
          importsDirectory,
          importsCreated: false,
          renamed: false,
        })
      }

      const importsExisted = await pathExists(importsDirectory)
      if (importsExisted && !(await isDirectory(importsDirectory))) {
        return this.failCommit(current,
          new WorkspaceImportError('bad-request', 'imports exists and is not a directory'), {
            importsDirectory,
            importsCreated: false,
            renamed: false,
          })
      }
      let importsCreated = false
      let finalPath: string | undefined
      let renamed = false
      try {
        if (!importsExisted) {
          await mkdir(importsDirectory, { recursive: true })
          importsCreated = true
        }
        const entryName = await this.uniqueEntryName(importsDirectory, current.entryName)
        finalPath = join(importsDirectory, entryName)
        await rename(current.stagingDirectory, finalPath)
        renamed = true
        await withTimeout(Promise.resolve(this.verifyCommitted(finalPath)), COMMIT_TIMEOUT_MS, 'import verification')
        await withTimeout(Promise.resolve(this.flushWorkspace()), COMMIT_TIMEOUT_MS, 'import flush')
      } catch (error) {
        return this.failCommit(current, error, {
          importsDirectory,
          importsCreated,
          finalPath,
          renamed,
        })
      }

      const result: DirectoryImportCommitResponse = {
        workspacePath: relative(this.workspaceRoot, finalPath).split(sep).join('/'),
        absolutePath: finalPath,
        fileCount: current.files.size,
        totalBytes: current.totalBytes,
      }
      // Publish the retained result *before* retiring the active mapping.
      // Cleanup below awaits real I/O; a retry that arrives in that window must
      // observe the real committed result, never `not-found`. Both map updates
      // happen in one synchronous section, so there is no gap between them.
      // Re-insert so capacity eviction treats this result as the newest entry.
      this.completed.delete(importId)
      this.completed.set(importId, { result, completedAt: Date.now() })
      this.pruneCompleted()
      this.active.delete(importId)
      // Cleanup is best-effort and may not turn a published commit into an
      // error (or delete the delivered tree if it races with a retry).
      try {
        await this.cleanupDotImports(current)
      } catch {
        // Ignore: `.imports` is private staging; the import is already real.
      }
      return result
    })
  }

  /**
   * Drop only this import's private staging; final/imports and user files stay
   * untouched.
   *
   * An abort that raced a commit joins the same queue. Once the commit has
   * published (or is publishing) the tree, abort returns `false` and deletes
   * nothing; only an import whose commit never started is removed.
   */
  async abort(importId: string): Promise<boolean> {
    if (typeof importId !== 'string' || importId.length === 0) fail('importId must be a non-empty string')
    this.pruneCompleted()
    const record = this.active.get(importId)
    if (record === undefined) {
      if (this.completed.has(importId)) return false
      throw new WorkspaceImportError('not-found', `unknown import: ${JSON.stringify(importId)}`)
    }
    if (record.state === 'active') record.state = 'aborting'
    return this.serialize(async () => {
      if (this.completed.has(importId)) return false
      const current = this.active.get(importId)
      if (current === undefined) return false
      await this.waitForWrites(current)
      this.active.delete(importId)
      await rm(current.stagingDirectory, { recursive: true, force: true })
      await this.cleanupDotImports(current)
      return true
    })
  }

  /** The retained real result of a committed import, while its retry window lasts. */
  committedResult(importId: string): DirectoryImportCommitResponse | undefined {
    return this.completedResult(importId)
  }

  /**
   * Roll back a commit that never became a success. The returned promise never
   * resolves: it rethrows the original failure after a durable cleanup, or a
   * wrapped error naming the failed rollback step. Nothing here is best-effort.
   */
  private async failCommit(
    record: ActiveImport,
    cause: unknown,
    layout: {
      readonly importsDirectory: string
      readonly importsCreated: boolean
      readonly finalPath?: string
      readonly renamed: boolean
    },
  ): Promise<never> {
    let rollbackError: unknown
    if (layout.renamed && layout.finalPath !== undefined) {
      try {
        await rm(layout.finalPath, { recursive: true, force: true })
      } catch (error) {
        rollbackError = error
      }
    }
    if (rollbackError === undefined) {
      try {
        // A renamed staging path is already gone; otherwise this removes the
        // private chunks of a commit that failed before publishing.
        await rm(record.stagingDirectory, { recursive: true, force: true })
      } catch (error) {
        rollbackError = error
      }
    }
    if (rollbackError === undefined) {
      try {
        if (layout.importsCreated) await this.removeDirectoryIfEmpty(layout.importsDirectory)
        if (record.dotImportsCreated) await this.removeDirectoryIfEmpty(record.dotImportsDirectory)
      } catch (error) {
        rollbackError = error
      }
    }
    if (rollbackError === undefined) {
      try {
        // Flush the deletion too: a verified/flushed rename must not come back
        // from the VFS/WAL after a failed commit.
        await withTimeout(Promise.resolve(this.flushWorkspace()), COMMIT_TIMEOUT_MS, 'import rollback flush')
      } catch (error) {
        rollbackError = error
      }
    }
    this.active.delete(record.importId)
    const reason = errorMessage(cause)
    if (rollbackError !== undefined) {
      throw new WorkspaceImportError('internal',
        `import commit failed (${reason}) and rollback could not be completed: ${errorMessage(rollbackError)}`)
    }
    if (cause instanceof WorkspaceImportError) throw cause
    throw new WorkspaceImportError('internal', `import commit failed: ${reason}`)
  }

  private waitForWrites(record: ActiveImport): Promise<void> {
    if (record.pendingWrites === 0) return Promise.resolve()
    return new Promise<void>((resolve) => { record.writeWaiters.push(resolve) })
  }

  private completedResult(importId: string): DirectoryImportCommitResponse | undefined {
    const completed = this.completed.get(importId)
    if (completed === undefined) return undefined
    if (completed.completedAt + COMPLETED_IMPORT_TTL_MS <= Date.now()) {
      this.completed.delete(importId)
      return undefined
    }
    return completed.result
  }

  private pruneCompleted(): void {
    const now = Date.now()
    for (const [importId, completed] of this.completed) {
      if (completed.completedAt + COMPLETED_IMPORT_TTL_MS <= now) this.completed.delete(importId)
    }
    while (this.completed.size > MAX_COMPLETED_IMPORTS) {
      const oldest = this.completed.keys().next().value
      if (oldest === undefined) break
      this.completed.delete(oldest)
    }
  }

  private requireActive(importId: string): ActiveImport {
    if (typeof importId !== 'string' || importId.length === 0) fail('importId must be a non-empty string')
    const record = this.active.get(importId)
    if (record === undefined) throw new WorkspaceImportError('not-found', `unknown import: ${JSON.stringify(importId)}`)
    return record
  }

  private async uniqueEntryName(importsDirectory: string, entryName: string): Promise<string> {
    let candidate = entryName
    for (let suffix = 2; suffix < 10_000; suffix += 1) {
      if (!(await pathExists(join(importsDirectory, candidate)))) return candidate
      candidate = `${entryName}-${suffix}`
    }
    throw new WorkspaceImportError('internal', 'could not allocate a unique import directory name')
  }

  private async cleanupDotImports(record: ActiveImport): Promise<void> {
    if (!record.dotImportsCreated) return
    await this.removeIfEmpty(record.dotImportsDirectory)
  }

  private async removeIfEmpty(directory: string): Promise<void> {
    try {
      await this.removeDirectoryIfEmpty(directory)
    } catch {
      // Best-effort cleanup only: an unrelated entry means the directory is not ours to remove.
    }
  }

  /** Like `removeIfEmpty` but a real failure is surfaced (used by rollback). */
  private async removeDirectoryIfEmpty(directory: string): Promise<void> {
    let entries: string[]
    try {
      entries = await readdir(directory)
    } catch (error) {
      if (isMissing(error)) return
      throw error
    }
    // The Worker VFS publishes no rmdir; its recursive rm is safe here because
    // readdir just proved this directory empty.
    if (entries.length === 0) await rm(directory, { recursive: true, force: true })
  }

  private serialize<T>(work: () => Promise<T>): Promise<T> {
    const next = this.commitQueue.then(work, work)
    this.commitQueue = next.then(() => undefined, () => undefined)
    return next
  }
}
