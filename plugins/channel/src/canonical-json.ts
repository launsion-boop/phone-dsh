// SPDX-License-Identifier: MIT
/**
 * Canonical JSON (D5, channel.md §5): UTF-8 with no insignificant whitespace,
 * member names sorted by Unicode code point, `/` never escaped, integers only,
 * and no duplicate member names. Strings are emitted literally except for the
 * escapes JSON requires.
 * @module @phone-dsh/dsh-channel/canonical-json
 */

/** A value that canonical JSON refuses to encode. */
export class CanonicalJsonError extends TypeError {
  constructor(message: string) {
    super(message)
    this.name = 'CanonicalJsonError'
  }
}

/** Compare two strings by Unicode code point, not by UTF-16 code unit. */
export function compareByCodePoint(left: string, right: string): number {
  const leftIterator = left[Symbol.iterator]()
  const rightIterator = right[Symbol.iterator]()
  for (;;) {
    const leftNext = leftIterator.next()
    const rightNext = rightIterator.next()
    if (leftNext.done === true || rightNext.done === true) {
      if (leftNext.done === rightNext.done) return 0
      return leftNext.done === true ? -1 : 1
    }
    const difference = leftNext.value.codePointAt(0)! - rightNext.value.codePointAt(0)!
    if (difference !== 0) return difference
  }
}

/**
 * Encode a JSON value canonically.
 * @param value - JSON value; `bigint` is accepted as an integer and emitted as decimal digits.
 * @throws {CanonicalJsonError} On a non-integer number, a non-finite number, a
 *   circular structure, or a value that has no JSON representation.
 */
export function canonicalStringify(value: unknown): string {
  return encode(value, new Set())
}

function encode(value: unknown, stack: Set<object>): string {
  if (value === null) return 'null'
  switch (typeof value) {
    case 'boolean':
      return value ? 'true' : 'false'
    case 'string':
      return encodeString(value)
    case 'number':
      return encodeNumber(value)
    case 'bigint':
      return value.toString(10)
    case 'object':
      return encodeObject(value, stack)
    default:
      throw new CanonicalJsonError(`canonical JSON cannot encode a ${typeof value}`)
  }
}

function encodeNumber(value: number): string {
  if (!Number.isFinite(value)) throw new CanonicalJsonError('canonical JSON rejects non-finite numbers')
  if (!Number.isInteger(value)) throw new CanonicalJsonError('canonical JSON accepts integers only')
  if (!Number.isSafeInteger(value)) throw new CanonicalJsonError('canonical JSON integers must be exact')
  if (Object.is(value, -0)) throw new CanonicalJsonError('canonical JSON rejects -0')
  return String(value)
}

function encodeString(value: string): string {
  // JSON.stringify escapes exactly the characters JSON requires, keeps `/`
  // unescaped and emits non-ASCII literally.
  return JSON.stringify(value)
}

function encodeObject(value: object, stack: Set<object>): string {
  if (stack.has(value)) throw new CanonicalJsonError('canonical JSON rejects circular structures')
  stack.add(value)
  try {
    if (Array.isArray(value)) {
      const parts: string[] = []
      for (let index = 0; index < value.length; index++) {
        parts.push(encode(value[index], stack))
      }
      return `[${parts.join(',')}]`
    }
    const keys = Object.keys(value).sort(compareByCodePoint)
    const parts: string[] = []
    for (const key of keys) {
      const member = (value as Record<string, unknown>)[key]
      parts.push(`${encodeString(key)}:${encode(member, stack)}`)
    }
    return `{${parts.join(',')}}`
  } finally {
    stack.delete(value)
  }
}
