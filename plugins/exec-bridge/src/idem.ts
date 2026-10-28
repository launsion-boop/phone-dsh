// SPDX-License-Identifier: MIT
/**
 * The second idempotency key of phone-dsh-v1 (exec.md §1, PLAN D10):
 *
 * ```
 * idem_key = sha256( XL_IDEMPOTENCY_KEY | 0x1F | canonical_json(argv)
 *                    | 0x1F | cwd | 0x1F | env_hash )
 * env_hash = sha256(canonical_json(env))
 * ```
 *
 * The first segment falls back to `session_id | 0x1F | turn_id | 0x1F |
 * step_id` when `XL_IDEMPOTENCY_KEY` is absent. Components are hashed as bytes,
 * not text, so the separators are single `0x1F` bytes.
 * @module @phone-dsh/dsh-exec-bridge/idem
 */

import { createHash } from 'node:crypto'
import { canonicalStringify } from '@phone-dsh/dsh-channel/canonical-json'
import { currentToolCall } from './call-context.ts'
import type { ToolCallContext } from './call-context.ts'

/** Environment map in wire form: strings set, `null` unsets. */
export type ExecEnv = Readonly<Record<string, string | null>>

/** Everything the fallback first segment needs. */
export interface IdemKeyFacts {
  /** `XL_IDEMPOTENCY_KEY`; when present it wins over the session fallback. */
  readonly key?: string | undefined
  readonly sessionId?: string | undefined
  readonly turnId?: string | undefined
  readonly stepId?: string | undefined
}

/** Lowercase hex sha256 of the UTF-8 bytes of a string. */
export function sha256Hex(value: string): string {
  return createHash('sha256').update(value, 'utf8').digest('hex')
}

/** Canonical JSON array of argv (D5), exactly as it appears in `env_hash`/`idem_key`. */
export function canonicalArgv(argv: readonly string[]): string {
  return canonicalStringify([...argv])
}

/** Lowercase hex sha256 of the canonical JSON of the env object (absent env = `{}`). */
export function envHash(env: ExecEnv | undefined): string {
  const normalized: Record<string, string | null> = {}
  for (const [key, value] of Object.entries(env ?? {})) normalized[key] = value ?? null
  return sha256Hex(canonicalStringify(normalized))
}

/** The first segment of the derivation. */
export function identitySegment(facts: IdemKeyFacts): string {
  if (facts.key !== undefined && facts.key !== '') return facts.key
  if (facts.sessionId === undefined || facts.sessionId === '') {
    throw new Error('idem_key needs XL_IDEMPOTENCY_KEY or a session_id for the fallback identity')
  }
  if (facts.turnId === undefined || facts.stepId === undefined) {
    throw new Error('idem_key fallback needs turn_id and step_id from the tool-call context')
  }
  return `${facts.sessionId}\u001f${facts.turnId}\u001f${facts.stepId}`
}

/**
 * Derive the 64-lowercase-hex exec idempotency key.
 * @param argv - exact program argv.
 * @param cwd - exact absolute request cwd, not normalized.
 * @param env - the request env (including `XL_IDEMPOTENCY_KEY` when injected).
 * @param facts - identity facts; `key` wins, otherwise session/turn/step.
 * @returns 64 lowercase hex characters.
 */
export function deriveIdemKey(argv: readonly string[], cwd: string, env: ExecEnv | undefined, facts: IdemKeyFacts): string {
  const material = [
    identitySegment(facts),
    canonicalArgv(argv),
    cwd,
    envHash(env),
  ].join('\u001f')
  return sha256Hex(material)
}

/** Derive from the ambient tool-call context (the normal path inside a tool). */
export function idemKeyFromContext(argv: readonly string[], cwd: string, env: ExecEnv | undefined, context: ToolCallContext | undefined = currentToolCall()): string {
  return deriveIdemKey(argv, cwd, env, {
    key: context?.key,
    sessionId: context?.sessionId,
    turnId: context?.turnId,
    stepId: context?.stepId,
  })
}
