// SPDX-License-Identifier: MIT
/**
 * G2-FIX-57 repair: the dispatch watchdogs are not constructor-only anymore.
 * `PDSH_TOOLBOX_EXEC_START_TIMEOUT_MS` and `PDSH_TOOLBOX_STDIN_READ_TIMEOUT_MS`
 * mirror the shell's `PDSH_SHELL_STDIN_TIMEOUT_MS`, so a field diagnosis can
 * tighten the same bound without rebuilding the Worker.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  DEFAULT_EXEC_START_TIMEOUT_MS,
  DEFAULT_STDIN_READ_TIMEOUT_MS,
  EXEC_START_TIMEOUT_ENV,
  MemoryVfsBackend,
  resolveDispatchTimeouts,
  STDIN_READ_TIMEOUT_ENV,
  WasiToolbox,
} from './index.ts'

/** One registered program; the toolbox never compiles or spawns in these tests. */
const command = {
  program: 'probe',
  module: { url: 'probe.wasm', load: async () => new Uint8Array(0) },
}

test('G2-FIX-57: dispatch watchdog defaults are unchanged', () => {
  assert.deepEqual(resolveDispatchTimeouts({}), {
    execStartTimeoutMs: DEFAULT_EXEC_START_TIMEOUT_MS,
    stdinReadTimeoutMs: DEFAULT_STDIN_READ_TIMEOUT_MS,
  })
  assert.equal(DEFAULT_EXEC_START_TIMEOUT_MS, 10_000)
  assert.equal(DEFAULT_STDIN_READ_TIMEOUT_MS, 20_000)
})

test('G2-FIX-57: environment knobs override both dispatch watchdogs', () => {
  assert.deepEqual(resolveDispatchTimeouts({
    [EXEC_START_TIMEOUT_ENV]: '1500',
    [STDIN_READ_TIMEOUT_ENV]: '2500.9',
  }), { execStartTimeoutMs: 1_500, stdinReadTimeoutMs: 2_500 })
  // Empty means "unset", the same rule the shell's knobs follow.
  assert.deepEqual(resolveDispatchTimeouts({
    [EXEC_START_TIMEOUT_ENV]: ' ',
    [STDIN_READ_TIMEOUT_ENV]: '',
  }), { execStartTimeoutMs: 10_000, stdinReadTimeoutMs: 20_000 })
})

test('G2-FIX-57: an invalid environment knob fails loud with its name', () => {
  for (const value of ['0', '-1', 'soon', 'Infinity']) {
    assert.throws(
      () => resolveDispatchTimeouts({ [EXEC_START_TIMEOUT_ENV]: value }),
      new RegExp(`${EXEC_START_TIMEOUT_ENV} must be a positive number of milliseconds`),
    )
    assert.throws(
      () => resolveDispatchTimeouts({ [STDIN_READ_TIMEOUT_ENV]: value }),
      new RegExp(`${STDIN_READ_TIMEOUT_ENV} must be a positive number of milliseconds`),
    )
  }
})

test('G2-FIX-57: explicit constructor options win over the environment knobs', async () => {
  const saved = new Map<string, string | undefined>()
  for (const name of [EXEC_START_TIMEOUT_ENV, STDIN_READ_TIMEOUT_ENV]) {
    saved.set(name, process.env[name])
  }
  process.env[EXEC_START_TIMEOUT_ENV] = '300'
  process.env[STDIN_READ_TIMEOUT_ENV] = 'not-a-number'
  try {
    // Both options are explicit: the invalid environment is not consulted.
    const explicit = new WasiToolbox({
      commands: [command],
      backend: new MemoryVfsBackend(),
      crossOriginIsolated: false,
      execStartTimeoutMs: 300,
      stdinReadTimeoutMs: 300,
    })
    await explicit.dispose()

    // A missing option falls back to its knob, so a bad value is a boot error.
    assert.throws(() => new WasiToolbox({
      commands: [command],
      backend: new MemoryVfsBackend(),
      crossOriginIsolated: false,
      execStartTimeoutMs: 300,
    }), new RegExp(`${STDIN_READ_TIMEOUT_ENV} must be a positive number of milliseconds`))
  } finally {
    for (const [name, value] of saved) {
      if (value === undefined) delete process.env[name]
      else process.env[name] = value
    }
  }
})
