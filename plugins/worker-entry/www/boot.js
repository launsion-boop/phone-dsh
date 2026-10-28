// SPDX-License-Identifier: MIT
/**
 * Page half of the DSH phone worker.
 *
 * Everything the Worker needs comes from this page's own query string, which
 * the loopback origin served. No secret is written into the markup: the
 * per-start token travels only in the URL the page was given and in the
 * `init` message to the Worker. The transport keys are scrubbed from the
 * visible URL immediately after they are captured, so the address bar, a
 * copied link and a screenshot keep only business query/hash. Subsequent
 * page↔Worker traffic uses the runtime's postMessage tunnel (`GET /__boot__`
 * still goes through it).
 */

const status = document.querySelector('#status')

/** Boot transport keys: the page consumes them once and they are then scrubbed. */
const BOOT_TRANSPORT_PARAMS = new Set([
  'image', 'channel', 'channelURL', 'token', 'overlay', 'overlay[]',
  'fence', 'env', 'egress', 'egress_allow', 'egressAllow',
  'boot_id', 'bootId', 'session_epoch', 'sessionEpoch',
])

/**
 * Bound and redact a failure before it reaches the visible boot page. Raw
 * tokens, environment objects and URLs must not be copyable from a screenshot.
 * @param {unknown} reason
 * @returns {string}
 */
function redact(reason) {
  var text
  try {
    text = reason instanceof Error
      ? String(reason.name) + ': ' + String(reason.message)
      : String(reason)
  } catch (redactError) {
    return 'unknown error'
  }
  text = text
    // Objects/arrays first, so `?env={"KEY":"secret"}` is consumed whole; a
    // query rule that stops at `{` would leave the raw body behind.
    .replace(/("(?:env|fence|egress(?:Allow|_allow)?)"\s*:\s*)(\{[^}]*\}|\[[^\]]*\])/gi, '$1[redacted]')
    .replace(/\b(env|fence|egress(?:Allow|_allow)?)\s*=\s*(\{[^}]*\}|\[[^\]]*\])/gi, '$1=[redacted]')
    .replace(/([?&](?:token|image|channel(?:URL)?|overlay(?:\[\])?|fence|env|egress(?:_allow|Allow)?|boot_id|bootId|session_epoch|sessionEpoch)=)[^&#\s"'<>]*/gi, '$1[redacted]')
    .replace(/(Authorization\s*:\s*Bearer\s+)[^\s,;]+/gi, '$1[redacted]')
    .replace(/("(?:token|image|channel(?:URL)?|overlay(?:\[\])?|fence|env|egress(?:_allow|Allow)?|boot_id|bootId|session_epoch|sessionEpoch)"\s*:\s*")[^"]*"/gi, '$1[redacted]"')
    .replace(/\b(token|image|channel(?:URL)?|overlay(?:\[\])?|fence|env|egress(?:_allow|Allow)?|boot_id|bootId|session_epoch|sessionEpoch)\s*=\s*[^\s,;&<>]+/gi, '$1=[redacted]')
    .replace(/\s+/g, ' ')
    .trim()
  return text.length > 320 ? text.slice(0, 320) + '…' : text
}

/** @param {string} text */
function show(text) {
  if (status !== null) status.textContent = text
}

/** @param {string} title @param {string} text */
function fail(title, text) {
  document.title = title
  show(redact(text))
}

const params = new URLSearchParams(location.search)
const image = params.get('image')
const channelParam = params.get('channel') ?? params.get('channelURL')
const token = params.get('token') ?? ''
// `overlay[]` is the bracketed spelling some carriers use; keep document order
// across both spellings so overlays still apply in the order sent.
const overlays = []
for (const [name, value] of params) {
  if (name === 'overlay' || name === 'overlay[]') overlays.push(value)
}
const fenceRaw = params.get('fence')
const envRaw = params.get('env')
const egressRaw = params.get('egress') ?? params.get('egress_allow') ?? params.get('egressAllow')
const bootId = params.get('boot_id') ?? params.get('bootId') ?? undefined
const sessionEpoch = params.get('session_epoch') ?? params.get('sessionEpoch') ?? undefined

// The init values above are now in memory. Remove the transport coordinates
// from the visible URL before validation or Worker start so neither the
// failure panel nor a copied link/screenshot carries the launch token; business
// query parameters and the hash remain. Nothing is written to history.state or
// storage.
try {
  var visible = new URL(location.href)
  var scrubbed = false
  for (const name of [...visible.searchParams.keys()]) {
    if (!BOOT_TRANSPORT_PARAMS.has(name)) continue
    visible.searchParams.delete(name)
    scrubbed = true
  }
  if (scrubbed) history.replaceState(history.state, '', visible.href)
} catch (scrubError) {
  // A denied replaceState must not stop the Worker boot.
}

if (image === null || image === '') {
  fail('DSH boot failed', 'missing ?image=<image-url>')
  throw new Error('boot: ?image=<image-url> is required')
}
if (channelParam === null || channelParam === '') {
  fail('DSH boot failed', 'missing ?channel=<channel-url>')
  throw new Error('boot: ?channel=<channel-url> is required')
}

/** @param {string} raw @returns {string} */
function resolveChannelUrl(raw) {
  const url = new URL(raw, location.href)
  if (url.protocol === 'http:') url.protocol = 'ws:'
  else if (url.protocol === 'https:') url.protocol = 'wss:'
  return url.href
}

/**
 * @param {string | null} raw
 * @param {string} name
 * @returns {unknown}
 */
function parseJsonParam(raw, name) {
  if (raw === null || raw === '') return undefined
  try {
    return JSON.parse(raw)
  } catch {
    fail('DSH boot failed', `?${name}= is not valid JSON`)
    throw new Error(`boot: ?${name}= is not valid JSON`)
  }
}

const fence = parseJsonParam(fenceRaw, 'fence') ?? { owner: 'phone', generation: 0, wal_seq: 0 }
const env = parseJsonParam(envRaw, 'env') ?? {}
const egress = parseJsonParam(egressRaw, 'egress')
if (egress !== undefined && (!Array.isArray(egress) || egress.some((entry) => typeof entry !== 'string'))) {
  fail('DSH boot failed', '?egress= must be a JSON array of strings')
  throw new Error('boot: ?egress= must be a JSON array of strings')
}

document.title = 'DSH booting'
show('starting worker…')

try {
  const worker = new Worker('./worker-entry.js', { type: 'module' })
  worker.addEventListener('message', (event) => {
    const data = event.data
    if (data === null || typeof data !== 'object') return
    if (data.t === 'pdsh-ready') {
      document.title = 'DSH ready'
      show('worker ready')
      return
    }
    if (data.t === 'pdsh-error' || data.t === 'init-error') {
      fail('DSH failed', `worker error: ${String(data.message ?? 'unknown error')}`)
    }
  })
  worker.addEventListener('error', (event) => {
    fail('DSH failed', `worker error: ${String(event.message ?? 'failed to load')}`)
  })
  worker.postMessage({
    t: 'init',
    image,
    overlays,
    xl: {
      channelURL: resolveChannelUrl(channelParam),
      token,
      env,
      fence,
      ...bootId === undefined ? {} : { bootId },
      ...sessionEpoch === undefined ? {} : { sessionEpoch },
      ...egress === undefined ? {} : { egressAllow: egress },
    },
  })
  show('worker started; waiting for the DSH tree…')
} catch (error) {
  fail('DSH failed', `worker start failed: ${error instanceof Error ? error.message : String(error)}`)
}
