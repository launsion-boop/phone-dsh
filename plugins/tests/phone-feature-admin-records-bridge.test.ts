// SPDX-License-Identifier: MIT
/**
 * The feature-admin -> App host raw-record bridge. A real loopback HTTP server
 * proves the request shape, auth headers, timeout/error mapping and the
 * bounded actual content; no DSH runtime or Worker is involved.
 */

import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { createServer } from 'node:http'
import type { AddressInfo } from 'node:net'
import { test } from 'node:test'
import { FeatureAdminError } from '../phone-feature-admin/src/errors.ts'
import {
  HostSkillMutationJournal,
  MAX_RECORDED_CONTENT_BYTES,
  skillMutationFailureCode,
} from '../phone-feature-admin/src/mutation-records.ts'

interface Captured {
  readonly path: string
  readonly authorization: string | undefined
  readonly egress: string | undefined
  readonly body: any
}

async function host(reply: (body: any) => { status?: number; json: unknown }) {
  const captured: Captured[] = []
  const server = createServer((request, response) => {
    const chunks: Buffer[] = []
    request.on('data', chunk => chunks.push(chunk))
    request.on('end', () => {
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'))
      captured.push({
        path: request.url ?? '',
        authorization: request.headers.authorization,
        egress: request.headers['x-pdsh-mcp-egress'] as string | undefined,
        body,
      })
      const answer = reply(body)
      response.writeHead(answer.status ?? 200, { 'content-type': 'application/json' })
      response.end(JSON.stringify(answer.json))
    })
  })
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve))
  const port = (server.address() as AddressInfo).port
  return {
    captured,
    endpoint: `http://127.0.0.1:${String(port)}/mcp`,
    close: () => new Promise<void>(resolve => server.close(() => resolve())),
  }
}

test('host bridge sends the exact requested input, hash and auth headers', async (t) => {
  const fake = await host(() => ({ json: { ok: true, record: 'record://event/41' } }))
  t.after(() => fake.close())
  const journal = new HostSkillMutationJournal({
    endpoint: fake.endpoint,
    token: 'worker-token',
    egressToken: 'egress-token',
    timeoutMs: 1_000,
  })
  const content = '# Weekly\n\n- actual UI body\n'
  const record = await journal.begin({
    operationId: 'op-1', action: 'write', file: 'weekly.md', content,
  })
  assert.deepEqual(record, { operationId: 'op-1', record: 'record://event/41' })
  assert.equal(fake.captured.length, 1)
  const request = fake.captured[0]!
  assert.equal(request.path, '/feature-admin/skill-mutation')
  assert.equal(request.authorization, 'Bearer worker-token')
  assert.equal(request.egress, 'egress-token')
  assert.deepEqual(request.body, {
    op: 'begin',
    operation_id: 'op-1',
    action: 'write',
    file: 'weekly.md',
    content,
    content_sha256: createHash('sha256').update(content, 'utf8').digest('hex'),
    bytes: Buffer.byteLength(content, 'utf8'),
  })
})

test('host bridge maps a bounded host refusal onto the browser failure vocabulary', async (t) => {
  const fake = await host(() => ({
    json: { ok: false, code: 'file-mismatch', reason: 'the real file differs' },
  }))
  t.after(() => fake.close())
  const journal = new HostSkillMutationJournal({
    endpoint: fake.endpoint, token: 'worker-token',
  })
  await assert.rejects(
    journal.begin({ operationId: 'op-1', action: 'write', file: 'weekly.md', content: 'x' }),
    (error: unknown) => error instanceof FeatureAdminError
      && error.code === 'conflict'
      && error.domainCode === 'file-mismatch'
      && /real file differs/u.test(error.message),
  )
})

test('host bridge fails closed without touching HTTP when the App is absent', async () => {
  const journal = new HostSkillMutationJournal({ endpoint: '', token: '' })
  assert.equal(journal.available, false)
  await assert.rejects(
    journal.begin({ operationId: 'op-1', action: 'write', file: 'weekly.md', content: 'x' }),
    (error: unknown) => error instanceof FeatureAdminError
      && error.code === 'unsupported'
      && error.domainCode === 'record-bridge-unavailable',
  )
})

test('host bridge refuses content above the raw-record bound before HTTP', async () => {
  let requested = 0
  const journal = new HostSkillMutationJournal({
    endpoint: 'http://127.0.0.1:9/mcp',
    token: 'worker-token',
    fetch: async () => {
      requested += 1
      throw new Error('must not reach HTTP')
    },
  })
  const content = 'a'.repeat(MAX_RECORDED_CONTENT_BYTES + 1)
  await assert.rejects(
    journal.begin({ operationId: 'op-1', action: 'write', file: 'large.md', content }),
    (error: unknown) => error instanceof FeatureAdminError
      && error.code === 'invalid-request'
      && error.domainCode === 'record-content-too-large',
  )
  assert.equal(requested, 0)
})

test('applied and failed reuse the one operation id and bounded failure code', async (t) => {
  const fake = await host(body => ({
    json: { ok: true, record: `record://event/${body.op === 'applied' ? '42' : '43'}` },
  }))
  t.after(() => fake.close())
  const journal = new HostSkillMutationJournal({
    endpoint: fake.endpoint, token: 'worker-token',
  })
  const applied = await journal.applied('op-1')
  assert.equal(applied.record, 'record://event/42')
  await journal.failed('op-1', 'EACCES')
  assert.deepEqual(fake.captured.map(request => request.body), [
    { op: 'applied', operation_id: 'op-1' },
    { op: 'failed', operation_id: 'op-1', failure_code: 'EACCES' },
  ])
  assert.equal(skillMutationFailureCode(Object.assign(new Error('x'), { code: 'EACCES' })), 'eacces')
  assert.equal(skillMutationFailureCode(new Error('x')), 'io-error')
})
