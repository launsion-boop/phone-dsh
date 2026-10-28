// SPDX-License-Identifier: MIT
/**
 * Classify the outcome of running one corpus command in a shell runner.
 *
 * The four buckets are the ones the W5 work package needs: a command either
 * runs (`ok`), fails because the runner does not implement a shell construct
 * (`syntax-unsupported`, with the construct named), fails because a program is
 * absent (`command-missing`, with the program named), or fails for any other
 * reason (`runtime-error`).
 *
 * @module tools/shell-corpus/classify
 */

/** Constructs a runner may report as unsupported, in attribution order. */
export const CONSTRUCT_NAMES = [
  'for',
  'while',
  'if',
  'case',
  'function',
  'heredoc',
  'pipeline',
  'redirection',
  'subshell',
  'arithmetic',
  'parameter-expansion',
]

/** Shell keywords mapped onto the construct their block represents. */
const KEYWORD_CONSTRUCT = new Map([
  ['for', 'for'],
  ['select', 'for'],
  ['while', 'while'],
  ['until', 'while'],
  ['if', 'if'],
  ['then', 'if'],
  ['elif', 'if'],
  ['else', 'if'],
  ['fi', 'if'],
  ['case', 'case'],
  ['esac', 'case'],
  ['function', 'function'],
])

/** Shell syntax words that are not programs; a 127 on one is a syntax gap. */
const SHELL_SYNTAX_WORDS = new Set([
  ...KEYWORD_CONSTRUCT.keys(),
  'do',
  'done',
  '{',
  '}',
  '!',
  '[[',
  ']]',
  'time',
  'coproc',
])

/**
 * Blank quoted text while keeping the command's structure visible.
 *
 * Quoting never changes whether a pipe or a semicolon is shell syntax, so a
 * command such as `echo "a|b"` must not look like a pipeline. Escaped
 * characters are blanked too.
 *
 * @param {string} source - command text.
 * @returns {string} same-length text with quoted/escaped spans replaced by spaces.
 */
function maskQuoted(source) {
  let output = ''
  let index = 0
  while (index < source.length) {
    const character = source[index]
    if (character === "'" || character === '"') {
      const quote = character
      output += ' '
      index += 1
      while (index < source.length) {
        const next = source[index]
        if (quote === '"' && next === '\\' && index + 1 < source.length) {
          output += '  '
          index += 2
          continue
        }
        if (next === quote) {
          output += ' '
          index += 1
          break
        }
        output += next === '\n' ? '\n' : ' '
        index += 1
      }
      continue
    }
    if (character === '\\' && index + 1 < source.length) {
      output += source[index + 1] === '\n' ? ' \n' : '  '
      index += 2
      continue
    }
    output += character
    index += 1
  }
  return output
}

/**
 * Blank only single-quoted text, keeping double-quoted expansions visible.
 *
 * `$(( … ))` and `${ … }` are expanded inside double quotes, so arithmetic and
 * parameter expansion need a mask that does not hide them.
 *
 * @param {string} source - command text.
 * @returns {string} same-length text with single-quoted spans replaced by spaces.
 */
function maskSingleQuoted(source) {
  let output = ''
  let index = 0
  let inSingle = false
  while (index < source.length) {
    const character = source[index]
    if (inSingle) {
      if (character === "'") {
        inSingle = false
        output += ' '
      } else {
        output += character === '\n' ? '\n' : ' '
      }
      index += 1
      continue
    }
    if (character === "'") {
      inSingle = true
      output += ' '
      index += 1
      continue
    }
    output += character
    index += 1
  }
  return output
}

/**
 * List the shell constructs a command uses, in attribution order.
 *
 * This is deliberately a recogniser, not a parser: it only has to name the
 * construct when a runner rejected the command, and it must not be fooled by
 * the same characters inside quotes.
 *
 * @param {string} command - command text.
 * @returns {string[]} zero or more of {@link CONSTRUCT_NAMES}.
 */
export function detectConstructs(command) {
  if (typeof command !== 'string' || command.trim() === '') return []
  const code = maskQuoted(command)
  const expansions = maskSingleQuoted(command)
  const present = new Set()
  if (/\bfor\s+(?:[A-Za-z_]\w*\s+in\b|\(\(|[A-Za-z_]\w*\s*;)/.test(code)) present.add('for')
  if (/\b(?:while|until)\b/.test(code)) present.add('while')
  if (/\bif\b/.test(code)) present.add('if')
  if (/\bcase\b/.test(code)) present.add('case')
  if (
    /\bfunction\s+[A-Za-z_]\w*\s*[({]/.test(code)
    || /(?:^|[;&|\n])\s*[A-Za-z_]\w*\s*\(\s*\)\s*\{/m.test(code)
  ) present.add('function')
  if (/(?<!<)<<(?!<)-?\s*['"]?[A-Za-z_][\w.-]*/.test(command)) present.add('heredoc')
  if (/(?<!\|)\|(?!\|)/.test(code)) present.add('pipeline')
  if (/>>|>(?![>=])|<(?![<(])/.test(code)) present.add('redirection')
  if (/(?<![$\w(])\((?!\()/.test(code.replace(/\$\(\(/g, '    '))) present.add('subshell')
  if (/\$\(\(/.test(expansions) || /(?:^|[;&|(\n])\s*\(\(/.test(code)) present.add('arithmetic')
  if (/\$\{/.test(expansions)) present.add('parameter-expansion')
  return CONSTRUCT_NAMES.filter((name) => present.has(name))
}

/**
 * Map a missing shell keyword onto the construct it belongs to.
 *
 * @param {string} program - the name the runner could not find.
 * @param {string} command - the whole command line.
 * @returns {string | undefined} the construct, when the name is shell syntax.
 */
function keywordConstruct(program, command) {
  const mapped = KEYWORD_CONSTRUCT.get(program)
  if (mapped !== undefined) return mapped
  if (program === 'do' || program === 'done') {
    return detectConstructs(command).find((name) => name === 'for' || name === 'while')
      ?? (/\b(?:while|until)\b/.test(command) ? 'while' : undefined)
  }
  if (SHELL_SYNTAX_WORDS.has(program)) return detectConstructs(command)[0] ?? 'unknown'
  return undefined
}

/**
 * Read the first program a runner reported as absent.
 *
 * @param {string} stderr - runner diagnostics.
 * @returns {string | undefined} the program name.
 */
export function parseMissingProgram(stderr) {
  if (typeof stderr !== 'string') return undefined
  // `bash: git: command not found`, `bash: line 1: git: command not found`
  // and just-bash-style `command not found: git` all name the same fact.
  for (const match of stderr.matchAll(/^(?:bash: )?(?:line \d+: )?(.+?): command not found$/gm)) {
    if (match[1] !== undefined && match[1] !== '') return match[1]
  }
  const other = /^command not found: (.+)$/m.exec(stderr)
  if (other?.[1] !== undefined) return other[1].trim()
  // `ln: not available in the worker host` from the runtime's stub programs.
  const unavailable = /^([\w.-]+): not available in the worker host$/m.exec(stderr)
  if (unavailable?.[1] !== undefined) return unavailable[1]
  return undefined
}

/**
 * First non-empty line of a diagnostic, capped for a report table.
 *
 * @param {unknown} value - error or stderr text.
 * @returns {string} one-line detail.
 */
export function firstLine(value) {
  const text = typeof value === 'string' ? value : String(value ?? '')
  const line = text.split(/\r?\n/).map((entry) => entry.trim()).find((entry) => entry !== '') ?? ''
  return line.length > 240 ? `${line.slice(0, 237)}...` : line
}

/** Strip leading assignments and whitespace from a command line. */
function firstWord(command) {
  const text = command.replace(/^\s+/, '')
  let current = text
  for (;;) {
    const assignment = /^[A-Za-z_]\w*=[^\s]+\s*/.exec(current)
    if (assignment === null) break
    current = current.slice(assignment[0].length)
  }
  const re = /^([^\s;&|()]+)/
  const match = re.exec(current)
  return match?.[1] ?? ''
}

/**
 * Classify one runner result.
 *
 * @param {string} command - the command that ran.
 * @param {{exitCode?: number, stdout?: string, stderr?: string, error?: unknown,
 *   syntaxConstruct?: string, missingProgram?: string}} result - runner outcome.
 * @returns {{status: 'ok'|'syntax-unsupported'|'command-missing'|'runtime-error', construct?: string, program?: string, detail?: string}} classification.
 */
export function classifyResult(command, result) {
  if (result === null || typeof result !== 'object') {
    return { status: 'runtime-error', detail: 'runner returned no result' }
  }
  if (result.error !== undefined) {
    return { status: 'runtime-error', detail: firstLine(result.error) || 'runner error' }
  }
  // A runner may know the construct or the missing program from its own
  // parser and report it structurally instead of only on stderr.
  if (typeof result.syntaxConstruct === 'string' && result.syntaxConstruct !== '') {
    return { status: 'syntax-unsupported', construct: result.syntaxConstruct }
  }
  if (typeof result.missingProgram === 'string' && result.missingProgram !== '') {
    const construct = keywordConstruct(result.missingProgram, command)
    return construct === undefined
      ? { status: 'command-missing', program: result.missingProgram }
      : { status: 'syntax-unsupported', construct }
  }
  const exitCode = Number.isFinite(result.exitCode) ? result.exitCode : 1
  const stderr = typeof result.stderr === 'string' ? result.stderr : ''
  // A missing program anywhere in a pipeline still leaves the pipeline status
  // equal to its last stage, so the diagnostics are checked before the exit
  // status: `curl ... | head` reports 0 while `curl` never ran.
  const missing = parseMissingProgram(stderr)
  if (missing !== undefined) {
    const construct = keywordConstruct(missing, command)
    if (construct !== undefined) return { status: 'syntax-unsupported', construct }
    return { status: 'command-missing', program: missing }
  }
  if (/syntax error|parse error/i.test(stderr)) {
    return { status: 'syntax-unsupported', construct: detectConstructs(command)[0] ?? 'unknown' }
  }
  if (exitCode === 0) return { status: 'ok' }
  if (exitCode === 127) {
    const program = firstWord(command)
    const construct = keywordConstruct(program, command)
    if (construct !== undefined) return { status: 'syntax-unsupported', construct }
    if (program !== '') return { status: 'command-missing', program }
  }
  return { status: 'runtime-error', detail: firstLine(stderr) || `exit ${String(exitCode)}` }
}
