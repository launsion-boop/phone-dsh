// SPDX-License-Identifier: MIT
/**
 * Anonymise one `bash -c` command string before it leaves the machine.
 *
 * Two things are removed: quoted string literals longer than 40 characters
 * (inline JSON blobs, tokens, long messages) and the user-specific prefix of
 * home-directory paths. Everything else is kept exactly as the model wrote it,
 * because the corpus is only useful while the command shapes stay realistic.
 *
 * @module tools/shell-corpus/anonymize
 */

import { homedir } from 'node:os'

/** Quoted literals longer than this many characters are replaced. */
export const MAX_LITERAL_LENGTH = 40

/** Marker that takes the place of an over-long quoted literal. */
const REDACTED_LITERAL = '<redacted>'

/**
 * Replace every closed single- or double-quoted literal whose content is
 * longer than the limit with a short placeholder of the same quoting style.
 *
 * @param source - command text.
 * @param limit - maximum content length to keep.
 * @returns command text with long literals shortened.
 */
export function stripLongLiterals(source, limit = MAX_LITERAL_LENGTH) {
  let output = ''
  let index = 0
  while (index < source.length) {
    const character = source[index]
    if (character !== "'" && character !== '"') {
      output += character
      index += 1
      continue
    }
    const quote = character
    let cursor = index + 1
    let content = ''
    let closed = false
    while (cursor < source.length) {
      const next = source[cursor]
      if (quote === '"' && next === '\\' && cursor + 1 < source.length) {
        content += next + source[cursor + 1]
        cursor += 2
        continue
      }
      if (next === quote) {
        closed = true
        break
      }
      content += next
      cursor += 1
    }
    if (!closed) {
      // An unterminated literal is left alone: cutting the rest of the command
      // would hide what the model actually tried to run.
      output += source.slice(index)
      break
    }
    output += content.length > limit ? `${quote}${REDACTED_LITERAL}${quote}` : source.slice(index, cursor + 1)
    index = cursor + 1
  }
  return output
}

/**
 * Reduce every absolute path under a home directory to `$HOME`.
 *
 * The account name is not the only private part of such a path: the project
 * directories below it can name unpublished work. The whole path is therefore
 * replaced, not just its first component. Covers the current user's home
 * directory and the `Users/<name>` and `home/<name>` spellings seen in logs
 * copied from another machine.
 *
 * @param source - command text.
 * @param options - extra home directories to redact.
 * @returns command text with home-rooted paths replaced.
 */
export function stripHomePrefixes(source, options = {}) {
  const homes = new Set()
  const configured = options.homeDirectories
  if (Array.isArray(configured)) {
    for (const entry of configured) if (typeof entry === 'string' && entry !== '') homes.add(entry)
  }
  homes.add(homedir())
  const replace = () => '$HOME'
  // Generic spellings first: they also cover the current user on the two
  // common home layouts without needing to know the account name.
  let output = source.replace(/(?<![\w.-])\/(?:Users|home)\/[^\s"'`;:|&<>()]*/g, replace)
  // Longest first so a nested home path is not half-replaced by a shorter one.
  for (const home of [...homes].sort((left, right) => right.length - left.length)) {
    if (home === '/' || !output.includes(home)) continue
    const escaped = home.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    output = output.replace(new RegExp(`${escaped}(?:/[^\\s"'\`;:|&<>()]*)?`, 'g'), replace)
  }
  return output
}

/**
 * Anonymise one extracted command.
 *
 * @param {string} command - command text from a session record.
 * @param {{homeDirectories?: string[]}} [options] - extra home prefixes.
 * @returns {string} the command with private prefixes and long literals removed.
 */
export function anonymizeCommand(command, options = {}) {
  if (typeof command !== 'string') return ''
  return stripHomePrefixes(stripLongLiterals(command.trim()), options)
}
