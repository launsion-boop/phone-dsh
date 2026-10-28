// SPDX-License-Identifier: MIT
/**
 * G2-FIX-114: the boot manifest discloses git's real trim surface.
 *
 * The model must learn before its first request that `show <rev>:<path>` is
 * supported, that `A..B`/`A...B` ranges and `show-ref` are not, and which
 * subcommands actually exist. The subcommand list must come from
 * `commandTable()` — never a hand-maintained copy in worker-entry.
 * @module @phone-dsh/dsh-plugins/tests/capability-disclosure.test
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { commandTable } from '../wasi-toolbox/git/commands.ts'
import { GIT_SUPPORTED_FORMS, GIT_TRIM_FACTS } from '../wasi-toolbox/git/capability.ts'
import { WORKER_EXECUTION_LIMITS } from '../shell-ext/src/index.ts'
import {
  buildCapabilityManifest,
  CAPABILITIES_JSON_PATH,
  type CapabilityManifestInput,
} from '../worker-entry/src/capabilities.ts'

function manifestInput(overrides: Partial<CapabilityManifestInput> = {}): CapabilityManifestInput {
  return { commands: ['bash', 'cat', 'git', 'tar'], ...overrides }
}

test('manifest.git.commands has an empty two-way difference with the real command table', () => {
  const manifest = buildCapabilityManifest(manifestInput())
  assert.ok(manifest.json.git !== undefined, 'git is in the command table, so the git section exists')
  const actual = new Set(Object.keys(commandTable()))
  const documented = new Set(manifest.json.git.commands)
  const missing = [...actual].filter(name => !documented.has(name)).sort()
  const stale = [...documented].filter(name => !actual.has(name)).sort()
  assert.deepEqual(missing, [], 'every implemented subcommand is disclosed')
  assert.deepEqual(stale, [], 'the manifest names no unimplemented subcommand')
  assert.deepEqual(manifest.json.git.commands, [...actual].sort())
})

test('AGENTS.md states the git trim facts and keeps <rev>:<path> supported', () => {
  const manifest = buildCapabilityManifest(manifestInput())
  const git = manifest.json.git
  assert.ok(git !== undefined)
  const forms = git.supported_forms.join('; ')
  assert.ok(forms.includes('<rev>:<path>'), 'the supported forms name <rev>:<path>')
  const trimmed = git.trimmed.map(fact => `${fact.note} ${fact.alternative}`).join(' ')
  assert.ok(!trimmed.includes('<rev>:<path>'), '<rev>:<path> is supported, so it is not a trim fact')
  assert.ok(trimmed.includes('A..B'), 'the range gap is disclosed')
  assert.ok(trimmed.includes('show-ref'), 'show-ref is disclosed')
  assert.deepEqual(git.trimmed.map(fact => fact.id), [
    'GIT-REVISION-RANGE',
    'GIT-SHOW-REF',
    'GIT-SHOW-ONE-REVISION',
    'GIT-LOG-GRAPH-DECORATE',
  ])
  assert.deepEqual(GIT_TRIM_FACTS.map(fact => fact.id), git.trimmed.map(fact => fact.id))

  const markdown = manifest.markdown
  assert.match(markdown, /A\.\.B/u)
  assert.match(markdown, /show-ref/u)
  assert.match(markdown, /<rev>:<path>/u)
  // The supported form must not be described as unsupported/not implemented.
  assert.doesNotMatch(markdown, /<rev>:<path>[^\n.]*(?:not supported|unsupported|not implemented)/iu)
  assert.ok(git.commands.includes('show'), 'the subcommand list is in the machine-readable document')
  assert.ok(GIT_SUPPORTED_FORMS.some(form => form.includes('<rev>:<path>')))
})

test('the manifest omits the git section when the command table does not serve git', () => {
  const manifest = buildCapabilityManifest(manifestInput({ commands: ['bash', 'cat', 'tar'] }))
  assert.equal(manifest.json.git, undefined)
  assert.doesNotMatch(manifest.markdown, /## Git/u)
  assert.doesNotMatch(manifest.markdown, /show-ref/u)
})

test('limits.execution publishes the 100000 per-command ceilings', () => {
  const manifest = buildCapabilityManifest(manifestInput())
  assert.equal(manifest.json.limits.execution.max_loop_iterations, 100000)
  assert.equal(manifest.json.limits.execution.max_command_count, 100000)
  assert.equal(manifest.json.limits.execution.max_awk_iterations, 100000)
  assert.equal(manifest.json.limits.execution.max_sed_iterations, 100000)
  assert.match(manifest.markdown, /100000\/100000\/100000 loop\/awk\/sed iterations/u)
  assert.match(manifest.markdown, /reason=iterations/u)
  assert.ok(manifest.markdown.includes(CAPABILITIES_JSON_PATH))
})

test('the manifest keeps the qualifiers that scope execution and recovery facts', () => {
  // These qualifiers are part of WORKER_EXECUTION_LIMIT_FACT and
  // spec/v1/budgets.md, not decoration: dropping "per command" would imply one
  // Worker-wide command ceiling, dropping "first" would change eviction order,
  // and dropping "after reconnect" would make the resend condition false.
  const manifest = buildCapabilityManifest(manifestInput())
  const facts = [
    `per command <= ${String(WORKER_EXECUTION_LIMITS.maxCommandCount)} commands`,
    'cleared first under pressure',
    'unacknowledged resend after reconnect',
  ]
  for (const fact of facts) {
    assert.ok(manifest.markdown.includes(fact), `AGENTS.md keeps the fact: ${fact}`)
  }
})
