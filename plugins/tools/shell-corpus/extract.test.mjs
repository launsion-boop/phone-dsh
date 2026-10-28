// SPDX-License-Identifier: MIT
/**
 * Tests for the session-log extractor and its anonymisation rules.
 */

import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { anonymizeCommand, stripHomePrefixes, stripLongLiterals } from './anonymize.mjs'
import { commandFromArguments, extractSessionCommands, formatCorpus } from './extract.mjs'

const EXTRACT_PATH = fileURLToPath(new URL('./extract.mjs', import.meta.url))

/** Build a home-directory-looking path without spelling one in this file. */
function homePath(...components) {
  return ['', ...components].join('/')
}

test('long quoted literals are replaced, short ones survive', () => {
  const long = 'x'.repeat(50)
  const command = `echo '${long}' "short"`
  assert.equal(anonymizeCommand(command), "echo '<redacted>' \"short\"")
  assert.equal(anonymizeCommand(`TOKEN="${long}"`), 'TOKEN="<redacted>"')
})

test('a literal of exactly the limit is kept', () => {
  const atLimit = 'y'.repeat(40)
  assert.equal(stripLongLiterals(`echo '${atLimit}'`), `echo '${atLimit}'`)
  assert.equal(stripLongLiterals(`echo '${atLimit}z'`), "echo '<redacted>'")
})

test('an unterminated literal is left alone', () => {
  assert.equal(stripLongLiterals("echo 'never closed"), "echo 'never closed")
})

test('absolute paths under a home directory become $HOME', () => {
  const usersPath = homePath('Users', 'alice', 'project', 'src')
  const homePathLinux = homePath('home', 'bob', 'project')
  assert.equal(stripHomePrefixes(`cd ${usersPath} && ls`), 'cd $HOME && ls')
  assert.equal(stripHomePrefixes(`cd ${homePathLinux}`), 'cd $HOME')
})

test('a path list keeps its separator after a home root', () => {
  const usersPath = homePath('Users', 'alice', 'bin')
  assert.equal(stripHomePrefixes(`export PATH=${usersPath}:/usr/bin`), 'export PATH=$HOME:/usr/bin')
})

test('the current user home directory is replaced', () => {
  const home = homedir()
  if (home === '/') return
  assert.equal(stripHomePrefixes(`cat ${home}/notes.txt`), 'cat $HOME')
})

test('paths that merely contain home are not rewritten', () => {
  assert.equal(stripHomePrefixes('cat /dsh/home/notes.txt'), 'cat /dsh/home/notes.txt')
})

test('commandFromArguments reads DSH objects, JSON strings and raw commands', () => {
  assert.equal(commandFromArguments({ command: 'ls -la' }), 'ls -la')
  assert.equal(commandFromArguments('{"command":"git status"}'), 'git status')
  assert.equal(commandFromArguments('echo raw'), 'echo raw')
  assert.equal(commandFromArguments({ description: 'no command' }), undefined)
  assert.equal(commandFromArguments(''), undefined)
})

test('extractor reads v3 content blocks, ptc dispatches and function calls', () => {
  const long = 'z'.repeat(60)
  const lines = [
    JSON.stringify({
      type: 'assistant/message',
      data: {
        message: {
          content: [
            { type: 'reasoning', text: 'not a command' },
            { type: 'tool-call', name: 'bash', arguments: { command: 'ls -la' } },
            { type: 'tool-call', name: 'write', arguments: { path: 'x.txt' } },
          ],
        },
      },
    }),
    JSON.stringify({
      type: 'tool/ptc-dispatch',
      data: { name: 'bash', arguments: { command: `echo '${long}'` } },
    }),
    JSON.stringify({ type: 'function_call', name: 'bash', arguments: '{"command":"git status"}' }),
    JSON.stringify({ function: { name: 'bash', arguments: '{"command":"pwd"}' } }),
    'not JSON at all',
  ]
  const commands = extractSessionCommands(lines.join('\n'))
  assert.deepEqual(commands, ['ls -la', "echo '<redacted>'", 'git status', 'pwd'])
})

test('extractor ignores a bash call nested only inside an arguments string', () => {
  const code = 'await tools.bash({ command: "rm -rf /" })'
  const line = JSON.stringify({
    type: 'tool-call',
    name: 'run_code',
    arguments: JSON.stringify({ code }),
  })
  assert.deepEqual(extractSessionCommands(line), [])
})

test('extractor de-duplicates identical commands', () => {
  const record = JSON.stringify({ type: 'tool-call', name: 'bash', arguments: { command: 'ls' } })
  assert.deepEqual(extractSessionCommands(`${record}\n${record}`), ['ls'])
})

test('formatCorpus writes source-tagged JSONL', () => {
  assert.equal(formatCorpus(['ls']), '{"cmd":"ls","source":"session"}\n')
})

test('extract CLI writes an anonymised corpus', () => {
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-extract-'))
  try {
    const long = 'a'.repeat(64)
    const home = homePath('Users', 'example', 'private')
    const sessionPath = join(directory, 'session.jsonl')
    const outPath = join(directory, 'corpus.jsonl')
    writeFileSync(
      sessionPath,
      `${JSON.stringify({
        type: 'assistant/message',
        data: {
          message: {
            content: [{ type: 'tool-call', name: 'bash', arguments: { command: `cd ${home} && echo '${long}'` } }],
          },
        },
      })}\n`,
    )
    const result = spawnSync(process.execPath, [EXTRACT_PATH, '--out', outPath, sessionPath], { encoding: 'utf8' })
    assert.equal(result.status, 0, result.stderr)
    const line = readFileSync(outPath, 'utf8').trim()
    assert.deepEqual(JSON.parse(line), { cmd: "cd $HOME && echo '<redacted>'", source: 'session' })
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('extract CLI rejects a missing session file', () => {
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-extract-'))
  try {
    const result = spawnSync(
      process.execPath,
      [EXTRACT_PATH, '--out', join(directory, 'nope.jsonl'), join(directory, 'missing.jsonl')],
      { encoding: 'utf8' },
    )
    assert.equal(result.status, 1)
    assert.match(result.stderr, /cannot read/)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})
