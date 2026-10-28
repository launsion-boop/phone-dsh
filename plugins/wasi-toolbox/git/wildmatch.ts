// SPDX-License-Identifier: MIT
/**
 * Shell-style glob matching over raw bytes.
 *
 * This is an independent implementation written from the documented glob
 * language git exposes for ref names and pathspecs (`*`, `?`, bracket
 * expressions, POSIX character classes and backslash quoting). It is not a
 * translation of any third-party source.
 *
 * Names are matched as bytes rather than JavaScript string units: `?` consumes
 * exactly one UTF-8 byte, so a CJK code point needs three of them. The default
 * {@link wildmatchBytes} has no notion of a path separator (`*` spans `/`); it
 * is the matcher for git's unanchored ref and default pathspec wildcards.
 * {@link wildmatchPathnameBytes} is the separate `:(glob)` mode: `*`, `?` and
 * bracket expressions stop at `/`, and `**` follows git's pathname rules. A
 * malformed pattern (unterminated class or escape) simply matches nothing
 * instead of throwing.
 * @module @phone-dsh/dsh-wasi-toolbox/git/wildmatch
 */

/** One member of a bracket expression. */
type ClassMember =
  | { readonly kind: 'byte'; readonly value: number }
  | { readonly kind: 'range'; readonly first: number; readonly last: number }
  | { readonly kind: 'posix'; readonly name: string }

/** One parsed pattern element. */
type PatternToken =
  | { readonly kind: 'star' }
  /** A double-star followed by `/`: zero or more complete path segments. */
  | { readonly kind: 'globstarSlash' }
  /**
   * A double-star followed by an escaped `/` (`**\/`): the separator is a
   * literal token, so this form has no zero-directory shortcut.
   */
  | { readonly kind: 'globstarEscapedSlash' }
  /** Trailing `**`: every remaining byte, including `/`. */
  | { readonly kind: 'globstarEnd' }
  | { readonly kind: 'question' }
  | { readonly kind: 'byte'; readonly value: number }
  | { readonly kind: 'class'; readonly negated: boolean; readonly members: readonly ClassMember[] }

const BACKSLASH = 0x5c
const HYPHEN = 0x2d
const CLOSE_BRACKET = 0x5d
const OPEN_BRACKET = 0x5b
const COLON = 0x3a
const STAR = 0x2a
const QUESTION = 0x3f
const EXCLAMATION = 0x21
const CARET = 0x5e

/** Decode the ASCII name of a POSIX class without throwing on invalid bytes. */
function asciiName(bytes: Uint8Array, start: number, end: number): string {
  let name = ''
  for (let index = start; index < end; index += 1) {
    name += String.fromCharCode(bytes[index] as number)
  }
  return name
}

function isDigit(byte: number): boolean {
  return byte >= 0x30 && byte <= 0x39
}

function isUpper(byte: number): boolean {
  return byte >= 0x41 && byte <= 0x5a
}

function isLower(byte: number): boolean {
  return byte >= 0x61 && byte <= 0x7a
}

function isAlpha(byte: number): boolean {
  return isUpper(byte) || isLower(byte)
}

function isAlnum(byte: number): boolean {
  return isAlpha(byte) || isDigit(byte)
}

function isXdigit(byte: number): boolean {
  return isDigit(byte) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
}

function isSpace(byte: number): boolean {
  return byte === 0x20 || (byte >= 0x09 && byte <= 0x0d)
}

function isBlank(byte: number): boolean {
  return byte === 0x20 || byte === 0x09
}

function isCntrl(byte: number): boolean {
  return byte <= 0x1f || byte === 0x7f
}

function isPrint(byte: number): boolean {
  return byte >= 0x20 && byte <= 0x7e
}

function isGraph(byte: number): boolean {
  return byte >= 0x21 && byte <= 0x7e
}

function isPunct(byte: number): boolean {
  return isGraph(byte) && !isAlnum(byte)
}

/** True for a POSIX class git's wildmatch knows, false for an unknown name. */
function posixMember(name: string, byte: number): boolean | undefined {
  switch (name) {
    case 'alnum': return isAlnum(byte)
    case 'alpha': return isAlpha(byte)
    case 'blank': return isBlank(byte)
    case 'cntrl': return isCntrl(byte)
    case 'digit': return isDigit(byte)
    case 'graph': return isGraph(byte)
    case 'lower': return isLower(byte)
    case 'print': return isPrint(byte)
    case 'punct': return isPunct(byte)
    case 'space': return isSpace(byte)
    case 'upper': return isUpper(byte)
    case 'xdigit': return isXdigit(byte)
    default: return undefined
  }
}

/**
 * Parse a bracket expression starting at `start` (which holds `[`).
 *
 * Returns the parsed token and the index just past its closing `]`, or
 * `undefined` for a malformed expression. A `]` immediately after `[` or
 * `[!` is a literal member, and an unterminated POSIX class or expression is
 * malformed rather than a literal `[`.
 */
function parseClass(
  bytes: Uint8Array,
  start: number,
): { readonly token: PatternToken; readonly next: number } | undefined {
  let index = start + 1
  let negated = false
  if (bytes[index] === EXCLAMATION || bytes[index] === CARET) {
    negated = true
    index += 1
  }
  const members: ClassMember[] = []
  let firstMember = true
  for (;;) {
    if (index >= bytes.length) return undefined
    const current = bytes[index] as number
    if (current === CLOSE_BRACKET && !firstMember) {
      return { token: { kind: 'class', negated, members }, next: index + 1 }
    }

    /** Read one literal byte or POSIX class, leaving `index` after it. */
    const readMember = (): ClassMember | undefined => {
      if (index >= bytes.length) return undefined
      const byte = bytes[index] as number
      if (byte === BACKSLASH) {
        index += 1
        if (index >= bytes.length) return undefined
        const escaped = bytes[index] as number
        index += 1
        return { kind: 'byte', value: escaped }
      }
      if (byte === OPEN_BRACKET && bytes[index + 1] === COLON) {
        const nameStart = index + 2
        let cursor = nameStart
        while (cursor < bytes.length && !(bytes[cursor] === COLON && bytes[cursor + 1] === CLOSE_BRACKET)) {
          cursor += 1
        }
        if (cursor + 1 >= bytes.length) {
          // No `:]` at all. Git treats the `[` as an ordinary member only when
          // a `]` exists but is not preceded by `:`; with no closer the whole
          // expression is malformed.
          const close = bytes.indexOf(CLOSE_BRACKET, nameStart)
          if (close < 0) return undefined
          index += 1
          return { kind: 'byte', value: OPEN_BRACKET }
        }
        const name = asciiName(bytes, nameStart, cursor)
        if (posixMember(name, 0) === undefined) return undefined
        index = cursor + 2
        return { kind: 'posix', name }
      }
      index += 1
      return { kind: 'byte', value: byte }
    }

    const member = readMember()
    if (member === undefined) return undefined
    // A `-` that is not the last member of the class forms a range. The first
    // endpoint was already recorded as a literal, which is what makes a
    // descending range such as `[z-a]` still match `z`.
    if (member.kind === 'byte' && bytes[index] === HYPHEN
      && index + 1 < bytes.length && bytes[index + 1] !== CLOSE_BRACKET) {
      index += 1
      let last: number
      if (bytes[index] === BACKSLASH) {
        index += 1
        if (index >= bytes.length) return undefined
        last = bytes[index] as number
        index += 1
      } else {
        last = bytes[index] as number
        index += 1
      }
      members.push(member)
      members.push({ kind: 'range', first: member.value, last })
    } else {
      members.push(member)
    }
    firstMember = false
  }
}

/**
 * Split a pathname pattern at its first wildcard or escape.
 *
 * Git matches a pathspec's literal prefix byte-for-byte before it parses the
 * wildcard remainder. That distinction is observable for `a/b**`: the prefix
 * `a/b` is consumed first, so the remainder starts with `**` and can span the
 * following slash. The prefix stops at a backslash exactly as git's
 * `simple_length` does, so an escaped `*`, `?` or `[` stays in the remainder
 * and is decoded by the parser; the globstar decision then still sees the real
 * preceding byte instead of treating the escaped wildcard as a segment start.
 */
function splitPathnamePrefix(bytes: Uint8Array): { readonly prefix: Uint8Array; readonly rest: Uint8Array } {
  const prefix: number[] = []
  let index = 0
  while (index < bytes.length) {
    const byte = bytes[index] as number
    if (byte === BACKSLASH || byte === STAR || byte === QUESTION || byte === OPEN_BRACKET) break
    prefix.push(byte)
    index += 1
  }
  return { prefix: Uint8Array.from(prefix), rest: bytes.subarray(index) }
}

/**
 * Split a pattern into tokens, or return undefined when it is malformed.
 *
 * In pathname mode a run of two or more `*` is a globstar only when it starts
 * the (post-prefix) pattern or follows `/`, and is followed by the end, `/`, or
 * an escaped `/` (`\/`). Everywhere else consecutive stars are an ordinary
 * `*`, exactly as git documents for `:(glob)`. The escaped form keeps its
 * separator as a literal token, which is what makes `**\/b` skip the
 * zero-directory shortcut of `**` followed by `/b`.
 */
function parsePattern(bytes: Uint8Array, pathname = false): PatternToken[] | undefined {
  const tokens: PatternToken[] = []
  let index = 0
  while (index < bytes.length) {
    const byte = bytes[index] as number
    if (byte === BACKSLASH) {
      index += 1
      if (index >= bytes.length) return undefined
      tokens.push({ kind: 'byte', value: bytes[index] as number })
      index += 1
    } else if (byte === STAR) {
      let next = index
      while (next < bytes.length && bytes[next] === STAR) next += 1
      const stars = next - index
      const afterSlash = index === 0 || bytes[index - 1] === 0x2f
      const escapedSlash = next + 1 < bytes.length
        && bytes[next] === BACKSLASH && bytes[next + 1] === 0x2f
      if (pathname && stars >= 2 && afterSlash
        && (next === bytes.length || bytes[next] === 0x2f || escapedSlash)) {
        if (next === bytes.length) {
          tokens.push({ kind: 'globstarEnd' })
          index = next
        } else if (bytes[next] === 0x2f) {
          tokens.push({ kind: 'globstarSlash' })
          index = next + 1
        } else {
          tokens.push({ kind: 'globstarEscapedSlash' })
          index = next + 2
        }
      } else {
        // A single `*` token is enough: matching zero or more bytes already
        // covers a run of ordinary asterisks.
        tokens.push({ kind: 'star' })
        index = next
      }
    } else if (byte === QUESTION) {
      tokens.push({ kind: 'question' })
      index += 1
    } else if (byte === OPEN_BRACKET) {
      const parsed = parseClass(bytes, index)
      if (parsed === undefined) return undefined
      tokens.push(parsed.token)
      index = parsed.next
    } else {
      tokens.push({ kind: 'byte', value: byte })
      index += 1
    }
  }
  return tokens
}

/** True when one parsed class member accepts the byte. */
function memberAccepts(member: ClassMember, byte: number): boolean {
  if (member.kind === 'byte') return member.value === byte
  if (member.kind === 'range') return byte >= member.first && byte <= member.last
  return posixMember(member.name, byte) === true
}

/** Match tokens against `text` starting at `tokenIndex`/`textIndex`. */
function matchFrom(
  tokens: readonly PatternToken[],
  text: Uint8Array,
  tokenIndex: number,
  textIndex: number,
  memo: Map<number, boolean>,
): boolean {
  const key = tokenIndex * (text.length + 1) + textIndex
  const remembered = memo.get(key)
  if (remembered !== undefined) return remembered

  let result: boolean
  if (tokenIndex === tokens.length) {
    result = textIndex === text.length
  } else {
    const token = tokens[tokenIndex] as PatternToken
    if (token.kind === 'star') {
      result = false
      for (let next = textIndex; next <= text.length; next += 1) {
        if (matchFrom(tokens, text, tokenIndex + 1, next, memo)) {
          result = true
          break
        }
      }
    } else if (textIndex >= text.length) {
      result = false
    } else {
      const byte = text[textIndex] as number
      if (token.kind === 'question') {
        result = matchFrom(tokens, text, tokenIndex + 1, textIndex + 1, memo)
      } else if (token.kind === 'byte') {
        result = token.value === byte
          && matchFrom(tokens, text, tokenIndex + 1, textIndex + 1, memo)
      } else if (token.kind === 'class') {
        let accepted = token.members.some(member => memberAccepts(member, byte))
        if (token.negated) accepted = !accepted
        result = accepted && matchFrom(tokens, text, tokenIndex + 1, textIndex + 1, memo)
      } else {
        result = false
      }
    }
  }
  memo.set(key, result)
  return result
}

/**
 * Match pathname tokens against `text` starting at a byte offset.
 *
 * This is the `WM_PATHNAME` half of the matcher, kept independent of the
 * non-pathname DP above: wildcards consume at most one segment, while the
 * globstar forms consume whole segments (`**` plus `/`), a prefix ending at
 * an escaped separator (`**\/`), or every remaining byte (trailing `**`).
 */
function matchPathFrom(
  tokens: readonly PatternToken[],
  text: Uint8Array,
  tokenIndex: number,
  textIndex: number,
  memo: Map<number, boolean>,
): boolean {
  const key = tokenIndex * (text.length + 1) + textIndex
  const remembered = memo.get(key)
  if (remembered !== undefined) return remembered

  let result: boolean
  if (tokenIndex === tokens.length) {
    result = textIndex === text.length
  } else {
    const token = tokens[tokenIndex] as PatternToken
    if (token.kind === 'globstarEnd') {
      result = true
    } else if (token.kind === 'globstarSlash') {
      // `**/` may match zero directories (git's `a/**/b` also matches
      // `a/b`), or any prefix that ends in a slash.
      result = matchPathFrom(tokens, text, tokenIndex + 1, textIndex, memo)
      if (!result) {
        for (let next = textIndex; next < text.length; next += 1) {
          if (text[next] === 0x2f && matchPathFrom(tokens, text, tokenIndex + 1, next + 1, memo)) {
            result = true
            break
          }
        }
      }
    } else if (token.kind === 'globstarEscapedSlash') {
      // `**\/` owns its escaped separator, so there is no zero-directory
      // shortcut: every candidate consumes through a real `/` first.
      result = false
      for (let next = textIndex; next < text.length; next += 1) {
        if (text[next] === 0x2f && matchPathFrom(tokens, text, tokenIndex + 1, next + 1, memo)) {
          result = true
          break
        }
      }
    } else if (token.kind === 'star') {
      result = false
      let next = textIndex
      for (;;) {
        if (matchPathFrom(tokens, text, tokenIndex + 1, next, memo)) {
          result = true
          break
        }
        if (next >= text.length || text[next] === 0x2f) break
        next += 1
      }
    } else if (textIndex >= text.length) {
      result = false
    } else {
      const byte = text[textIndex] as number
      if (token.kind === 'byte') {
        result = token.value === byte
          && matchPathFrom(tokens, text, tokenIndex + 1, textIndex + 1, memo)
      } else if (byte === 0x2f) {
        // `?` and bracket expressions never consume the path separator.
        result = false
      } else if (token.kind === 'question') {
        result = matchPathFrom(tokens, text, tokenIndex + 1, textIndex + 1, memo)
      } else {
        let accepted = token.members.some(member => memberAccepts(member, byte))
        if (token.negated) accepted = !accepted
        result = accepted && matchPathFrom(tokens, text, tokenIndex + 1, textIndex + 1, memo)
      }
    }
  }
  memo.set(key, result)
  return result
}

function startsWithBytes(bytes: Uint8Array, prefix: Uint8Array): boolean {
  if (prefix.length > bytes.length) return false
  for (let index = 0; index < prefix.length; index += 1) {
    if (bytes[index] !== prefix[index]) return false
  }
  return true
}

/**
 * Match one byte path against a `:(glob)` pattern using git's pathname rules.
 *
 * The literal prefix before the first wildcard is compared byte-for-byte and
 * consumed first, then `*`/`?`/brackets match within one path segment and `**`
 * is special only at a segment boundary (start/after `/`, before end/`/`).
 * A malformed pattern matches nothing, as it does for default pathspecs.
 */
export function wildmatchPathnameBytes(pattern: Uint8Array, text: Uint8Array): boolean {
  const { prefix, rest } = splitPathnamePrefix(pattern)
  if (!startsWithBytes(text, prefix)) return false
  const tokens = parsePattern(rest, true)
  if (tokens === undefined) return false
  return matchPathFrom(tokens, text, 0, prefix.length, new Map<number, boolean>())
}

/**
 * Match one byte string against one glob.
 *
 * The whole text must be consumed. `*` spans every byte (including `/`),
 * `?` is one byte, bracket expressions match one byte, and malformed patterns
 * match nothing. This is the shared matcher for `tag -l`, `branch --list` and
 * default (non-`:(glob)`) pathspecs.
 */
export function wildmatchBytes(pattern: Uint8Array, text: Uint8Array): boolean {
  const tokens = parsePattern(pattern)
  if (tokens === undefined) return false
  return matchFrom(tokens, text, 0, 0, new Map<number, boolean>())
}
