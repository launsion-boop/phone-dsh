// SPDX-License-Identifier: MIT
/**
 * G2-FIX-89 class gate: interpreter-invocation vectors.
 *
 * The public corpus never contained a `bash SCRIPT` / `bash -n` /
 * `bash --version` form, so the classification gate could not see the class
 * the real-model batch exposed: the bundled command read every option as a
 * script filename (`command-missing`, exit 127) and ran a script through a
 * nested interpreter (`runtime-error`, exit 126), while only the shebang path
 * worked. `corpus/interpreter-invocation.jsonl` adds those forms as a separate
 * corpus and this gate runs each one through the real Worker shell, using the
 * same runner interface and classifier `coverage.mjs` uses. A regression in
 * the class turns one of these into `command-missing` / `runtime-error`
 * instead of `ok`.
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import { JustBashRunner } from '../../shell-ext/coverage/just-bash.mjs'
import { classifyResult } from './classify.mjs'
import { parseCorpus } from './runners.mjs'

const CORPUS_URL = new URL('./corpus/interpreter-invocation.jsonl', import.meta.url)
const entries = parseCorpus(readFileSync(CORPUS_URL, 'utf8'))

/** The invocation forms the class gate must keep, as a corpus-line pattern. */
const REQUIRED_FORMS = [
  [/^bash \S+\.sh\b/u, 'bash SCRIPT'],
  [/^sh \S+\.sh\b/u, 'sh SCRIPT'],
  [/^\/bin\/bash \S+\.sh\b/u, '/bin/bash SCRIPT'],
  [/^\/usr\/bin\/bash \S+\.sh\b/u, '/usr/bin/bash SCRIPT'],
  [/^\/bin\/sh \S+\.sh\b/u, '/bin/sh SCRIPT'],
  [/^bash -n \S+\.sh\b/u, 'bash -n SCRIPT'],
  [/^bash --version$/u, 'bash --version'],
  [/^bash -c /u, 'bash -c STRING'],
  [/^bash -e -c /u, 'bash -e -c STRING'],
  [/^bash -u -c /u, 'bash -u -c STRING'],
  [/^bash -x -c /u, 'bash -x -c STRING'],
  [/^bash -eux -c /u, 'bash -eux -c STRING'],
  [/^bash -c .+ _ ARG$/u, 'bash -c STRING _ ARG'],
  [/^\/bin\/bash -c .+ _ ARG$/u, '/bin/bash -c STRING _ ARG'],
  [/^find .* -exec sh -c .* \\;$/u, 'find -exec sh -c ... {} \\;'],
  [/^find .* -exec sh -c .* \+$/u, 'find -exec sh -c ... {} +'],
]

test('the interpreter-invocation corpus covers every bash/sh form the batch reached for', () => {
  assert.ok(entries.length >= 9, `only ${entries.length} interpreter vectors`)
  for (const [pattern, form] of REQUIRED_FORMS) {
    assert.ok(entries.some(entry => pattern.test(entry.cmd)), `the corpus has no ${form} vector`)
  }
  const seen = new Set()
  for (const entry of entries) {
    assert.equal(seen.has(entry.cmd), false, `duplicate command ${entry.cmd}`)
    seen.add(entry.cmd)
    assert.equal(entry.category, 'script')
  }
})

test('every interpreter-invocation vector classifies as ok, never command-missing', async () => {
  const runner = new JustBashRunner({ env: { PDSH_SHELL_CORPUS_MODE: 'real' } })
  await runner.start()
  try {
    for (const entry of entries) {
      const result = await runner.run(entry.cmd)
      const classification = classifyResult(entry.cmd, result)
      assert.equal(
        classification.status,
        'ok',
        `${entry.cmd}: ${JSON.stringify(classification)} stdout=${JSON.stringify(result.stdout ?? '')} stderr=${JSON.stringify(result.stderr ?? '')}`,
      )
    }
  } finally {
    await runner.close()
  }
})
