// SPDX-License-Identifier: MIT
// The Worker-side curl allow-list understands the same wildcard entries as
// the host gateway: `*` admits every host, `*.corp.example` one domain.
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { hostAllowed } from './curl.ts'

test('a single * admits every host', () => {
  assert.equal(hostAllowed('weather.example', ['*']), true)
  assert.equal(hostAllowed('api.weather.example', ['model.example', ' * ']), true)
})

test('*.suffix admits the apex and its subdomains only', () => {
  assert.equal(hostAllowed('corp.example', ['*.corp.example']), true)
  assert.equal(hostAllowed('api.corp.example', ['*.corp.example']), true)
  assert.equal(hostAllowed('notcorp.example', ['*.corp.example']), false)
  assert.equal(hostAllowed('corp.example.evil.invalid', ['*.corp.example']), false)
})

test('exact and .suffix entries keep their meaning', () => {
  assert.equal(hostAllowed('corp.example', ['corp.example']), true)
  assert.equal(hostAllowed('api.corp.example', ['corp.example']), true)
  assert.equal(hostAllowed('api.corp.example', ['.corp.example']), true)
  assert.equal(hostAllowed('weather.example', ['corp.example']), false)
  assert.equal(hostAllowed('weather.example', []), false)
  assert.equal(hostAllowed('weather.example', ['*.']), false)
})
