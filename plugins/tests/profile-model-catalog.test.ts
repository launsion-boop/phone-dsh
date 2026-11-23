// SPDX-License-Identifier: MIT
// The phone profile's `llm-deepseek` catalog row: DeepSeek-only mid-conversation
// tool changes (`tool_addition`) are declared only for the official endpoint.
// The Tono cloud rejected them with 400 `upstream_rejected` (2026-11-23), which
// failed every DSH-tab turn on the iPhone. The row's real `!!js` text is
// evaluated and its result goes through DSH's own resolver.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import { resolveAdapterOptions } from '@deepseek-ai/dsh-llm-deepseek'

const repository = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const profile = readFileSync(
  join(repository, 'plugins/profile/phone.worker.cordis.patch.yml'), 'utf8')

/** The `models: !!js |` block of the top-level `- id: llm-deepseek` row. */
function modelsExpression(): string {
  const row = profile.indexOf('\n- id: llm-deepseek\n')
  assert.ok(row >= 0, 'the phone profile has no top-level llm-deepseek row')
  const marker = '    models: !!js |\n'
  const start = profile.indexOf(marker, row)
  assert.ok(start >= 0, 'the llm-deepseek row has no models expression')
  const lines: string[] = []
  for (const line of profile.slice(start + marker.length).split('\n')) {
    if (line.length > 0 && !line.startsWith('      ')) break
    lines.push(line.slice(6))
  }
  return lines.join('\n')
}

function catalogFor(providerJSON: string | undefined): unknown {
  const env: Record<string, string> = {}
  if (providerJSON !== undefined) env.PDSH_MODEL_PROVIDER_JSON = providerJSON
  return new Function('process', `return (${modelsExpression()})`)({ env })
}

function projection(baseURL: string): string {
  return JSON.stringify({
    providers: [
      { id: 'other', displayName: 'Other', baseURL: 'https://api.deepseek.com/anthropic', model: 'deepseek-flash' },
      { id: 'tono-cloud', displayName: 'Tono 云端', baseURL, model: 'deepseek-flash' },
    ],
    selectedId: 'tono-cloud',
    version: 1,
  })
}

/** The resolved catalog entry the request serializer reads for `deepseek-flash`. */
function flash(models: unknown) {
  const connection = resolveAdapterOptions({ models } as never)
  const entry = connection.models.find(model => model.id === 'deepseek-flash')
  assert.ok(entry, 'deepseek-flash is missing from the resolved catalog')
  return entry
}

/** DSH's own built-in catalog, resolved the same way. */
const builtIn = resolveAdapterOptions({} as never).models

test('the Tono cloud route never declares mid-conversation tool changes', () => {
  const models = catalogFor(projection('https://pdsh.tonoai.cn/v1/llm/anthropic'))
  assert.ok(Array.isArray(models))
  const info = flash(models)
  assert.equal(info.toolUpdate, undefined, 'tool_addition would reach an endpoint that rejects it')
  assert.equal(info.systemPromptUpdate, 'in-history')
})

test('any non-official endpoint drops toolUpdate but keeps the rest of the built-in catalog', () => {
  const models = catalogFor(projection('https://llm.example.com/anthropic')) as Record<string, unknown>[]
  const resolved = resolveAdapterOptions({ models } as never).models
  const expected = builtIn.map(({ toolUpdate: _dropped, ...rest }) => rest)
  assert.deepEqual(resolved, expected, 'the phone copy of the DSH catalog drifted from the built-in catalog')
})

test('the official endpoint and unreadable projections keep the built-in catalog', () => {
  assert.equal(catalogFor(projection('https://api.deepseek.com/anthropic')), undefined)
  assert.equal(catalogFor(projection('https://API.DeepSeek.com/anthropic')), undefined)
  assert.equal(catalogFor(undefined), undefined)
  assert.equal(catalogFor('not json'), undefined)
  assert.equal(catalogFor(JSON.stringify({ providers: [] })), undefined)
  assert.equal(catalogFor(projection('not a url')), undefined)
  assert.equal(flash(undefined).toolUpdate, 'addition-only')
})
