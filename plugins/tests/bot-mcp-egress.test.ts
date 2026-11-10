// SPDX-License-Identifier: MIT
/**
 * WPF1 profile check: both Worker profiles mount `mcp-phone` with the
 * host-issued `X-PDSH-MCP-Egress` credential, and omit the header when the
 * environment value is absent or empty (the host then fails the request
 * closed). The header map is evaluated exactly as the Cordis loader evaluates
 * a `!!js` scalar.
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

const repository = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const yaml = createRequire(import.meta.url)('js-yaml') as {
  readonly Type: new (tag: string, options: {
    kind: string
    construct: (value: unknown) => unknown
  }) => unknown
  readonly DEFAULT_SCHEMA: { extend(types: unknown[]): unknown }
  load(text: string, options: { schema: unknown }): unknown
}

interface PatchRow {
  readonly id?: string
  readonly config?: { readonly headers?: unknown }
  readonly insert?: readonly PatchRow[]
  readonly plugins?: readonly PatchRow[]
}

/** Preserve DSH's `!!js` expression source as a string. */
function loadPatch(filename: string): PatchRow[] {
  const jsType = new yaml.Type('!js', { kind: 'scalar', construct: value => String(value) })
  const schema = yaml.DEFAULT_SCHEMA.extend([jsType])
  const text = readFileSync(filename, 'utf8')
  return yaml.load(text.replace(/!!js/g, '!js'), { schema }) as PatchRow[]
}

/** Depth-first walk over groups, inserts and nested plugin lists. */
function flatten(rows: readonly PatchRow[]): PatchRow[] {
  const all: PatchRow[] = []
  const visit = (list: readonly PatchRow[] | undefined): void => {
    if (!Array.isArray(list)) return
    for (const row of list) {
      if (row === null || typeof row !== 'object') continue
      all.push(row)
      visit(row.insert)
      visit(row.plugins)
      const plugins = (row.config as { plugins?: readonly PatchRow[] } | undefined)?.plugins
      if (Array.isArray(plugins)) visit(plugins)
    }
  }
  visit(rows)
  return all
}

function mcpPhoneHeaders(profile: string): Record<string, string> {
  const filename = join(repository, 'plugins/profile', profile)
  const row = flatten(loadPatch(filename)).find(candidate => candidate.id === 'mcp-phone')
  assert.ok(row, `${profile} must mount mcp-phone`)
  const expression = row.config?.headers
  assert.equal(typeof expression, 'string', `${profile} mcp-phone headers must be a !!js map`)
  const headers = new Function(`return (${String(expression)})`)() as Record<string, string>
  assert.equal(typeof headers, 'object')
  return headers
}

function withEnvironment<T>(values: Record<string, string | undefined>, body: () => T): T {
  const previous: Record<string, string | undefined> = {}
  for (const [name, value] of Object.entries(values)) {
    previous[name] = process.env[name]
    if (value === undefined) delete process.env[name]
    else process.env[name] = value
  }
  try {
    return body()
  } finally {
    for (const [name, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[name]
      else process.env[name] = value
    }
  }
}

const PROFILES = ['phone.cordis.patch.yml', 'phone.worker.cordis.patch.yml'] as const

for (const profile of PROFILES) {
  test(`${profile}: mcp-phone sends the host egress credential when set`, () => {
    const headers = withEnvironment({
      PDSH_PHONE_MCP_TOKEN: 'phone-host-injects-bot-mcp-token',
      PDSH_MCP_EGRESS_TOKEN: 'profile-fixture-egress',
    }, () => mcpPhoneHeaders(profile))
    assert.deepEqual(headers, {
      Authorization: 'Bearer phone-host-injects-bot-mcp-token',
      'X-PDSH-MCP-Egress': 'profile-fixture-egress',
    })
  })

  test(`${profile}: mcp-phone omits the egress header when the value is absent or empty`, () => {
    for (const value of [undefined, '']) {
      const headers = withEnvironment({
        PDSH_PHONE_MCP_TOKEN: 'phone-host-injects-bot-mcp-token',
        PDSH_MCP_EGRESS_TOKEN: value,
      }, () => mcpPhoneHeaders(profile))
      assert.equal('X-PDSH-MCP-Egress' in headers, false,
        `an absent/empty value must omit the header (${String(value)})`)
      assert.equal(headers.Authorization, 'Bearer phone-host-injects-bot-mcp-token',
        'the non-secret Bot bearer placeholder is unchanged')
    }
  })
}
