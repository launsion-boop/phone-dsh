// SPDX-License-Identifier: MIT
/**
 * Extract the `bash -c` command strings from DeepSeek Harness session JSONL
 * files and write an anonymised command corpus.
 *
 * The session log never leaves the user's machine: only the command strings
 * (with long string literals and home-directory prefixes removed) are written.
 * Every output record has the shape `{cmd, source: "session"}`.
 *
 * Usage:
 *   node tools/shell-corpus/extract.mjs [--out FILE] [--append] SESSION.jsonl...
 *
 * @module tools/shell-corpus/extract
 */

import { readFileSync, writeFileSync, appendFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { anonymizeCommand } from './anonymize.mjs'

/** Names under which DSH and common providers record a bash tool call. */
const TOOL_CALL_TYPES = new Set([
  'tool-call',
  'tool_call',
  'toolCall',
  'tool_use',
  'function_call',
  'tool/ptc-dispatch-start',
  'tool/ptc-dispatch',
])
const BASH_TOOL_NAMES = new Set(['bash'])

/**
 * Read the command out of a tool call's arguments.
 *
 * DSH stores an object; OpenAI-compatible logs store a JSON string; a few
 * harnesses store the command itself as the argument string.
 *
 * @param {unknown} argumentsValue - the record's `arguments`/`input` field.
 * @returns {string | undefined} the command, when one is present.
 */
export function commandFromArguments(argumentsValue) {
  if (typeof argumentsValue === 'string') {
    const text = argumentsValue.trim()
    if (text === '') return undefined
    let parsed
    try {
      parsed = JSON.parse(text)
    } catch {
      // A raw command string is still a command, not a serialized object.
      return text
    }
    return commandFromArguments(parsed)
  }
  if (argumentsValue === null || typeof argumentsValue !== 'object') return undefined
  const record = argumentsValue
  for (const key of ['command', 'cmd', 'script']) {
    const value = record[key]
    if (typeof value === 'string' && value.trim() !== '') return value
  }
  return undefined
}

/**
 * Walk one parsed JSONL record and collect bash commands from tool calls.
 *
 * @param {unknown} node - JSON value.
 * @param {string[]} found - accumulator.
 * @param {number} depth - recursion guard.
 */
function walkRecord(node, found, depth = 0) {
  if (depth > 40 || node === null || typeof node !== 'object') return
  if (Array.isArray(node)) {
    for (const item of node) walkRecord(item, found, depth + 1)
    return
  }
  const record = node
  const name = record.name
  const type = record.type
  const isToolCall = typeof type === 'string' && TOOL_CALL_TYPES.has(type)
  const hasArguments = record.arguments !== undefined || record.input !== undefined || record.args !== undefined
  // DSH records programmatic sub-dispatches as `tool/ptc-dispatch` records
  // whose `name` and `arguments` sit directly on the record, so a bash name
  // with arguments is a tool call even when the record type is not one of the
  // content-block types above.
  if ((isToolCall || hasArguments) && typeof name === 'string' && BASH_TOOL_NAMES.has(name)) {
    const command = commandFromArguments(record.arguments ?? record.input ?? record.args)
    if (command !== undefined) found.push(command)
  }
  // OpenAI-style `{"type":"function","function":{"name":"bash",...}}`.
  const fn = record.function
  if (fn !== null && typeof fn === 'object' && typeof fn.name === 'string' && BASH_TOOL_NAMES.has(fn.name)) {
    const command = commandFromArguments(fn.arguments)
    if (command !== undefined) found.push(command)
  }
  for (const value of Object.values(record)) walkRecord(value, found, depth + 1)
}

/**
 * Extract, anonymise and de-duplicate commands from session JSONL text.
 *
 * Malformed lines and non-bash tool calls are ignored instead of failing the
 * whole extraction: a session log may be truncated while a turn is running.
 *
 * @param {string} text - one or more JSONL session records.
 * @param {{homeDirectories?: string[]}} [options] - anonymisation options.
 * @returns {string[]} anonymised commands in first-seen order.
 */
export function extractSessionCommands(text, options = {}) {
  const commands = []
  const seen = new Set()
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.replace(/^\uFEFF/, '').trim()
    if (line === '') continue
    let record
    try {
      record = JSON.parse(line)
    } catch {
      continue
    }
    const found = []
    walkRecord(record, found)
    for (const command of found) {
      const anonymised = anonymizeCommand(command, options)
      if (anonymised === '' || seen.has(anonymised)) continue
      seen.add(anonymised)
      commands.push(anonymised)
    }
  }
  return commands
}

/**
 * Format extracted commands as JSONL corpus records.
 *
 * @param {string[]} commands - anonymised commands.
 * @returns {string} JSONL text, newline-terminated when non-empty.
 */
export function formatCorpus(commands) {
  return commands.map((cmd) => `${JSON.stringify({ cmd, source: 'session' })}\n`).join('')
}

/**
 * Parse the extractor command line.
 *
 * @param {string[]} argv - arguments after the script name.
 * @returns {{out: string, append: boolean, sessions: string[]}} parsed options.
 */
export function parseArguments(argv) {
  let out = 'corpus.jsonl'
  let append = false
  const sessions = []
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--out') {
      const value = argv[index + 1]
      if (value === undefined) throw new Error('--out needs a file path')
      out = value
      index += 1
      continue
    }
    if (argument === '--append') {
      append = true
      continue
    }
    if (argument === '--help' || argument === '-h') {
      return { out, append, sessions, help: true }
    }
    sessions.push(argument)
  }
  return { out, append, sessions }
}

/** Print usage to standard error. */
function usage() {
  process.stderr.write('usage: node extract.mjs [--out FILE] [--append] SESSION.jsonl...\n')
}

/**
 * CLI entry point.
 *
 * @param {string[]} argv - arguments after the script name.
 * @returns {number} process exit status.
 */
export function main(argv) {
  let parsed
  try {
    parsed = parseArguments(argv)
  } catch (error) {
    process.stderr.write(`extract: ${error instanceof Error ? error.message : String(error)}\n`)
    usage()
    return 2
  }
  if (parsed.help === true) {
    usage()
    return 0
  }
  if (parsed.sessions.length === 0) {
    usage()
    return 2
  }
  const commands = []
  const seen = new Set()
  let failures = 0
  for (const session of parsed.sessions) {
    let text
    try {
      text = readFileSync(session, 'utf8')
    } catch (error) {
      process.stderr.write(`extract: cannot read ${session}: ${error instanceof Error ? error.message : String(error)}\n`)
      failures += 1
      continue
    }
    for (const command of extractSessionCommands(text)) {
      if (seen.has(command)) continue
      seen.add(command)
      commands.push(command)
    }
  }
  const output = formatCorpus(commands)
  const out = resolve(parsed.out)
  if (parsed.append) appendFileSync(out, output)
  else writeFileSync(out, output)
  process.stdout.write(`extracted ${String(commands.length)} commands from ${String(parsed.sessions.length)} session file(s) to ${out}\n`)
  return failures === 0 ? 0 : 1
}

if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  process.exitCode = main(process.argv.slice(2))
}
