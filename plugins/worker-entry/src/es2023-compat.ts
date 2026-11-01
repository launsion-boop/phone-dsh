// SPDX-License-Identifier: MIT
/**
 * ES2023 prelude for engines older than the DSH runtime's own baseline.
 *
 * `jsc-compat.ts` covers the platform gaps that JavaScriptCore's *platform*
 * surface has. This module covers a different class: **language/library
 * builtins** that DSH 0.2.1's npm dependencies call unconditionally, and that a
 * Chromium older than 110–111 does not have:
 *
 *  - `Array.prototype.toReversed` / `toSorted` / `toSpliced` / `with` (Chrome
 *    110, Safari 16.4): `dsh-agent-loop`, `dsh-session-format` and
 *    `dsh-goal-round-driver` call `toReversed` while opening a session.
 *  - `String.prototype.isWellFormed` / `toWellFormed` (Chrome 111, Safari 16.4):
 *    reached through `undici`'s WebIDL layer and `dsh-hmr`.
 *
 * Measured 2026-11-01: on the `android-33` image (WebView 109.0.5414.123) the
 * Worker boots and `session/create` fails with
 * `TypeError: session.snapshotEvents(...).toReversed is not a function`.
 * JavaScriptCore never showed this — Safari shipped the helpers before 17.0 —
 * which is why the JSC prelude did not carry them.
 *
 * Install order: `boot.ts` and `entry.ts` import this module immediately after
 * `jsc-compat.ts`, so both run before any DSH module evaluates. Feature-detected
 * and idempotent: Node 22 and modern engines keep every native definition.
 *
 * The implementations are the spec algorithms, generic over array-likes where
 * the builtin is generic. They are not byte-for-byte V8: they do not honour
 * `Array` subclass species (the spec's own helpers return a plain array), and
 * they do not perform the spec's observable `length` getter calls. DSH only
 * uses them on plain arrays, where the difference is unobservable.
 * @module @phone-dsh/dsh-worker-entry/es2023-compat
 */

/** The global surface this prelude patches; `globalThis` in production. */
export interface Es2023CompatScope {
  readonly Array?: { readonly prototype: Record<PropertyKey, unknown> } | undefined
  readonly String?: { readonly prototype: Record<PropertyKey, unknown> } | undefined
}

/** What one {@link installEs2023Compat} call had to add. */
export interface Es2023CompatReport {
  /** `Array.prototype.toReversed` was absent and was installed. */
  readonly arrayToReversed: boolean
  /** `Array.prototype.toSorted` was absent and was installed. */
  readonly arrayToSorted: boolean
  /** `Array.prototype.toSpliced` was absent and was installed. */
  readonly arrayToSpliced: boolean
  /** `Array.prototype.with` was absent and was installed. */
  readonly arrayWith: boolean
  /** `String.prototype.isWellFormed` was absent and was installed. */
  readonly stringIsWellFormed: boolean
  /** `String.prototype.toWellFormed` was absent and was installed. */
  readonly stringToWellFormed: boolean
}

/** `ToIntegerOrInfinity`, enough for the index arguments of these helpers. */
function toInteger(value: unknown): number {
  const number = Number(value)
  if (Number.isNaN(number)) return 0
  if (!Number.isFinite(number)) return number
  return Math.trunc(number)
}

/** Copy an array-like into a plain array, the way the helpers' spec starts. */
function copyArrayLike(this: ArrayLike<unknown>): unknown[] {
  const length = Number(this.length) >>> 0
  const out = new Array<unknown>(length)
  for (let index = 0; index < length; index += 1) out[index] = this[index]
  return out
}

/** `Array.prototype.toReversed`: a reversed copy, leaving the receiver alone. */
function toReversed(this: ArrayLike<unknown>): unknown[] {
  const source = copyArrayLike.call(this)
  const length = source.length
  const out = new Array<unknown>(length)
  for (let index = 0; index < length; index += 1) out[index] = source[length - 1 - index]
  return out
}

/** `Array.prototype.toSorted`: a sorted copy, leaving the receiver alone. */
function toSorted(this: ArrayLike<unknown>, compare?: (a: unknown, b: unknown) => number): unknown[] {
  return copyArrayLike.call(this).sort(compare)
}

/** `Array.prototype.toSpliced`: a spliced copy, leaving the receiver alone. */
function toSpliced(this: ArrayLike<unknown>, start?: number, deleteCount?: number, ...items: unknown[]): unknown[] {
  const out = copyArrayLike.call(this)
  const length = out.length
  const relative = toInteger(start)
  const actualStart = relative < 0 ? Math.max(length + relative, 0) : Math.min(relative, length)
  const skip = deleteCount === undefined
    ? length - actualStart
    : Math.min(Math.max(toInteger(deleteCount), 0), length - actualStart)
  out.splice(actualStart, skip, ...items)
  return out
}

/** `Array.prototype.with`: one replaced element, leaving the receiver alone. */
function withIndex(this: ArrayLike<unknown>, index: number, value: unknown): unknown[] {
  const out = copyArrayLike.call(this)
  const length = out.length
  const relative = toInteger(index)
  const actual = relative < 0 ? length + relative : relative
  if (actual < 0 || actual >= length) {
    throw new RangeError(`Invalid index: ${String(index)}`)
  }
  out[actual] = value
  return out
}

/** `String.prototype.isWellFormed`: true when the string has no lone surrogates. */
function isWellFormed(this: string): boolean {
  const text = String(this)
  for (let index = 0; index < text.length; index += 1) {
    const unit = text.charCodeAt(index)
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = index + 1 < text.length ? text.charCodeAt(index + 1) : Number.NaN
      if (!(next >= 0xdc00 && next <= 0xdfff)) return false
      index += 1
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false
    }
  }
  return true
}

/** `String.prototype.toWellFormed`: lone surrogates become U+FFFD. */
function toWellFormed(this: string): string {
  const text = String(this)
  let out = ''
  for (let index = 0; index < text.length; index += 1) {
    const unit = text.charCodeAt(index)
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = index + 1 < text.length ? text.charCodeAt(index + 1) : Number.NaN
      if (next >= 0xdc00 && next <= 0xdfff) {
        // Index access is provably in range (the surrogate pair check above),
        // but the compiler cannot see it, so the coalesce keeps the type honest
        // without changing the value.
        out += (text[index] ?? '') + (text[index + 1] ?? '')
        index += 1
      } else {
        out += '\ufffd'
      }
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      out += '\ufffd'
    } else {
      out += text[index]
    }
  }
  return out
}

/** Define `name` on `target` only when the engine has no such function. */
function installMethod(
  target: Record<PropertyKey, unknown> | undefined,
  name: string,
  value: (...args: never[]) => unknown,
): boolean {
  if (target === undefined) return false
  if (typeof target[name] === 'function') return false
  Object.defineProperty(target, name, { configurable: true, writable: true, value })
  return true
}

/**
 * Install the missing ES2023 helpers.
 * @param scope - Global surface to patch; `globalThis` by default.
 * @returns Which definitions this call added.
 */
export function installEs2023Compat(
  scope: Es2023CompatScope = globalThis as unknown as Es2023CompatScope,
): Es2023CompatReport {
  const array = scope.Array?.prototype
  const string = scope.String?.prototype
  return {
    arrayToReversed: installMethod(array, 'toReversed', toReversed as (...args: never[]) => unknown),
    arrayToSorted: installMethod(array, 'toSorted', toSorted as unknown as (...args: never[]) => unknown),
    arrayToSpliced: installMethod(array, 'toSpliced', toSpliced as unknown as (...args: never[]) => unknown),
    arrayWith: installMethod(array, 'with', withIndex as unknown as (...args: never[]) => unknown),
    stringIsWellFormed: installMethod(string, 'isWellFormed', isWellFormed as unknown as (...args: never[]) => unknown),
    stringToWellFormed: installMethod(string, 'toWellFormed', toWellFormed as unknown as (...args: never[]) => unknown),
  }
}

/**
 * Import-time installation. `boot.ts` and `entry.ts` import this module right
 * after `jsc-compat.ts`, so the helpers exist before any DSH module evaluates;
 * importing it again from another boot module is a no-op.
 */
export const es2023Compat: Es2023CompatReport = installEs2023Compat()
