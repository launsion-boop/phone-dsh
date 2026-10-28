// SPDX-License-Identifier: MIT
/**
 * Phone-only descendant drain before Worker teardown.
 *
 * G2-F01 exposed a teardown gap: a parent turn that was cancelled or completed
 * can leave a spawned child Agent running independently. The child owns its own
 * durable session and DSH activation, so cancelling the parent's session (or
 * stopping the Worker) does not make the child terminal. `session/cancel` is
 * scoped to one Agent and rejects a subagent-owned id as `session/agent-busy`;
 * the public scoped teardown primitive is
 * `ctx.subagents.drainDescendants([rootAgent])`, which closes admission below
 * the exact live root and disposes its descendant activations child-first.
 *
 * This route is the Worker half of that call. The host passes the exact
 * App-owned root session ids it created or prompted. The route resolves each
 * id to the exact live top-level Agent, verifies it is a root (never a
 * subagent-owned child id), and awaits the public DSH manager's
 * `drainDescendants`. It never cancels an unrelated root and never writes a
 * session record: the durable `turn/end` is DSH's own output.
 *
 * The route is served by the existing phone `/api` connection carrier (the
 * same launch-token/channel authentication as every other Remote call), not by
 * a new network surface, and it makes no model request.
 * @module @phone-dsh/dsh-surface-phone/descendant-drain-controller
 */

/** Exact shared-API path the host posts to for one scoped descendant drain. */
export const DESCENDANT_DRAIN_PATH = '/api/pdsh-descendant-drain'
/** Wire protocol recorded in every drain receipt. */
export const DESCENDANT_DRAIN_PROTOCOL = 'pdsh-descendant-drain/1'
/** Largest accepted JSON body: a bounded set of session ids and one budget. */
export const DESCENDANT_DRAIN_MAX_BODY_BYTES = 16 * 1024
/** Default server-side budget for one drain. */
export const DESCENDANT_DRAIN_DEFAULT_BUDGET_MS = 5000
/** Hard upper bound; the host still owns the outer 20 s drain window. */
export const DESCENDANT_DRAIN_MAX_BUDGET_MS = 20_000
/** Maximum exact roots one request may name. */
export const DESCENDANT_DRAIN_MAX_ROOTS = 64

/** Structured route failure with a stable code and HTTP status. */
export class DescendantDrainError extends Error {
  /**
   * @param {string} code - stable wire code (`descendant-drain/...`).
   * @param {string} message - human-readable detail.
   * @param {number} status - HTTP status the route answers.
   */
  constructor(code, message, status = 400) {
    super(message)
    this.name = 'DescendantDrainError'
    this.code = code
    this.status = status
  }
}

function json(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
  })
}

function failure(status, code, message) {
  return json({ ok: false, error: { code, message } }, status)
}

/** True for a non-empty string. */
function nonEmpty(value) {
  return typeof value === 'string' && value !== ''
}

/**
 * Validate one request body and return the exact roots plus the clamped budget.
 * A missing or empty root list is a caller bug, not a successful no-op.
 * @param {unknown} body - parsed JSON body.
 * @returns {{rootSessionIds: string[], budgetMs: number}} normalized request.
 */
export function validateDescendantDrainRequest(body) {
  if (body === null || typeof body !== 'object' || Array.isArray(body)) {
    throw new DescendantDrainError('descendant-drain/bad-request',
      'the request body must be a JSON object')
  }
  const value = /** @type {Record<string, unknown>} */ (body)
  const raw = value.sessionIds
  if (!Array.isArray(raw) || raw.length === 0) {
    throw new DescendantDrainError('descendant-drain/missing-roots',
      'sessionIds must be a non-empty array of root session ids')
  }
  if (raw.length > DESCENDANT_DRAIN_MAX_ROOTS) {
    throw new DescendantDrainError('descendant-drain/too-many-roots',
      `sessionIds may name at most ${String(DESCENDANT_DRAIN_MAX_ROOTS)} roots`)
  }
  const rootSessionIds = []
  const seen = new Set()
  for (const id of raw) {
    if (!nonEmpty(id)) {
      throw new DescendantDrainError('descendant-drain/bad-root',
        'every sessionIds entry must be a non-empty string')
    }
    if (seen.has(id)) continue
    seen.add(id)
    rootSessionIds.push(id)
  }
  const timeout = value.timeoutMs
  if (timeout !== undefined
      && (typeof timeout !== 'number' || !Number.isFinite(timeout) || timeout <= 0)) {
    throw new DescendantDrainError('descendant-drain/bad-budget',
      'timeoutMs must be a positive number of milliseconds')
  }
  const budgetMs = timeout === undefined
    ? DESCENDANT_DRAIN_DEFAULT_BUDGET_MS
    : Math.min(DESCENDANT_DRAIN_MAX_BUDGET_MS, Math.max(1, Math.trunc(timeout)))
  return { rootSessionIds, budgetMs }
}

/**
 * Fuse the request's cancellation with the route deadline.
 * @param source - cancellation of the HTTP request.
 * @param timeoutMs - bounded route budget.
 * @returns signal, timeout flag and disposer.
 */
function descendantDrainDeadline(source, timeoutMs) {
  const controller = new AbortController()
  let timedOut = false
  const forward = () => {
    if (!controller.signal.aborted) controller.abort(source.reason)
  }
  if (source.aborted) forward()
  else source.addEventListener('abort', forward, { once: true })
  const timer = setTimeout(() => {
    timedOut = true
    controller.abort(new Error(`descendant drain exceeded ${String(timeoutMs)} ms`))
  }, timeoutMs)
  timer.unref?.()
  return {
    signal: controller.signal,
    timedOut: () => timedOut,
    dispose: () => {
      clearTimeout(timer)
      source.removeEventListener('abort', forward)
    },
  }
}

/** Resolve the subagent service without requiring a second manager. */
function subagentService(ctx) {
  if (typeof ctx?.get === 'function') return ctx.get('subagents')
  return ctx?.subagents
}

/** Resolve the public subagent service or fail instead of guessing no children. */
function requireSubagentService(ctx, capability) {
  const subagents = subagentService(ctx)
  if (subagents === undefined || typeof subagents[capability] !== 'function') {
    throw new DescendantDrainError('descendant-drain/unavailable',
      `the Worker has no scoped subagent ${capability}; refusing to report a child terminal`,
      503)
  }
  return subagents
}

/**
 * Collect the descendant session ids that are live in this Worker incarnation.
 *
 * DSH cold resume reuses a child session id and its persisted header, so the
 * header `createdAt` cannot tell a live resumed child from a stale crash
 * journal. `listDescendants` reports each durable child with `activity`
 * derived from the live Session store; the Host needs exactly those ids to
 * still verify their `turn/end` when the header predates its incarnation.
 * Inactive descendants stay out: they have no resident Activation, so
 * `drainDescendants` cannot append a terminal record for them.
 *
 * A diagnostic branch means part of the durable tree was unreadable. Returning
 * a partial set would let an unknown descendant look converged, so the route
 * fails loud instead.
 *
 * @param ctx - context carrying the public `subagents` service.
 * @param roots - exact live root Agents just resolved.
 * @param signal - caller cancellation for the bounded listing.
 * @returns sorted live descendant session ids for these roots.
 */
async function liveDescendantSessionIds(ctx, roots, signal) {
  const subagents = requireSubagentService(ctx, 'listDescendants')
  const ids = new Set()
  for (const root of roots) {
    let entries
    try {
      entries = await withAbort(signal,
        () => subagents.listDescendants(root.id, signal))
    } catch (error) {
      if (error instanceof DescendantDrainError) throw error
      throw new DescendantDrainError('descendant-drain/list-failed',
        `cannot list descendants of root "${root.id}": ${String(error)}`, 500)
    }
    signal?.throwIfAborted()
    if (!Array.isArray(entries)) {
      throw new DescendantDrainError('descendant-drain/list-failed',
        `descendant listing for root "${root.id}" was not an array`, 500)
    }
    for (const entry of entries) {
      signal?.throwIfAborted()
      if (entry === null || typeof entry !== 'object') {
        throw new DescendantDrainError('descendant-drain/list-failed',
          `descendant listing for root "${root.id}" had a malformed entry`, 500)
      }
      if (entry.kind === 'diagnostic') {
        throw new DescendantDrainError('descendant-drain/list-incomplete',
          `descendant listing for root "${root.id}" is incomplete at "${String(entry.id)}"`,
          500)
      }
      if (entry.kind !== 'child') continue
      if (typeof entry.id !== 'string' || entry.id === '') {
        throw new DescendantDrainError('descendant-drain/list-failed',
          `descendant listing for root "${root.id}" had a child without an id`, 500)
      }
      if (entry.activity === 'running') ids.add(entry.id)
    }
  }
  return [...ids].sort()
}

/** Wait for one operation, but let the route deadline end the wait. */
async function withAbort(signal, operation) {
  signal?.throwIfAborted()
  let onAbort
  const aborted = new Promise((_, reject) => {
    if (signal === undefined) return
    onAbort = () => reject(signal.reason ?? new Error('descendant drain aborted'))
    signal.addEventListener('abort', onAbort, { once: true })
  })
  const running = Promise.resolve().then(operation)
  try {
    // A late settlement must not become an unhandled rejection after the
    // route has answered. The host still owns the outer fail-loud decision.
    void running.catch(() => undefined)
    return await Promise.race([running, aborted])
  } finally {
    if (signal !== undefined && onAbort !== undefined) {
      signal.removeEventListener('abort', onAbort)
    }
  }
}

/**
 * Drain the managed descendants of the exact live App-owned roots.
 *
 * A missing root is reported, not guessed: it cannot own a live activation
 * through this Worker incarnation. A live subagent-owned id is rejected with
 * `descendant-drain/not-root`; callers must never pass a child id to turn an
 * unrelated root's teardown into a global cancellation.
 *
 * @param ctx - context carrying `agents` and the public `subagents` service.
 * @param rootSessionIds - exact top-level root session ids.
 * @param signal - caller cancellation for the bounded wait.
 * @returns durable receipt facts. No session record is written here.
 */
export async function drainDescendantSessions(ctx, rootSessionIds, signal) {
  const startedAt = Date.now()
  const agents = ctx?.agents
  if (agents === undefined || typeof agents.get !== 'function') {
    throw new DescendantDrainError('descendant-drain/unavailable',
      'the Worker has no agents service', 503)
  }
  const topLevel = typeof agents.roots === 'function'
    ? new Set(agents.roots())
    : undefined
  const roots = []
  const missing = []
  for (const id of rootSessionIds) {
    signal?.throwIfAborted()
    const agent = agents.get(id)
    if (agent === undefined) {
      missing.push(id)
      continue
    }
    if (topLevel !== undefined && !topLevel.has(agent)) {
      throw new DescendantDrainError('descendant-drain/not-root',
        `session "${id}" is not a live top-level root; subagent-owned children cannot be drained directly`,
        409)
    }
    roots.push(agent)
  }
  if (roots.length === 0) {
    return {
      protocol: DESCENDANT_DRAIN_PROTOCOL,
      roots: [],
      missing,
      // No live root can own a live descendant through this incarnation. The
      // field is still present so a receipt never becomes an implicit "I know
      // no children" answer.
      descendants: [],
      durationMs: Date.now() - startedAt,
    }
  }
  const subagents = requireSubagentService(ctx, 'drainDescendants')
  // Capture the ids that are actually live *before* disposal. The manager's
  // `drainDescendants` returns void, so this public query is the authority the
  // Host uses to distinguish a cold-resumed old child from a stale journal.
  const liveBefore = await liveDescendantSessionIds(ctx, roots, signal)
  await withAbort(signal, () => subagents.drainDescendants(roots))
  signal?.throwIfAborted()
  // Re-list after the awaited disposal to cover a descendant published while
  // admission was closing. A child that is still running is returned to the
  // Host as live, never silently declared terminal.
  const liveAfter = await liveDescendantSessionIds(ctx, roots, signal)
  const descendants = [...new Set([...liveBefore, ...liveAfter])].sort()
  return {
    protocol: DESCENDANT_DRAIN_PROTOCOL,
    roots: roots.map(agent => agent.id),
    missing,
    descendants,
    durationMs: Date.now() - startedAt,
  }
}

/**
 * Register the descendant-drain Fetch route on the phone connection carrier.
 *
 * @param ctx - owning surface context carrying `agents` and `subagents`.
 * @param connection - `HostConnectionService` the phone surface created.
 * @returns the disposer owned by the surface fiber.
 */
export function registerDescendantDrainRoute(ctx, connection) {
  return ctx.effect(() => connection.fetch.register({
    path: DESCENDANT_DRAIN_PATH,
    methods: ['POST'],
    requestBody: 'buffered',
    fetch: async request => {
      const mediaType = request.headers.get('content-type')?.split(';', 1)[0]?.trim().toLowerCase()
      if (mediaType !== 'application/json') {
        return failure(415, 'descendant-drain/content-type',
          'content type must be application/json')
      }
      let body
      try {
        const text = await request.text()
        if (Buffer.byteLength(text, 'utf8') > DESCENDANT_DRAIN_MAX_BODY_BYTES) {
          return failure(413, 'descendant-drain/body-too-large',
            'the descendant drain request body is too large')
        }
        body = JSON.parse(text)
      } catch {
        return failure(400, 'descendant-drain/bad-json',
          'the descendant drain request body is not JSON')
      }
      let parsed
      try {
        parsed = validateDescendantDrainRequest(body)
      } catch (error) {
        if (error instanceof DescendantDrainError) {
          return failure(error.status, error.code, error.message)
        }
        return failure(400, 'descendant-drain/bad-request', String(error))
      }
      const deadline = descendantDrainDeadline(request.signal, parsed.budgetMs)
      try {
        return json({
          ok: true,
          value: await drainDescendantSessions(ctx, parsed.rootSessionIds, deadline.signal),
        })
      } catch (error) {
        if (deadline.timedOut()) {
          return failure(504, 'descendant-drain/timeout',
            `the scoped descendant drain did not finish within ${String(parsed.budgetMs)} ms`)
        }
        if (request.signal.aborted) {
          return failure(499, 'descendant-drain/cancelled',
            'the scoped descendant drain was cancelled by the request')
        }
        if (error instanceof DescendantDrainError) {
          return failure(error.status, error.code, error.message)
        }
        const name = error !== null && typeof error === 'object' ? error.name : ''
        const message = error instanceof Error ? error.message : String(error)
        if (name === 'SubagentError' || name === 'ACTIVATION_TEARDOWN_FAILED') {
          return failure(500, 'descendant-drain/failed', message)
        }
        return failure(500, 'descendant-drain/failed', message)
      } finally {
        deadline.dispose()
      }
    },
  }), 'phone-surface: scoped descendant drain')
}
