// SPDX-License-Identifier: MIT
/**
 * Redaction for boot diagnostics shared by the page and Worker halves.
 *
 * A boot failure can carry the page URL, the Worker init frame or a Worker 503
 * body. Those values include the transport coordinates: the launch token, the
 * channel URL, image/overlay URLs, the fence, the page-supplied environment and
 * the egress allow-list. This module removes both the field syntax (a
 * `?token=` query or a serialized `"env":{...}`) and the exact captured values,
 * because an error body does not have to preserve the field name that carried
 * the secret.
 *
 * The result is whitespace-collapsed and length-bounded so it can be painted
 * into a failure page or written to the native console log without copying a
 * raw URL, token or environment object out of the device.
 *
 * @module @phone-dsh/dsh-worker-entry/boot-redaction
 */

/** Transport query keys read by the page boot and the minimal boot page. */
export const BOOT_TRANSPORT_PARAMS: ReadonlySet<string> = new Set([
  'image',
  'channel',
  'channelURL',
  'token',
  'overlay',
  'overlay[]',
  'fence',
  'env',
  'egress',
  'egress_allow',
  'egressAllow',
  'boot_id',
  'bootId',
  'session_epoch',
  'sessionEpoch',
])

/** Longest technical detail kept in a visible failure or console line. */
export const BOOT_FAILURE_DETAIL_LIMIT = 320

/** The boot coordinates whose exact values must not survive in a diagnostic. */
export interface BootTransportFrame {
  readonly image?: string
  readonly overlays?: readonly string[]
  readonly xl?: Readonly<Record<string, unknown>>
}

/** Values shorter than this are skipped so ordinary words are not mangled. */
const MIN_SECRET_LENGTH = 3

/**
 * Header/field names that carry a credential. A transport layer may rename the
 * standard header (`X-PDSH-Upstream-Authorization`, `x-auth-token`) while
 * keeping its meaning, so match the semantic word under any prefix/suffix
 * rather than only the exact `Authorization` spelling.
 */
const COOKIE_FIELD_NAME = '[a-z0-9-]*cookie[a-z0-9-]*'

const CREDENTIAL_FIELD_NAME = [
  '[a-z0-9-]*authorization[a-z0-9-]*',
  'x-[a-z0-9-]*(?:api-?key|token|secret|auth)[a-z0-9-]*',
  '[a-z0-9-]*(?:api-?key|auth-token|access-token|client-secret|session-token)',
].join('|')

/** Every credential-shaped name, for the cookie rule's "next header" boundary. */
const CREDENTIAL_HEADER_NAME = `${COOKIE_FIELD_NAME}|${CREDENTIAL_FIELD_NAME}`

/**
 * A header or field assignment whose value is opaque. A non-cookie value stops
 * at a comma or the end of the line, so unrelated fields after it survive. The
 * quoting alternatives keep a serialized value from swallowing the next key.
 */
const CREDENTIAL_HEADER_VALUE = new RegExp(
  `\\b((?:${CREDENTIAL_FIELD_NAME})\\s*["']?\\s*[:=]\\s*)(?:"[^"]*"|'[^']*'|[^,\\r\\n]+)`,
  'gi',
)

/**
 * Cookie values are a semicolon-separated list and may contain commas; removing
 * only the first pair would leave the rest of the session behind. Consume to
 * the next credential-shaped header or the end of the line instead.
 */
const COOKIE_HEADER_VALUE = new RegExp(
  `\\b(${COOKIE_FIELD_NAME}\\s*["']?\\s*[:=]\\s*)(?:"[^"]*"|'[^']*'|(?:(?!(?<![a-z0-9-])(?:${CREDENTIAL_HEADER_NAME})\\s*["']?\\s*[:=])[^\\r\\n])+)`,
  'gi',
)

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function addSecret(values: Set<string>, value: unknown): void {
  if (typeof value !== 'string' || value.length < MIN_SECRET_LENGTH) return
  values.add(value)
  try {
    const encoded = encodeURIComponent(value)
    if (encoded !== value) values.add(encoded)
  } catch {
    // A lone surrogate cannot be percent-encoded; the raw value is still queued.
  }
  const jsonEscaped = JSON.stringify(value)
  if (jsonEscaped !== undefined) values.add(jsonEscaped.slice(1, -1))
}

function addJsonValue(values: Set<string>, value: unknown): void {
  try {
    const json = JSON.stringify(value, (_key, member: unknown) =>
      typeof member === 'bigint' ? member.toString(10) : member)
    if (json !== undefined && json.length >= MIN_SECRET_LENGTH) values.add(json)
  } catch {
    // A cyclic thrown value cannot also be a URL/init value; skip it.
  }
}

function addObjectValues(values: Set<string>, value: unknown): void {
  if (value === null || typeof value !== 'object') return
  if (Array.isArray(value)) {
    for (const member of value) addSecret(values, member)
    return
  }
  for (const member of Object.values(value as Record<string, unknown>)) addSecret(values, member)
}

function addUrlValues(values: Set<string>, raw: string | undefined, base: string): void {
  if (raw === undefined || raw === '') return
  addSecret(values, raw)
  try {
    const url = new URL(raw, base)
    for (const [name, value] of url.searchParams) {
      if (BOOT_TRANSPORT_PARAMS.has(name)) addSecret(values, value)
    }
  } catch {
    // A non-URL image/overlay is still covered by the raw value above.
  }
}

/**
 * Extract the exact transport values from a page query or Worker init frame.
 *
 * Only string values become replacements; short values are skipped so a
 * one-letter environment value cannot erase the useful part of the diagnostic.
 * URL query values are included even when the matching `xl` field is absent.
 * @param frame - image, overlays and `xl` values already parsed into memory.
 * @param base - base URL for relative image/overlay/channel references.
 * @returns unique secret strings, longest first so a prefix cannot hide a
 *   longer match.
 */
export function bootTransportSecretValues(
  frame: BootTransportFrame,
  base = 'http://127.0.0.1/',
): string[] {
  const values = new Set<string>()
  addUrlValues(values, frame.image, base)
  for (const overlay of frame.overlays ?? []) addUrlValues(values, overlay, base)
  const xl = frame.xl ?? {}
  addUrlValues(values, typeof xl['channelURL'] === 'string' ? xl['channelURL'] : undefined, base)
  addUrlValues(values, typeof xl['channelUrl'] === 'string' ? xl['channelUrl'] : undefined, base)
  for (const name of ['token', 'channel', 'bootId', 'boot_id', 'sessionEpoch', 'session_epoch']) {
    addSecret(values, xl[name])
  }
  for (const name of ['env', 'fence', 'egressAllow', 'egress_allow']) {
    const value = xl[name]
    addObjectValues(values, value)
    addJsonValue(values, value)
  }
  return [...values].sort((left, right) => right.length - left.length)
}

/**
 * Bound and redact a boot failure detail before it reaches the UI or console.
 *
 * Transport secrets can appear in fetch/navigation errors and in the Worker's
 * 503 body, sometimes without their field name. The well-known field shapes are
 * replaced first, then every exact value captured from the init frame is
 * replaced. The rest of the diagnostic is kept, whitespace-collapsed and
 * length-bounded so a raw URL, environment object or token cannot be copied
 * from a screenshot or log.
 * @param reason - failure thrown by the handshake or Worker boot.
 * @param secrets - exact transport values from {@link bootTransportSecretValues}.
 * @returns at most {@link BOOT_FAILURE_DETAIL_LIMIT} characters plus an ellipsis.
 */
export function redactBootFailureDetail(
  reason: unknown,
  secrets: readonly string[] = [],
): string {
  let text: string
  try {
    text = reason instanceof Error ? `${reason.name}: ${reason.message}` : String(reason)
  } catch {
    // Exotic thrown values must not replace the original boot failure.
    return 'unknown error'
  }
  text = text
    // Environment/fence/egress objects or arrays, quoted or bare, BEFORE the
    // generic query rule. A query rule that stops at `{`/`[` would leave the
    // object body (`?env={"PDSH_LAUNCH_TOKEN":"secret"}`) behind as raw text.
    .replace(/("(?:env|fence|egress(?:Allow|_allow)?)"\s*:\s*)(\{[^}]*\}|\[[^\]]*\])/gi, '$1[redacted]')
    .replace(/\b(env|fence|egress(?:Allow|_allow)?)\s*=\s*(\{[^}]*\}|\[[^\]]*\])/gi, '$1=[redacted]')
    // URL query values for every boot transport key. Allow braces/brackets so
    // a malformed JSON body is still consumed as one value.
    .replace(
      /([?&](?:token|image|channel(?:URL)?|overlay(?:\[\])?|fence|env|egress(?:_allow|Allow)?|boot_id|bootId|session_epoch|sessionEpoch)=)[^&#\s"'<>]*/gi,
      '$1[redacted]',
    )
    // Any credential-shaped header, not only `Authorization: Bearer` and the
    // boot transport keys. Cookies go first because their semicolon-separated
    // value needs a different boundary; then every other header loses its value
    // before the narrower rules so a renamed `x-api-key` cannot survive
    // half-redacted.
    .replace(COOKIE_HEADER_VALUE, '$1[redacted]')
    .replace(CREDENTIAL_HEADER_VALUE, '$1[redacted]')
    .replace(/(Authorization\s*:\s*Bearer\s+)[^\s,;]+/gi, '$1[redacted]')
    // JSON string fields (a serialized init frame can carry the token).
    .replace(
      /("(?:token|image|channel(?:URL)?|overlay(?:\[\])?|fence|env|egress(?:_allow|Allow)?|boot_id|bootId|session_epoch|sessionEpoch)"\s*:\s*")[^"]*"/gi,
      '$1[redacted]"',
    )
    // A field spelled without its leading `?`/`&` (for example a Worker body),
    // including an object/array value the shape rules above did not match.
    .replace(
      /\b(token|image|channel(?:URL)?|overlay(?:\[\])?|fence|env|egress(?:_allow|Allow)?|boot_id|bootId|session_epoch|sessionEpoch)\s*=\s*[^\s,;&<>]+/gi,
      '$1=[redacted]',
    )
  const exact = [...new Set(secrets.filter(secret => typeof secret === 'string' && secret.length > 0))]
  if (exact.length > 0) {
    text = text.replace(
      new RegExp(exact.map(escapeRegExp).join('|'), 'g'),
      '[redacted]',
    )
  }
  text = text.replace(/\s+/g, ' ').trim()
  return text.length > BOOT_FAILURE_DETAIL_LIMIT
    ? `${text.slice(0, BOOT_FAILURE_DETAIL_LIMIT)}…`
    : text
}

/**
 * Build the safe Error a boot consumer may log or paint.
 *
 * The returned error has only the redacted message as its stack input: it never
 * carries the raw failure as `cause`, so the client's `console.error(reason)`
 * and `BootPage.fail(reason.message)` cannot recover the secret.
 * @param reason - raw boot failure.
 * @param secrets - exact transport values captured before the failure.
 * @returns a new Error with a bounded, redacted message.
 */
export function bootFailureError(reason: unknown, secrets: readonly string[] = []): Error {
  return new Error(redactBootFailureDetail(reason, secrets))
}
