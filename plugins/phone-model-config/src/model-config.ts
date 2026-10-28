// SPDX-License-Identifier: MIT
/**
 * Read-only model provider projection for the phone Worker settings tab.
 *
 * The host app writes `PDSH_MODEL_PROVIDER_JSON` into the Worker environment
 * before boot. It contains only the selected provider's id, display name,
 * endpoint, model and optional reasoning effort — never an API key and never a
 * Keychain reference. This module parses that value defensively and returns a
 * frozen snapshot the browser tab can render without mutating anything.
 * @module @phone-dsh/dsh-phone-model-config/model-config
 */

/** Environment variable carrying the host's non-secret provider document. */
export const MODEL_PROVIDER_ENV = 'PDSH_MODEL_PROVIDER_JSON'

/** One provider as published to the Worker; deliberately contains no secret. */
export interface ProviderPublicConfig {
  readonly id: string
  readonly displayName: string
  readonly baseURL: string
  readonly model: string
  readonly reasoningEffort?: string
}

/** Facts about where the key lives, repeated to the page without its value. */
export interface CredentialProjection {
  readonly storage: 'device-keychain'
  readonly injectedBy: 'host'
  readonly writable: false
}

/**
 * One machine-readable reason the projection is unavailable.
 *
 * The Host never ships user-facing English (or any other locale) here: the
 * browser owns copy and maps this code through its own locale namespace.
 */
export type ModelConfigIssueCode =
  | 'env-missing'
  | 'json-invalid'
  | 'document-not-object'
  | 'version-unsupported'
  | 'providers-empty'
  | 'provider-invalid'
  | 'duplicate-provider-id'
  | 'selected-missing'
  | 'selected-unknown'

/** Structured diagnostic for a missing or invalid projection. */
export interface ModelConfigIssue {
  readonly code: ModelConfigIssueCode
  /** Provider id involved in the issue, when one is known. */
  readonly providerId?: string
}

/** The read-only result the `phone/modelConfig` Remote returns. */
export type ModelConfigSnapshot =
  | {
    readonly configured: false
    readonly reason: 'missing' | 'invalid'
    readonly detail: ModelConfigIssue
    readonly credential: CredentialProjection
  }
  | {
    readonly configured: true
    readonly selectedId: string
    readonly selected: ProviderPublicConfig
    readonly providers: readonly ProviderPublicConfig[]
    readonly credential: CredentialProjection
  }

/** Where the browser may say the key is; the Worker cannot read the value. */
export const CREDENTIAL_PROJECTION: CredentialProjection = Object.freeze({
  storage: 'device-keychain',
  injectedBy: 'host',
  writable: false,
})

/** A non-empty, whitespace-free profile id that can be a Keychain account suffix. */
const PROFILE_ID = /^[^\s\u0000-\u001f]+$/u

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function stringField(value: unknown, name: string): string | undefined {
  if (typeof value !== 'string') return undefined
  const trimmed = value.trim()
  if (trimmed === '') throw new Error(`${name} must not be empty`)
  return trimmed
}

/** Parse one provider row, dropping every field the page must never receive. */
function publicProvider(value: unknown): ProviderPublicConfig {
  if (!isRecord(value)) throw new Error('provider entry must be an object')
  const id = stringField(value['id'], 'provider id')
  if (id === undefined || !PROFILE_ID.test(id)) throw new Error('provider id is invalid')
  const displayName = stringField(value['displayName'], 'provider displayName')
  const model = stringField(value['model'], 'provider model')
  const rawBaseURL = stringField(value['baseURL'], 'provider baseURL')
  if (displayName === undefined || model === undefined || rawBaseURL === undefined) {
    throw new Error('provider is missing displayName, model or baseURL')
  }
  let url: URL
  try {
    url = new URL(rawBaseURL)
  } catch {
    throw new Error('provider baseURL is not a valid URL')
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new Error('provider baseURL must use http or https')
  }
  if (url.hostname === '' || url.username !== '' || url.password !== '' || url.search !== '' || url.hash !== '') {
    throw new Error('provider baseURL must name a host without credentials, query or fragment')
  }
  const rawEffort = value['reasoningEffort']
  if (rawEffort !== undefined && typeof rawEffort !== 'string') {
    throw new Error('provider reasoningEffort must be a string when present')
  }
  const reasoningEffort = typeof rawEffort === 'string' && rawEffort.trim() !== '' ? rawEffort.trim() : undefined
  return Object.freeze({
    id,
    displayName,
    baseURL: rawBaseURL,
    model,
    ...(reasoningEffort === undefined ? {} : { reasoningEffort }),
  })
}

function issue(code: ModelConfigIssueCode, providerId?: string): ModelConfigIssue {
  return Object.freeze({
    code,
    ...(providerId === undefined ? {} : { providerId }),
  })
}

function invalid(detail: ModelConfigIssue): ModelConfigSnapshot {
  return Object.freeze({
    configured: false as const,
    reason: 'invalid' as const,
    detail,
    credential: CREDENTIAL_PROJECTION,
  })
}

/**
 * Parse the host-published provider document.
 *
 * A missing variable is an honest "not configured" state, not an error. A
 * malformed document is an explicit invalid state: the page renders the reason
 * and never falls back to a fabricated provider. Unknown fields (including a
 * mistakenly supplied key) are ignored by construction.
 * @param environment - environment mapping; defaults to the Worker process env.
 * @returns a frozen projection safe to send to the browser.
 */
export function readModelConfig(
  environment: { readonly [name: string]: string | undefined } = process.env,
): ModelConfigSnapshot {
  const raw = environment[MODEL_PROVIDER_ENV]
  if (typeof raw !== 'string' || raw.trim() === '') {
    return Object.freeze({
      configured: false as const,
      reason: 'missing' as const,
      detail: issue('env-missing'),
      credential: CREDENTIAL_PROJECTION,
    })
  }
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return invalid(issue('json-invalid'))
  }
  if (!isRecord(parsed)) return invalid(issue('document-not-object'))
  if (parsed['version'] !== 1) return invalid(issue('version-unsupported'))
  if (!Array.isArray(parsed['providers']) || parsed['providers'].length === 0) {
    return invalid(issue('providers-empty'))
  }
  const providers: ProviderPublicConfig[] = []
  const seen = new Set<string>()
  for (const entry of parsed['providers']) {
    let provider: ProviderPublicConfig
    try {
      provider = publicProvider(entry)
    } catch {
      const rawId = isRecord(entry) && typeof entry['id'] === 'string' ? entry['id'] : undefined
      return invalid(issue('provider-invalid', rawId))
    }
    if (seen.has(provider.id)) return invalid(issue('duplicate-provider-id', provider.id))
    seen.add(provider.id)
    providers.push(provider)
  }
  const selectedId = parsed['selectedId']
  if (typeof selectedId !== 'string' || selectedId.trim() === '') {
    return invalid(issue('selected-missing'))
  }
  const selected = providers.find(provider => provider.id === selectedId)
  if (selected === undefined) return invalid(issue('selected-unknown', selectedId))
  return Object.freeze({
    configured: true as const,
    selectedId,
    selected,
    providers: Object.freeze(providers),
    credential: CREDENTIAL_PROJECTION,
  })
}
