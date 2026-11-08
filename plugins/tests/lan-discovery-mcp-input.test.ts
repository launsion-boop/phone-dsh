// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import { validateServerInput } from '../phone-mcp/src/schema.ts'

test('shared LAN discovery URLs survive the MCP input validator under Node', () => {
  const path = new URL('../../spec/device/v1/golden/lan-discovery-raw.jsonl', import.meta.url)
  const rows = readFileSync(path, 'utf8').trim().split('\n').map(line => JSON.parse(line))
  const valid = rows.filter(row => typeof row.url === 'string')
  assert.ok(valid.length > 0, 'the shared file must contain valid candidates')
  for (const row of valid) {
    const config = validateServerInput({ serverName: 'device', url: row.url })
    assert.equal(config.url, row.url, row.name)
  }
})

test('manual MCP URL parsing is separate from LAN discovery hostname validation', () => {
  const path = new URL('../../spec/device/v1/golden/lan-discovery-raw.jsonl', import.meta.url)
  const rows = readFileSync(path, 'utf8').trim().split('\n').map(line => JSON.parse(line))
  const host = (name: string) => {
    const row = rows.find(item => item.name === name)
    assert.ok(row, `missing shared vector ${name}`)
    return row.host
  }
  assert.equal(validateServerInput({ serverName: 'device', url: `https://${host('hex_prefix_only')}/mcp` }).url,
    'https://0.0.0.0/mcp')
  assert.throws(() => validateServerInput({ serverName: 'device', url: `https://${host('named_numeric_final')}/mcp` }))
})
