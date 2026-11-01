// SPDX-License-Identifier: MIT
/**
 * Integer projection for the DSH values that cross the phone mux.
 *
 * The mux response is canonical JSON (D5): integers only, no floats, no `-0`
 * (`spec/v1/channel.md` §5). That strictness is the wire contract — goldens,
 * CRC32C and four implementations share it — and this module does not relax it.
 * Some DSH fields, however, are *timing* values computed with jitter or a
 * fractional multiplication, so they are fractional by construction:
 *
 *   - `llm/retry.data.delayMs` — the local backoff wait
 *     (`initialDelayMs * 2**n * (1 - jitterRatio + 2 * jitterRatio * random())`,
 *     default jitterRatio 0.1): the first retry waits e.g. `481.7056…` ms;
 *   - `providerRetryAfterMs` on an `LlmFailure` — a provider `retry-after`
 *     converted with `Number(seconds) * 1000`, which is fractional after the
 *     multiplication (`1.005 * 1000 === 1004.9999999999999`).
 *
 * The second one is easy to miss: a failed attempt records its exact failure in
 * the durable `assistant/attempt` event, so the same fractional number also
 * rides that event's embedded stream at
 * `data.stream[i].chunk.reason.failure.providerRetryAfterMs` — and a failed
 * turn records it again in `turn/end.data.reason.error`. A phone that only
 * normalizes `llm/retry.delayMs` still aborts; that is the shape this module
 * was extended to cover.
 *
 * One float anywhere in a frame makes the canonical encoder throw, the receive
 * sink fail, and the whole turn abort as `API_ABORT reason=canonical JSON
 * accepts integers only` — turning every recoverable retry (429/5xx/transport
 * jitter) into a hard turn failure. `docs/receipts/phase0-a1-2026-10-29.json`
 * therefore decided that nested `llm/retry` `delayMs` is rounded at the phone
 * mux projection; this module is that projection, extended to the failure
 * waits that carry the same quantity.
 *
 * Rounding is deliberately scoped to lengths of time in whole milliseconds:
 * `Math.round` moves a scheduled wait by less than one millisecond, so the
 * retry still waits the length DSH chose, and the durable session log keeps the
 * exact float (the projection never writes to the log; it only shapes one wire
 * frame). Nothing else is rounded — token counts, epoch timestamps, wall-time
 * totals, costs and sampling scalars
 * (`request/header.header.config.temperature`) are either already integers or
 * semantically precise, and silently changing them would corrupt the record
 * instead of repairing the wire. A float outside this scope still fails loudly
 * at the encoder, which is the intended behaviour.
 *
 * Every rounding that changes a value is reported, so the projection can never
 * silently rewrite data: the mux bridge logs each report on the Worker console
 * stream (`mux projection rounded …`).
 * @module @phone-dsh/dsh-worker-entry/mux-projection
 */

/** One field the projection rounded, with both values, for the visibility log. */
export interface MuxProjectionRounding {
  /** Nearest enclosing DSH session-event type, e.g. `llm/retry` or `assistant/attempt`. */
  readonly eventType: string
  /** Dotted path within that event, e.g. `data.delayMs`. */
  readonly field: string
  /** Value DSH produced. */
  readonly from: number
  /** Value placed on the wire. */
  readonly to: number
}

/** Observer for one rounding; the production caller logs it. */
export type MuxProjectionReport = (rounding: MuxProjectionRounding) => void

/**
 * Timing fields per DSH session-event type, relative to the event. Only
 * scheduled waits appear here: each is a length of time in milliseconds, so
 * whole-millisecond precision is lossless for its purpose.
 */
const EVENT_TIMING_FIELDS: Readonly<Record<string, readonly (readonly string[])[]>> = {
  'llm/retry': [['data', 'delayMs']],
}

/** The provider-requested wait a failure can carry, wherever the failure is embedded. */
const FAILURE_TIMING_FIELD = 'providerRetryAfterMs'

/** Label used when a rounded field has no enclosing session event. */
const UNKNOWN_EVENT = 'dsn/value'

/**
 * Project one mux server frame (or any nested DSH value) so the canonical
 * encoder can carry it.
 * @param value - server frame, event, or any nested member of one.
 * @param report - receives one entry per round that changed a value.
 * @returns The projected value; unchanged branches keep their identity.
 */
export function projectMuxServerFrame<T>(value: T, report?: MuxProjectionReport): T {
  return project(value, { eventType: undefined, path: [] }, report) as T
}

interface WalkFrame {
  /** Nearest enclosing DSH event type, for report labels. */
  readonly eventType: string | undefined
  /** Path inside that event, for report labels. */
  readonly path: readonly (string | number)[]
}

function project(value: unknown, frame: WalkFrame, report: MuxProjectionReport | undefined): unknown {
  if (Array.isArray(value)) return projectArray(value, frame, report)
  if (!isRecord(value)) return value
  const eventType = isEvent(value) ? value['type'] as string : undefined
  const scope: WalkFrame = eventType === undefined || eventType === frame.eventType
    ? frame
    : { eventType, path: [] }
  // An `llm/retry` event carries its wait in `data.delayMs`; the failure rule
  // below reaches a different field, and each rule stays scoped to its own.
  let projected = scope.eventType === undefined ? value : projectEventFields(value, scope.eventType, report)
  // A failure's provider wait appears in `llm/retry`, in the stream an
  // `assistant/attempt` keeps, and in a failed `turn/end` reason alike.
  if (isLlmFailure(projected)) {
    projected = roundField(
      projected,
      [FAILURE_TIMING_FIELD],
      { eventType: scope.eventType ?? UNKNOWN_EVENT, path: [...scope.path, FAILURE_TIMING_FIELD] },
      report,
    )
  }
  return projectRecord(projected, scope, report)
}

function projectArray(
  value: readonly unknown[],
  frame: WalkFrame,
  report: MuxProjectionReport | undefined,
): readonly unknown[] {
  let projected: unknown[] | undefined
  for (let index = 0; index < value.length; index += 1) {
    const next = project(value[index], { ...frame, path: [...frame.path, index] }, report)
    if (next === value[index]) continue
    projected ??= [...value]
    projected[index] = next
  }
  return projected ?? value
}

function projectRecord(
  value: Record<string, unknown>,
  frame: WalkFrame,
  report: MuxProjectionReport | undefined,
): Record<string, unknown> {
  let projected: Record<string, unknown> | undefined
  for (const key of Object.keys(value)) {
    const next = project(value[key], { ...frame, path: [...frame.path, key] }, report)
    if (next === value[key]) continue
    projected ??= { ...value }
    projected[key] = next
  }
  return projected ?? value
}

/** Round this event's own timing fields, copying only the branches that change. */
function projectEventFields(
  event: Record<string, unknown>,
  eventType: string,
  report: MuxProjectionReport | undefined,
): Record<string, unknown> {
  let projected = event
  for (const path of EVENT_TIMING_FIELDS[eventType] ?? []) {
    projected = roundField(projected, path, { eventType, path }, report)
  }
  return projected
}

/** Round one nested numeric field, if it is present and fractional. */
function roundField(
  value: Record<string, unknown>,
  path: readonly (string | number)[],
  tag: { readonly eventType: string; readonly path: readonly (string | number)[] },
  report: MuxProjectionReport | undefined,
): Record<string, unknown> {
  const last = path.length - 1
  let parent = value
  for (let depth = 0; depth < last; depth += 1) {
    const segment = path[depth]
    if (segment === undefined) return value
    const next = parent[String(segment)]
    if (!isRecord(next)) return value
    parent = next
  }
  const key = path[last]
  if (key === undefined) return value
  const current = parent[String(key)]
  // Non-finite numbers are left for the canonical encoder, which rejects them
  // loudly: they are not a jitter artifact and no rounding can repair them.
  if (typeof current !== 'number' || !Number.isFinite(current)) return value
  const rounded = roundTiming(current)
  if (rounded === current && !Object.is(current, -0)) return value
  report?.({ eventType: tag.eventType, field: formatPath(tag.path), from: current, to: rounded })
  return replacePath(value, path, rounded)
}

/** Copy the object chain along `path` and set the leaf, leaving siblings shared. */
function replacePath(
  value: Record<string, unknown>,
  path: readonly (string | number)[],
  rounded: number,
): Record<string, unknown> {
  const [head, ...rest] = path
  if (head === undefined) return value
  const key = String(head)
  if (rest.length === 0) return { ...value, [key]: rounded }
  const child = value[key]
  return isRecord(child)
    ? { ...value, [key]: replacePath(child, rest, rounded) }
    : value
}

/** `data.stream[0].chunk.reason.failure.providerRetryAfterMs` */
function formatPath(path: readonly (string | number)[]): string {
  let text = ''
  for (const segment of path) {
    if (typeof segment === 'number') text += `[${String(segment)}]`
    else text += text === '' ? segment : `.${segment}`
  }
  return text
}

/**
 * Round one finite scheduled wait to whole milliseconds.
 * @param value - finite timing value in milliseconds.
 * @returns The rounded integer, normalized to `0` so `-0` never reaches the encoder.
 */
function roundTiming(value: number): number {
  const rounded = Math.round(value)
  return rounded === 0 ? 0 : rounded
}

/** A DSH session event: a string `type` plus an object `data` payload. */
function isEvent(value: Record<string, unknown>): boolean {
  return typeof value['type'] === 'string' && isRecord(value['data'])
}

/** The `LlmFailure` facts: a message, a machine-routing code, and optional timings. */
function isLlmFailure(value: Record<string, unknown>): boolean {
  return typeof value['message'] === 'string' && typeof value['code'] === 'string'
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
