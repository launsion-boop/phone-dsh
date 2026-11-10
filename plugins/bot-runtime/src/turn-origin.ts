// SPDX-License-Identifier: MIT
/**
 * The frozen turn-origin classification from `spec/bot/v1/README.md` §4.1.
 *
 * The only input is the DSH `user/message.data.source.rpcId` minted by the
 * host. Message text is never consulted. The prefix table mirrors the valid
 * vectors in `spec/bot/v1/golden/turn-origin.phone.json`; that file drives the
 * conformance tests instead of a second hand-written expectation list.
 */

export type TurnOriginKind =
  | 'user'
  | 'held'
  | 'agent'
  | 'routine'
  | 'task'
  | 'task-wake'
  | 'unknown'

export type TurnMemorySource =
  | 'user-turn'
  | 'agent-message'
  | 'routine'
  | 'task'
  | 'hidden-wake'

export interface TurnOrigin {
  readonly rpcId: string | null
  readonly kind: TurnOriginKind
  readonly hidden: boolean
  readonly held: boolean
  readonly memorySource: TurnMemorySource
}

const PREFIXES: readonly (readonly [string, TurnOriginKind])[] = [
  ['user-action:', 'user'],
  ['card-answer:', 'user'],
  ['bot-', 'user'],
  ['held:', 'held'],
  ['agent:', 'agent'],
  ['routine:', 'routine'],
  ['task-turn:', 'task'],
  ['task-settled:', 'task-wake'],
  ['task-interrupted:', 'task-wake'],
]

const UNKNOWN: TurnOrigin = Object.freeze({
  rpcId: null,
  kind: 'unknown',
  hidden: false,
  held: false,
  memorySource: 'agent-message',
})

const MEMORY_SOURCE: Readonly<Record<TurnOriginKind, TurnMemorySource>> = Object.freeze({
  user: 'user-turn',
  held: 'agent-message',
  agent: 'agent-message',
  routine: 'routine',
  task: 'task',
  'task-wake': 'hidden-wake',
  unknown: 'agent-message',
})

const HIDDEN: ReadonlySet<TurnOriginKind> = new Set(['routine', 'task', 'task-wake'])

function make(rpcId: string | null, kind: TurnOriginKind): TurnOrigin {
  return Object.freeze({
    rpcId,
    kind,
    hidden: HIDDEN.has(kind),
    held: kind === 'held',
    memorySource: MEMORY_SOURCE[kind],
  })
}

/**
 * Classify one `source.rpcId`. Prefix matching is exact, ASCII
 * case-sensitive and anchored at offset 0; the payload must contain at least
 * one non-whitespace character. Anything else is `unknown` (visible, no held
 * block, lowest-trust `agent-message`).
 */
export function resolveTurnOrigin(rpcId: unknown): TurnOrigin {
  if (typeof rpcId !== 'string') return UNKNOWN
  if (rpcId.length === 0) return make(rpcId, 'unknown')
  for (const [prefix, kind] of PREFIXES) {
    if (!rpcId.startsWith(prefix)) continue
    const payload = rpcId.slice(prefix.length)
    if (/\S/u.test(payload)) return make(rpcId, kind)
    return make(rpcId, 'unknown')
  }
  return make(rpcId, 'unknown')
}

/** The `rpcId` of one DSH message source, if it is a string. */
export function rpcIdFromSource(source: unknown): string | undefined {
  if (typeof source !== 'object' || source === null) return undefined
  const value = (source as Record<string, unknown>)['rpcId']
  return typeof value === 'string' ? value : undefined
}

/** Resolve the origin of a message-shaped object carrying `source`. */
export function turnOriginOfMessage(message: { readonly source?: unknown }): TurnOrigin {
  return resolveTurnOrigin(rpcIdFromSource(message.source))
}

/** The `user-action:` nonce, or undefined for every other request id. */
export function userActionNonce(rpcId: unknown): string | undefined {
  if (typeof rpcId !== 'string' || !rpcId.startsWith('user-action:')) return undefined
  const nonce = rpcId.slice('user-action:'.length)
  return /\S/u.test(nonce) ? nonce : undefined
}
