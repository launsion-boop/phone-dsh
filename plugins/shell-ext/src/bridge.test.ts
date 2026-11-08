// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { test } from 'node:test'
import type { ExecRequest } from '@phone-dsh/dsh-exec-bridge'
import { acceleratorExecID, createExecBridgeAccelerators, createAcceleratorCommands } from './bridge.ts'
import { byteStringToBytes } from './encoding.ts'
import { phoneProviderFailure } from './phone-errors.ts'
import { createCommandContext, InMemoryFs } from 'just-bash/browser'

test('accelerator exec_id survives process sequence reset without cross-call collisions', async () => {
  const requests: ExecRequest[] = []
  async function dispatch(sessionId: string, turnId: string, stepId: string): Promise<void> {
    const bridge = createExecBridgeAccelerators({
      hello: { capabilities: { exec: true, accelerators: ['phone'] } },
      revision: () => 0n,
      toolCall: () => ({ sessionId, turnId, stepId, key: `${sessionId}-${turnId}-${stepId}`, callId: stepId, spawns: 0 }),
      client: {
        async exec(request) {
          requests.push(request)
          return {
            async *[Symbol.asyncIterator]() {
              yield {
                type: 'exit' as const, exec_id: request.exec_id, seq: 0,
                code: 0, signal: null, status: 'exited' as const, quiescent: true,
              }
            },
            close() {},
          }
        },
        async cancel() {},
      },
    })
    const result = await bridge.exec({ argv: ['phone', 'files.list', '{}'], cwd: '/dsh/workspace', env: {}, stdin: '' })
    assert.equal(result.exitCode, 0)
  }
  await dispatch('session-a', '1', '1')
  await dispatch('session-b', '1', '1')
  assert.equal(requests.length, 2)
  assert.equal(requests[0]?.exec_id.length, 64)
  assert.notEqual(requests[0]?.exec_id, requests[1]?.exec_id)
  assert.notEqual(requests[0]?.idem_key, requests[1]?.idem_key)
  // `spec/v1/exec.md:78-79` pins the shape, not a helper: the host exec id is
  // `<identity>-a<sequence>`, bounded to 64 characters with only the prefix
  // shortened. `identity.key` is the trusted tool-call key, which is not
  // necessarily a sha256 digest (the session/turn/step fallback is not), so this
  // asserts the shape the bridge actually builds.
  const first = requests[0]!
  assert.match(first.exec_id, /-a\d+$/u)
  assert.equal(first.exec_id.endsWith('-a0'), true)
  assert.equal(first.exec_id.length <= 64, true)
})

test('phone admission failure is retryable only because it did not start', () => {
  const { error } = JSON.parse(phoneProviderFailure('doc.write', {
    exitCode: 1, providerCode: 'admission_closed', providerMessage: 'admission is closed',
  })!)
  assert.equal(error.code, 'admission_closed')
  assert.equal(error.retryable, true)
  assert.equal(error.foreground_required, true)
  assert.equal(error.outcome, 'not_started')
})

test('phone timeout distinguishes read-only retry from unknown write outcome', () => {
  const read = JSON.parse(phoneProviderFailure('pdf.text', { exitCode: 124 })!).error
  const write = JSON.parse(phoneProviderFailure('doc.write', { exitCode: 124 })!).error
  assert.equal(read.code, 'provider_timeout')
  assert.equal(read.retryable, true)
  assert.equal(write.code, 'provider_timeout')
  assert.equal(write.retryable, false)
  assert.equal(write.foreground_required, false)
  assert.equal(write.outcome, 'unknown')
  for (const tool of [
    'contacts.get', 'calendar.list', 'reminders.list', 'health.summary', 'health.query',
    'photos.recent', 'photos.search', 'audio.transcribe', 'location.current',
    'clipboard.read', 'files.list_roots', 'device.status', 'motion.activity',
    'motion.steps', 'bluetooth.scan', 'network.browse',
  ]) {
    const result = JSON.parse(phoneProviderFailure(tool, { exitCode: 124 })!).error
    assert.equal(result.retryable, true, `${tool} is read-only and safe to retry after a timeout`)
  }
  for (const tool of [
    'reminders.create', 'reminders.complete', 'camera.capture', 'camera.scan_document',
    'audio.record', 'notify.local', 'clipboard.write', 'files.grant_folder',
  ]) {
    const result = JSON.parse(phoneProviderFailure(tool, { exitCode: 124 })!).error
    assert.equal(result.retryable, false, `${tool} has an unknown write outcome and must not auto-retry`)
  }
})

test('a phone provider failure keeps its typed code and safe host message in a bounded result', async () => {
  const [command] = createAcceleratorCommands({
    names: ['phone'],
    exec: async () => ({
      stdout: '', stderr: 'not_configured: mount unavailable', exitCode: 69,
      providerCode: 'not_configured', providerMessage: 'mount unavailable',
    }),
  })
  assert.ok(command)
  const context = createCommandContext({
    cwd: '/dsh/workspace', fs: new InMemoryFs(), env: new Map(),
  })
  const result = await command.execute(['doc.write', '{}'], context)
  assert.equal(result.exitCode, 69)
  assert.deepEqual(JSON.parse(Buffer.from(byteStringToBytes(result.stdout)).toString('utf8')), {
    ok: false,
    error: {
      code: 'provider_unavailable', message: 'mount unavailable', retryable: false,
      foreground_required: false, outcome: 'unknown', tool: 'doc.write', cause: 'not_configured',
    },
  })
  assert.equal(Buffer.from(byteStringToBytes(result.stderr)).toString('utf8'), '')
})
