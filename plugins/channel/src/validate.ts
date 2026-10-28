// SPDX-License-Identifier: MIT
/**
 * Identifier, path and API-head validation from channel.md §4.9 and §6.
 * @module @phone-dsh/dsh-channel/validate
 */
import { FrameError } from './errors.ts'

const IDENTIFIER = /^[A-Za-z0-9._-]{1,64}$/
const BOOT_ID = /^[0-9a-f]{32}$/
const FENCE_OWNER = /^[A-Za-z0-9._:-]{1,64}$/
const MUTATION_PATH = /^\/dsh\/(?:home|workspace)(?:\/[^/]+)+$/
const HEADER_NAME = /^[a-z0-9!#$%&'*+.^_`|~-]+$/
const HTTP_METHOD = /^[A-Z][A-Z0-9-]*$/

/** D6 identifier: `exec_id`, `session_id`, `workspace_id` and string-shaped request ids. */
export function isValidIdentifier(value: unknown): value is string {
  return typeof value === 'string' && IDENTIFIER.test(value)
}

/** D6 boot identity: exactly 32 lowercase hexadecimal characters. */
export function isValidBootId(value: unknown): value is string {
  return typeof value === 'string' && BOOT_ID.test(value)
}

/** Fence owner grammar of channel.md §4.1. */
export function isValidFenceOwner(value: unknown): value is string {
  return typeof value === 'string' && FENCE_OWNER.test(value)
}

/** Sink scope grammar of D4 / channel.md §6. */
export function isValidMutationPath(value: unknown): value is string {
  if (typeof value !== 'string' || !MUTATION_PATH.test(value)) return false
  for (const component of value.split('/')) {
    if (component === '.' || component === '..') return false
  }
  return true
}

/** API_REQ path: an absolute path that may carry a query string. */
export function isValidApiPath(value: unknown): value is string {
  return typeof value === 'string' && value.startsWith('/')
}

/** API request method token. */
export function isValidHttpMethod(value: unknown): value is string {
  return typeof value === 'string' && HTTP_METHOD.test(value)
}

/** Lowercase HTTP header member name used by the API heads. */
export function isValidHeaderName(value: string): boolean {
  return HEADER_NAME.test(value)
}

/** Throw `BAD_PAYLOAD` when a value is not a D6 identifier. */
export function requireIdentifier(value: unknown, what: string): string {
  if (!isValidIdentifier(value)) {
    throw new FrameError('BAD_PAYLOAD', `${what} is not a D6 identifier`)
  }
  return value
}

/** Throw `BAD_PATH` when a sink path violates §6. */
export function requireMutationPath(value: unknown, what = 'path'): string {
  if (!isValidMutationPath(value)) {
    throw new FrameError('BAD_PATH', `${what} is outside /dsh/home or /dsh/workspace or has a bad component`)
  }
  return value
}

/** Throw `BAD_PAYLOAD` when a boot identity is malformed. */
export function requireBootId(value: unknown, what = 'boot_id'): string {
  if (!isValidBootId(value)) {
    throw new FrameError('BAD_PAYLOAD', `${what} must be 32 lowercase hex characters`)
  }
  return value
}
