// SPDX-License-Identifier: MIT
/**
 * Host half: the `phone` Remote namespace that publishes a bounded directory
 * import into the *existing* session workspace.
 *
 * Every call is scoped to a live DSH session. The session header's `cwd` (or
 * the sandbox policy root when the header has none) is the only workspace this
 * plugin writes; no second workspace, session or filesystem authority exists.
 * Final verification goes through `ctx.fs.resolve` + `ctx.fs.stat`, so a
 * success is observed by the same filesystem the Files tree reads.
 *
 * @module @phone-dsh/dsh-phone-directory-import/remote
 */

import type { Context } from '@deepseek-ai/cordis'
import { Remote, RemoteError, TypertRemoteService } from '@deepseek-ai/dsh-typert-protocol'
import type { SessionId } from '@deepseek-ai/dsh-session/types'
import type {} from '@deepseek-ai/dsh-fs'
import type {} from '@deepseek-ai/dsh-sandbox-policy'
import type {} from '@deepseek-ai/dsh-session'
import {
  COMPLETED_IMPORT_TTL_MS,
  MAX_COMPLETED_IMPORTS,
  WorkspaceImportError,
  WorkspaceImportService,
} from './import-service.ts'
import type {
  DirectoryImportAbortRequest,
  DirectoryImportAbortResponse,
  DirectoryImportBeginRequest,
  DirectoryImportBeginResponse,
  DirectoryImportCommitRequest,
  DirectoryImportCommitResponse,
  DirectoryImportWriteRequest,
  DirectoryImportWriteResponse,
} from './types.ts'

interface ActiveRoute {
  readonly service: WorkspaceImportService
  readonly sessionId: string
}

/**
 * A real commit result retained after the active route is retired. The session
 * id keeps the two-phase result owned by the session that created it; the
 * bounded TTL/capacity mirrors the service's completed cache so a retry inside
 * the promised window sees the same success instead of `session/not-found`.
 */
interface CompletedRoute {
  readonly sessionId: string
  readonly result: DirectoryImportCommitResponse
  readonly expiresAt: number
}

/**
 * Active and completed routes are deliberately separate. A commit keeps its
 * real result for the retry window, but a finished import must not consume an
 * active slot: otherwise filling the active cap with old, still-open imports
 * would evict the route that *just* committed before its retry arrives.
 *
 * Completed entries use the same TTL and capacity as `WorkspaceImportService`;
 * the cache stores only the four result fields, never file bytes. Like the
 * service cache this is process-local on purpose: after a Worker restart a
 * retry reports the honest not-found instead of inventing a success. Restart
 * recovery is not claimed here and would have to read the existing VFS.
 */
export const MAX_ACTIVE_IMPORT_ROUTES = 512

/**
 * Active routes are capped so begin gets explicit backpressure instead of
 * growing process state without bound. Completed routes have their own cap;
 * they never evict active work and active work never evicts a fresh success.
 */
type RemoteMethodName = 'importBegin' | 'importWrite' | 'importCommit' | 'importAbort'
type SessionScopedRequest = { readonly sessionId: string }

function badRequest(message: string): never {
  throw new RemoteError('gateway/bad-request', message, {})
}

function requireObject(request: unknown): Record<string, unknown> {
  if (typeof request !== 'object' || request === null || Array.isArray(request)) {
    badRequest('request must be an object')
  }
  return request as Record<string, unknown>
}

function requireString(request: Record<string, unknown>, field: string): string {
  const value = request[field]
  if (typeof value !== 'string' || value.length === 0) badRequest(`${field} must be a non-empty string`)
  return value
}

/** Phone-only directory import over the session's existing workspace. */
export class PhoneDirectoryImportRemote extends TypertRemoteService {
  static inject = ['sessions', 'sandboxPolicy', 'fs', 'typert']

  /** Live imports only; a successful commit retires its route here. */
  private readonly routes = new Map<string, ActiveRoute>()
  /** Real results kept for the bounded retry window, owned by their session. */
  private readonly completedRoutes = new Map<string, CompletedRoute>()
  private readonly services = new Map<string, WorkspaceImportService>()

  constructor(ctx: Context) {
    super(ctx, 'phoneDirectoryImportRemote', { namespace: 'phone' })
  }

  /**
   * Validate the manifest and create the Worker-side staging directory.
   *
   * Active routes are bounded. `begin` is the backpressure point: beyond the
   * cap the Worker refuses new work with an explicit busy error instead of
   * silently evicting another import's staging state.
   */
  async importBegin(request: DirectoryImportBeginRequest): Promise<DirectoryImportBeginResponse> {
    this.pruneRoutes()
    const raw = requireObject(request)
    const sessionId = requireString(raw, 'sessionId')
    if (this.routes.size >= MAX_ACTIVE_IMPORT_ROUTES) {
      throw new RemoteError('gateway/bad-request',
        `directory import is busy: ${this.routes.size} active imports`, {})
    }
    const service = this.serviceFor(sessionId)
    try {
      const importId = await service.begin(request)
      // Concurrent begins can all pass the check above before their awaits
      // resolve. Re-check after staging exists and never exceed the cap; the
      // losing begin rolls back its private staging through the service.
      if (this.routes.size >= MAX_ACTIVE_IMPORT_ROUTES) {
        await service.abort(importId).catch(() => {})
        throw new RemoteError('gateway/bad-request', 'directory import is busy: active import limit reached', {})
      }
      this.routes.set(importId, { service, sessionId })
      return { importId }
    } catch (error) {
      this.rethrow(error, sessionId)
    }
  }

  /** Append one base64 chunk to the manifest path. */
  async importWrite(request: DirectoryImportWriteRequest): Promise<DirectoryImportWriteResponse> {
    const raw = requireObject(request)
    if (raw.v !== 1) badRequest('importWrite request.v must be 1')
    const sessionId = requireString(raw, 'sessionId')
    const importId = requireString(raw, 'importId')
    requireString(raw, 'path')
    const offset = raw.offset
    if (!Number.isSafeInteger(offset) || (offset as number) < 0) badRequest('offset must be a non-negative safe integer')
    const dataBase64 = requireString(raw, 'dataBase64')
    const route = this.activeRoute(importId, sessionId)
    try {
      return await route.service.write(importId, raw.path as string, offset as number, dataBase64)
    } catch (error) {
      this.rethrow(error, sessionId)
    }
  }

  /**
   * Publish the staged tree, verify it through `ctx.fs`, then flush the VFS.
   *
   * On success the active route is retired and the real result moves into a
   * separate bounded completed cache. Re-inserting the entry refreshes its
   * order and the prune step never drops the entry that just finished, so an
   * RPC retry (or a concurrent duplicate) receives this exact result even when
   * the completed cache was full before the commit finished.
   */
  async importCommit(request: DirectoryImportCommitRequest): Promise<DirectoryImportCommitResponse> {
    this.pruneRoutes()
    const raw = requireObject(request)
    if (raw.v !== 1) badRequest('importCommit request.v must be 1')
    const sessionId = requireString(raw, 'sessionId')
    const importId = requireString(raw, 'importId')
    const cached = this.completedResult(importId, sessionId)
    if (cached !== undefined) return cached
    const route = this.activeRoute(importId, sessionId)
    try {
      const result = await route.service.commit(importId)
      this.recordCompleted(importId, route.sessionId, result)
      return result
    } catch (error) {
      // A commit that already published and cached its real result is a
      // success even if a neighbouring await happened to throw. Returning the
      // service's retained result here keeps a delivered `imports/<name>` from
      // being reported as `session/not-found` and prevents a duplicate import.
      const completed = route.service.committedResult(importId)
      if (completed !== undefined) {
        this.recordCompleted(importId, route.sessionId, completed)
        return completed
      }
      // The service self-cleans a failed commit, so no retry can succeed for
      // this route. Drop it instead of retaining dead work forever.
      this.routes.delete(importId)
      this.rethrow(error, sessionId)
    }
  }

  /**
   * Discard only the private staging directory of this import.
   *
   * If a commit won the point of no return, the service returns `false` and
   * this method reports `{aborted:false}` without deleting the published tree.
   * A completed import is never deleted by a late abort.
   */
  async importAbort(request: DirectoryImportAbortRequest): Promise<DirectoryImportAbortResponse> {
    this.pruneRoutes()
    const raw = requireObject(request)
    if (raw.v !== 1) badRequest('importAbort request.v must be 1')
    const sessionId = requireString(raw, 'sessionId')
    const importId = requireString(raw, 'importId')
    if (this.completedResult(importId, sessionId) !== undefined) return { aborted: false }
    const route = this.activeRoute(importId, sessionId)
    try {
      const aborted = await route.service.abort(importId)
      if (aborted) {
        this.routes.delete(importId)
      } else {
        // The commit won while abort waited on the transaction queue. Keep the
        // real result so a commit retry still returns success.
        const result = route.service.committedResult(importId)
        if (result !== undefined) this.recordCompleted(importId, route.sessionId, result)
      }
      return { aborted }
    } catch (error) {
      this.routes.delete(importId)
      this.rethrow(error, sessionId)
    }
  }

  private serviceFor(sessionId: string): WorkspaceImportService {
    const workspaceRoot = this.workspaceRoot(sessionId)
    const existing = this.services.get(workspaceRoot)
    if (existing !== undefined) return existing
    const service = new WorkspaceImportService(workspaceRoot, {
      verify: async (absolutePath) => {
        const target = await this.ctx.fs.resolve(absolutePath)
        const info = await this.ctx.fs.stat(target)
        if (info?.type !== 'directory') {
          throw new RemoteError('gateway/internal', `committed import is not a directory: ${absolutePath}`, {})
        }
      },
    })
    this.services.set(workspaceRoot, service)
    return service
  }

  private workspaceRoot(sessionId: string): string {
    const session = this.ctx.sessions.get(sessionId as SessionId)
    if (session === undefined) {
      throw new RemoteError('session/not-found', `session "${sessionId}" does not exist`, {
        sessionId: sessionId as SessionId,
      })
    }
    return session.header.cwd ?? this.ctx.sandboxPolicy.workspaceRoot
  }

  private activeRoute(importId: string, sessionId: string): ActiveRoute {
    const route = this.routes.get(importId)
    if (route === undefined || route.sessionId !== sessionId) {
      throw new RemoteError('session/not-found', `import "${importId}" does not exist`, {
        sessionId: sessionId as SessionId,
      })
    }
    return route
  }

  /** A still-valid retained commit result, or `undefined` when not completed. */
  private completedResult(importId: string, sessionId: string): DirectoryImportCommitResponse | undefined {
    const completed = this.completedRoutes.get(importId)
    if (completed === undefined) return undefined
    if (completed.sessionId !== sessionId) {
      throw new RemoteError('session/not-found', `import "${importId}" does not exist`, {
        sessionId: sessionId as SessionId,
      })
    }
    if (completed.expiresAt <= Date.now()) {
      this.completedRoutes.delete(importId)
      return undefined
    }
    return completed.result
  }

  /**
   * Retire the live route and retain its real result. Delete+set refreshes the
   * insertion order so this just-finished result is the last candidate for
   * capacity eviction; `pruneRoutes` also refuses to drop it explicitly.
   */
  private recordCompleted(importId: string, sessionId: string, result: DirectoryImportCommitResponse): void {
    this.routes.delete(importId)
    this.completedRoutes.delete(importId)
    this.completedRoutes.set(importId, {
      sessionId,
      result,
      expiresAt: Date.now() + COMPLETED_IMPORT_TTL_MS,
    })
    this.pruneRoutes(importId)
  }

  /**
   * Drop expired completed results, then enforce the completed cap oldest
   * first. Active routes are bounded at `importBegin` and are never evicted
   * here: deleting one would lose an import that may still be written.
   */
  private pruneRoutes(protectedImportId?: string): void {
    const now = Date.now()
    for (const [importId, completed] of this.completedRoutes) {
      if (importId !== protectedImportId && completed.expiresAt <= now) {
        this.completedRoutes.delete(importId)
      }
    }
    while (this.completedRoutes.size > MAX_COMPLETED_IMPORTS) {
      let evicted = false
      for (const importId of this.completedRoutes.keys()) {
        if (importId === protectedImportId) continue
        this.completedRoutes.delete(importId)
        evicted = true
        break
      }
      if (!evicted) break
    }
  }

  private rethrow(error: unknown, sessionId: string): never {
    if (error instanceof RemoteError) throw error
    if (error instanceof WorkspaceImportError) {
      switch (error.code) {
        case 'not-found':
          throw new RemoteError('session/not-found', error.message, { sessionId: sessionId as SessionId })
        case 'bad-request':
          throw new RemoteError('gateway/bad-request', error.message, {})
        case 'internal':
          throw new RemoteError('gateway/internal', error.message, {})
      }
    }
    const message = error instanceof Error ? error.message : String(error)
    throw new RemoteError('gateway/internal', message, {})
  }
}

// Node's built-in TypeScript type stripping cannot evaluate decorator syntax.
// Apply the standard Typert decorator through its initializer, exactly as the
// resident surface does, so the same Remote descriptors reach the Gateway.
function markRemoteMethod(name: RemoteMethodName): void {
  const descriptor = Object.getOwnPropertyDescriptor(PhoneDirectoryImportRemote.prototype, name)
  if (typeof descriptor?.value !== 'function') throw new TypeError(`phone directory import Remote method is missing: ${name}`)
  let initializer: ((this: PhoneDirectoryImportRemote) => void) | undefined
  const context = {
    name,
    private: false,
    static: false,
    addInitializer(fn: (this: PhoneDirectoryImportRemote) => void) { initializer = fn },
  } as ClassMethodDecoratorContext<
    PhoneDirectoryImportRemote,
    (this: PhoneDirectoryImportRemote, request: SessionScopedRequest) => unknown
  >
  const decorator = Remote({
    resources: {
      session: (...args: unknown[]) => (args[0] as SessionScopedRequest).sessionId as SessionId,
    },
  }) as unknown as (
    method: (this: PhoneDirectoryImportRemote, request: SessionScopedRequest) => unknown,
    context: ClassMethodDecoratorContext<
      PhoneDirectoryImportRemote,
      (this: PhoneDirectoryImportRemote, request: SessionScopedRequest) => unknown
    >,
  ) => void
  decorator(descriptor.value, context)
  if (initializer === undefined) throw new TypeError(`phone directory import Remote decorator did not initialize: ${name}`)
  // Typert's initializer marks the prototype; a one-level prototype object
  // gives it the same receiver shape as the class initializer contract.
  initializer.call(Object.create(PhoneDirectoryImportRemote.prototype) as PhoneDirectoryImportRemote)
}

markRemoteMethod('importBegin')
markRemoteMethod('importWrite')
markRemoteMethod('importCommit')
markRemoteMethod('importAbort')
