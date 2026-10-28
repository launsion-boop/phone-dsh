// SPDX-License-Identifier: MIT
/**
 * Phone-only recovery write-open.
 *
 * G2-FIX-93: after a Worker terminates, the replacement Worker must run DSH's
 * tool-journal reconcile before the host gives up the interrupted step. The
 * only production trigger for that reconcile is
 * `sessionPersistence.open(sessionId, 'write')`: the phone profile wraps that
 * method in `session-persistence.js` and calls `toolJournal.reconcile` before
 * the handle is returned. Reading history (`session/follow`, `session/page`)
 * does not open the writer, so it cannot settle the journal.
 *
 * This route exposes exactly that write-open for the host recovery path. It
 * opens the stored session for writing, lets DSH's normal reconcile append the
 * terminal `tool/result` and journal `resolved` records, then closes the handle.
 * It never activates an Agent, never sends a prompt and therefore never makes a
 * model call. The host waits for the normal JOURNAL frames those appends emit
 * before it abandons whatever is still open.
 *
 * The route is served by the existing phone `/api` connection carrier (the
 * same launch-token/channel authentication as every other Remote call), not by
 * a new network surface. `POST /api/pdsh-recovery/resume` performs DSH's
 * session-repair first phase without publishing an Agent, so it settles an
 * interrupted turn while preserving pending inbox prompts.
 * @module @phone-dsh/dsh-surface-phone/recovery-controller
 */

import { interruptedTurnClosers } from '@deepseek-ai/dsh-session'

/** Exact shared-API path the host posts to for one recovery write-open. */
export const RECOVERY_PATH = '/api/pdsh-recovery/reconcile'
/**
 * Exact shared-API path the drain escalation posts to after terminating a
 * Worker: it opens the stored session for writing, reads the persisted log,
 * appends DSH's own `interruptedTurnClosers`, and closes the handle. It does
 * not publish or start an Agent, so a pending user prompt in the inbox is left
 * untouched; the route never prompts the model.
 */
export const RECOVERY_RESUME_PATH = '/api/pdsh-recovery/resume'
/** Largest accepted JSON body; one session id and one budget is all it carries. */
export const RECOVERY_MAX_BODY_BYTES = 4096
/**
 * Default server-side budget for one write-open. The host's post-termination
 * grace is `min(helloTimeout, 2 s)`; 1.5 s leaves room for the final handle
 * close and the response round trip while still fitting under that grace.
 */
export const RECOVERY_DEFAULT_BUDGET_MS = 1500
/** Hard upper bound for a write-open; a host-supplied budget is clamped to it. */
export const RECOVERY_MAX_BUDGET_MS = 1500
/** Default server-side budget for one resume/repair. */
export const RECOVERY_RESUME_DEFAULT_BUDGET_MS = 3000
/** Hard upper bound for the resume route, which also runs setup/teardown. */
export const RECOVERY_RESUME_MAX_BUDGET_MS = 5000
/** Smallest accepted budget; a positive deadline always beats no deadline. */
export const RECOVERY_MIN_BUDGET_MS = 1

function json(value, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
  })
}

function failure(status, code, message) {
  return json({ ok: false, error: { code, message } }, status)
}

/**
 * Validate/clamp the optional host budget. A private JSON extension: the body
 * carries `timeoutMs`; the server never trusts the host to keep it inside the
 * recovery grace.
 * @param value - raw `timeoutMs` from the request body.
 * @returns the clamped positive integer budget.
 */
function recoveryBudget(value, maximum, fallback) {
  if (value === undefined) return fallback
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) {
    throw new TypeError('recovery: timeoutMs must be a positive number')
  }
  return Math.min(maximum,
    Math.max(RECOVERY_MIN_BUDGET_MS, Math.trunc(value)))
}

/**
 * Fuse the request's cancellation with the route deadline. The timer aborts
 * the same signal every write-open/journal-ack wait receives, so a timeout
 * unwinds the real operation instead of leaving it running with the writer.
 * @param source - cancellation of the HTTP request.
 * @param timeoutMs - bounded route budget.
 * @param operation - route label (`write-open`/`resume`) for the timeout text.
 * @returns signal, timeout flag and disposer.
 */
function recoveryDeadline(source, timeoutMs, operation) {
  const controller = new AbortController()
  let timedOut = false
  const forward = () => {
    if (!controller.signal.aborted) controller.abort(source.reason)
  }
  if (source.aborted) forward()
  else source.addEventListener('abort', forward, { once: true })
  const timer = setTimeout(() => {
    timedOut = true
    controller.abort(new Error(
      `recovery ${operation} exceeded ${String(timeoutMs)} ms`))
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

/**
 * Open one stored session for writing so the mounted phone persistence wrapper
 * runs DSH's tool-journal reconcile, then close the write handle.
 *
 * @param ctx - context carrying `sessionPersistence`.
 * @param sessionId - stored session identity to reconcile.
 * @param signal - caller cancellation for the open/reconcile.
 * @returns the durable facts of the write-open.
 */
export async function reconcileSessionForRecovery(ctx, sessionId, signal) {
  if (typeof sessionId !== 'string' || sessionId === '') {
    throw new TypeError('recovery: sessionId must be a non-empty string')
  }
  signal?.throwIfAborted()
  const handle = await ctx.sessionPersistence.open(sessionId, 'write', { signal })
  let closed = false
  try {
    // The write-open wrapper runs `toolJournal.reconcile` before returning
    // this handle; on this path it has already awaited the terminal
    // `resolved` JOURNAL ack (or rejected). Close is still unconditional so a
    // timeout/abort can never leave the writer owned by a background task.
    signal?.throwIfAborted()
    await handle.close()
    closed = true
    signal?.throwIfAborted()
  } finally {
    if (!closed) await handle.close().catch(() => {})
  }
  return { sessionId, access: 'write', closed }
}

/**
 * Read and validate one recovery request body.
 * @param request - Fetch request on the recovery route.
 * @param label - operation name used in the timeout error.
 * @returns session id, optional budget and parsed body.
 */
async function recoveryRequest(request, label, maximumBudget, defaultBudget) {
  const mediaType = request.headers.get('content-type')?.split(';', 1)[0]?.trim().toLowerCase()
  if (mediaType !== 'application/json') {
    return { error: failure(415, 'recovery/content-type', 'content type must be application/json') }
  }
  let body
  try {
    const text = await request.text()
    if (Buffer.byteLength(text, 'utf8') > RECOVERY_MAX_BODY_BYTES) {
      return { error: failure(413, 'recovery/body-too-large', 'the recovery request body is too large') }
    }
    body = JSON.parse(text)
  } catch {
    return { error: failure(400, 'recovery/bad-json', 'the recovery request body is not JSON') }
  }
  if (body === null || typeof body !== 'object'
    || typeof body.sessionId !== 'string' || body.sessionId === '') {
    return { error: failure(400, 'recovery/bad-request',
      'the recovery request needs a non-empty sessionId') }
  }
  let budget
  try {
    budget = recoveryBudget(body.timeoutMs, maximumBudget, defaultBudget)
  } catch {
    return { error: failure(400, 'recovery/bad-budget',
      'timeoutMs must be a positive number of milliseconds') }
  }
  return { sessionId: body.sessionId, budget, body }
}

/**
 * Map one route failure to the same bounded response as the write-open route.
 * @param error - operation failure.
 * @param deadline - route deadline state.
 * @param request - incoming request.
 * @param budget - clamped budget.
 * @param label - operation name used in the timeout text.
 * @returns failure response.
 */
function recoveryFailure(error, deadline, request, budget, label) {
  if (deadline.timedOut()) {
    return failure(504, 'recovery/timeout',
      `the recovery ${label} did not finish within ${String(budget)} ms`
        + ' (the write handle was released)')
  }
  if (request.signal.aborted) {
    return failure(499, 'recovery/cancelled',
      `the recovery ${label} was cancelled by the request`)
  }
  const name = error !== null && typeof error === 'object' ? error.name : ''
  const message = error instanceof Error ? error.message : String(error)
  if (name === 'SessionPersistenceNotFoundError' || name === 'SessionQuerySessionNotFoundError') {
    return failure(404, 'recovery/session-not-found', message)
  }
  if (name === 'SessionAlreadyOwnedError' || name === 'SessionAlreadyExistsError') {
    return failure(409, 'recovery/session-writer-held', message)
  }
  return failure(500, 'recovery/failed', message)
}

/**
 * Close one stored session's interrupted tail turn with DSH's own repair
 * closers, without publishing an Agent.
 *
 * `AgentLoop.resume` owns the crash-recovery closers
 * (`packages/core/session/src/repair.ts`), but returning its `AgentHandle` and
 * calling `dispose()` would cancel the Agent with `keepInbox:false`, clearing
 * every queued user prompt. This route therefore performs only the durable
 * first phase of that resume: open the write handle (which also runs the
 * mounted tool-journal reconcile), read the persisted log, append
 * `interruptedTurnClosers`, and close. The inbox is never touched and no
 * model request can start.
 * @param ctx - context carrying `sessionPersistence`.
 * @param sessionId - stored session whose open tail turn must be closed.
 * @param signal - route deadline/cancellation.
 * @returns durable facts of the resume repair.
 */
export async function resumeSessionForRecovery(ctx, sessionId, signal) {
  if (typeof sessionId !== 'string' || sessionId === '') {
    throw new TypeError('recovery: sessionId must be a non-empty string')
  }
  const persistence = ctx.sessionPersistence
  if (persistence === undefined) {
    throw new Error('recovery: session persistence is unavailable')
  }
  signal?.throwIfAborted()
  const handle = await persistence.open(sessionId, 'write', {
    ...signal === undefined ? {} : { signal },
  })
  let closed = false
  let appended = 0
  try {
    const read = await handle.read(0, undefined, {
      ...signal === undefined ? {} : { signal },
    })
    const closers = interruptedTurnClosers(read.events)
    signal?.throwIfAborted()
    if (closers.length > 0) await handle.append(closers)
    appended = closers.length
    signal?.throwIfAborted()
    await handle.close()
    closed = true
  } finally {
    // A timeout/abort must release the single-writer lock; close drains the
    // routed appends. The returned value never claims success on that path.
    if (!closed) await handle.close().catch(() => {})
  }
  return { sessionId, access: 'resume', closed, appended }
}

/**
 * Register the recovery Fetch routes on the phone connection carrier.
 *
 * @param ctx - owning surface context carrying `sessionPersistence`.
 * @param connection - `HostConnectionService` the phone surface created.
 * @returns the disposer owned by the surface fiber.
 */
export function registerRecoveryRoute(ctx, connection) {
  return ctx.effect(() => {
    const disposeReconcile = connection.fetch.register({
      path: RECOVERY_PATH,
      methods: ['POST'],
      requestBody: 'buffered',
      fetch: async request => {
        const parsed = await recoveryRequest(request, 'write-open',
          RECOVERY_MAX_BUDGET_MS, RECOVERY_DEFAULT_BUDGET_MS)
        if (parsed.error !== undefined) return parsed.error
        const { sessionId, budget } = parsed
        const deadline = recoveryDeadline(request.signal, budget, 'write-open')
        try {
          return json({
            ok: true,
            value: await reconcileSessionForRecovery(ctx, sessionId, deadline.signal),
          })
        } catch (error) {
          return recoveryFailure(error, deadline, request, budget, 'write-open')
        } finally {
          deadline.dispose()
        }
      },
    })
    const disposeResume = connection.fetch.register({
      path: RECOVERY_RESUME_PATH,
      methods: ['POST'],
      requestBody: 'buffered',
      fetch: async request => {
        const parsed = await recoveryRequest(request, 'resume',
          RECOVERY_RESUME_MAX_BUDGET_MS, RECOVERY_RESUME_DEFAULT_BUDGET_MS)
        if (parsed.error !== undefined) return parsed.error
        const { sessionId, budget } = parsed
        const deadline = recoveryDeadline(request.signal, budget, 'resume')
        try {
          return json({
            ok: true,
            value: await resumeSessionForRecovery(ctx, sessionId, deadline.signal),
          })
        } catch (error) {
          return recoveryFailure(error, deadline, request, budget, 'resume')
        } finally {
          deadline.dispose()
        }
      },
    })
    return () => {
      disposeReconcile()
      disposeResume()
    }
  }, 'phone-surface: recovery write-open/resume')
}
