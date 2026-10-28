// SPDX-License-Identifier: MIT
/**
 * Behaviour tests for the minimal `www/boot.js` page.
 *
 * The script is evaluated in a fresh VM realm with a URL/history/Worker stand-in:
 * it must forward the transport coordinates to the Worker from memory, scrub
 * them from the visible URL before the Worker starts (or a failure is shown),
 * keep business query/hash, and never print a raw token or environment.
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'
import { runInNewContext } from 'node:vm'

const HERE = dirname(fileURLToPath(import.meta.url))
const BOOT_JS = join(HERE, '..', 'www', 'boot.js')
const SOURCE = readFileSync(BOOT_JS, 'utf8')

interface HistoryCall {
  readonly state: unknown
  readonly url: string
}

interface Page {
  readonly location: { href: string; search: string }
  readonly history: { state: unknown; replaceState(data: unknown, unused: string, url?: string | URL | null): void }
  readonly historyCalls: HistoryCall[]
  readonly posted: unknown[]
  readonly status: { textContent: string }
  readonly document: { title: string; querySelector(selector: string): { textContent: string } }
}

/** Build the browser face boot.js reads, plus captured history/Worker results. */
function page(href: string): Page {
  const historyCalls: HistoryCall[] = []
  const state = { route: 'conversation' }
  const status = { textContent: '' }
  const document = {
    title: '',
    querySelector(selector: string) {
      assert.equal(selector, '#status')
      return status
    },
  }
  const history = {
    state,
    replaceState(data: unknown, unused: string, url?: string | URL | null) {
      historyCalls.push({ state: data, url: String(url) })
    },
  }
  return {
    location: { href, search: new URL(href).search },
    history,
    historyCalls,
    posted: [],
    status,
    document,
  }
}

/** Execute boot.js with the page stand-in and a recording Worker. */
function boot(href: string, failure?: string): Page {
  const host = page(href)
  class RecordingWorker {
    constructor(_url: string, _options: { type: string }) {
      if (failure !== undefined) throw new Error(failure)
    }

    addEventListener(): void {}

    postMessage(message: unknown): void {
      host.posted.push(message)
    }
  }
  runInNewContext(SOURCE, {
    location: host.location,
    history: host.history,
    document: host.document,
    Worker: RecordingWorker,
    URL,
    URLSearchParams,
    Error,
    console: { error() {} },
  }, { filename: BOOT_JS })
  return host
}

test('www/boot.js forwards init values in memory and scrubs the visible URL', () => {
  const href = 'http://127.0.0.1:7411/static/index.html'
    + '?token=launch-token&image=%2Fimage%2Fbase&channel=%2Fchannel'
    + '&overlay=a.tar.gz&overlay%5B%5D=b.tar.gz'
    + '&fence=%7B%22owner%22%3A%22phone%22%2C%22generation%22%3A4%2C%22wal_seq%22%3A9%7D'
    + '&env=%7B%22PDSH_LAUNCH_TOKEN%22%3A%22env-secret%22%7D'
    + '&egress=%5B%22api.example.invalid%22%5D'
    + '&boot_id=0123456789abcdef0123456789abcdef&session_epoch=4'
    + '&keep=business#conversation/42'
  const host = boot(href)
  assert.equal(host.posted.length, 1)
  const frame = host.posted[0] as {
    t: string
    image: string
    overlays: readonly string[]
    xl: Record<string, unknown>
  }
  assert.equal(frame.t, 'init')
  assert.equal(frame.image, '/image/base')
  assert.deepEqual([...frame.overlays], ['a.tar.gz', 'b.tar.gz'])
  assert.equal(frame.xl['token'], 'launch-token')
  assert.deepEqual({ ...(frame.xl['env'] as Record<string, unknown>) }, { PDSH_LAUNCH_TOKEN: 'env-secret' })
  assert.equal(frame.xl['channelURL'], 'ws://127.0.0.1:7411/channel')
  assert.equal(frame.xl['bootId'], '0123456789abcdef0123456789abcdef')
  assert.equal(frame.xl['sessionEpoch'], '4')

  assert.equal(host.historyCalls.length, 1)
  assert.equal(host.historyCalls[0]?.state, host.history.state)
  const visible = new URL(host.historyCalls[0]!.url)
  assert.equal(visible.searchParams.get('keep'), 'business')
  assert.equal(visible.hash, '#conversation/42')
  for (const name of ['token', 'image', 'channel', 'overlay', 'overlay[]', 'fence', 'env', 'egress', 'boot_id', 'session_epoch']) {
    assert.equal(visible.searchParams.has(name), false, `the visible URL must not keep ${name}`)
  }
  assert.doesNotMatch(host.status.textContent, /launch-token|env-secret/)
})

test('www/boot.js scrubs the URL and redacts a Worker start failure', () => {
  const href = 'http://127.0.0.1:7411/static/index.html'
    + '?token=launch-token&image=%2Fimage%2Fbase&channel=%2Fchannel'
    + '&env=%7B%22PDSH_LAUNCH_TOKEN%22%3A%22env-secret%22%7D&keep=business#chat'
  const host = boot(href,
    `worker start failed: ${href} Authorization: Bearer bearer-secret`)
  assert.equal(host.posted.length, 0)
  assert.equal(host.document.title, 'DSH failed')
  assert.equal(host.historyCalls.length, 1)
  const visible = new URL(host.historyCalls[0]!.url)
  assert.equal(visible.searchParams.get('keep'), 'business')
  assert.equal(visible.hash, '#chat')
  assert.doesNotMatch(host.status.textContent, /launch-token|env-secret|bearer-secret|%2Fimage%2Fbase/)
  assert.match(host.status.textContent, /\[redacted\]/)
})

test('www/boot.js redacts raw env/fence object values in a failure', () => {
  const href = 'http://127.0.0.1:7411/static/index.html'
    + '?image=x&channel=%2Fchannel&keep=business'
    + '&env=%7B%22PDSH_LAUNCH_TOKEN%22%3A%22env-secret%22%7D'
    + '&fence=%7B%22owner%22%3A%22phone-secret%22%7D'
  const host = boot(href,
    'worker start failed: ?env={"PDSH_LAUNCH_TOKEN":"env-secret"} '
    + 'fence={"owner":"phone-secret"}')
  assert.equal(host.document.title, 'DSH failed')
  assert.doesNotMatch(host.status.textContent, /PDSH_LAUNCH_TOKEN|env-secret|owner|phone-secret/)
  assert.match(host.status.textContent, /\[redacted\]/)
  assert.match(host.status.textContent, /worker start failed/)
})
