// SPDX-License-Identifier: MIT
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import { validateServerInput } from '../phone-mcp/src/schema.ts'

test('shared LAN discovery URLs survive the MCP input validator under Node', () => {
  const rows = ['lan-discovery.jsonl', 'lan-discovery-raw.jsonl'].flatMap(file =>
    readFileSync(new URL(`../../spec/device/v1/golden/${file}`, import.meta.url), 'utf8')
      .trim().split('\n').map(line => JSON.parse(line)))
  const valid = rows.filter(row => typeof row.url === 'string')
  assert.ok(valid.length > 0, 'the shared files must contain valid candidates')
  for (const row of valid) {
    const config = validateServerInput({ serverName: 'device', url: row.url })
    assert.equal(config.url, row.url, row.name)
  }
})

const vectors = (file: string) => readFileSync(new URL(`../../spec/device/v1/golden/${file}`, import.meta.url), 'utf8')
  .trim().split('\n').map(line => JSON.parse(line))

test('accepted A-label/LDH discovery URLs keep their exact host in the MCP input validator', () => {
  // lan-mcp.md canon: without xn-- labels, WHATWG domain-to-ASCII is ASCII lowercasing,
  // so the stored URL and the TLS servername derived from it equal the decoder's H.
  const rows = vectors('lan-discovery-alabel.jsonl')
  const valid = rows.filter(row => typeof row.url === 'string')
  assert.ok(valid.length > 0 && valid.length < rows.length, 'the A-label file must contain both outcomes')
  for (const row of valid) {
    const config = validateServerInput({ serverName: 'device', url: row.url })
    assert.equal(config.url, row.url, row.name)
    assert.equal(new URL(config.url).hostname, row.host.replace(/\.$/, '').toLowerCase(), row.name)
  }
})

test('consistent publication vectors keep URL host equal to the certificate hostname', () => {
  const rows = vectors('lan-publication.jsonl').filter(row => row.result === 'consistent')
  assert.ok(rows.length > 0)
  for (const row of rows) {
    const config = validateServerInput({ serverName: 'device', url: row.url })
    assert.equal(config.url, row.url, row.name)
    assert.equal(new URL(config.url).hostname, row.hostname.replace(/\.$/, '').toLowerCase(), row.name)
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
