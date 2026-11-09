// SPDX-License-Identifier: MIT
// PCLink normalized relay origin handling (§3.1).
//
// Origins are ASCII http(s) origins, lowercase only, default port omitted, no
// userinfo/path/query/fragment, maximum 128 characters.  A producer must not
// emit uppercase and a consumer must reject it rather than lowercasing it;
// `new URL()` would silently lowercase, so the raw string is checked first.

const ORIGIN_PATTERN = /^(https?):\/\/([a-z0-9][a-z0-9.-]*)(?::([0-9]{1,5}))?$/

export function normalizeOrigin(value) {
  if (typeof value !== 'string' || value.length === 0) throw new Error('origin must be a non-empty string')
  if (value.length > 128) throw new Error('origin exceeds 128 characters')
  if (value !== value.toLowerCase()) throw new Error('origin must be lowercase')
  const match = ORIGIN_PATTERN.exec(value)
  if (match === null) throw new Error('origin is not a canonical http(s) origin')
  let url
  try {
    url = new URL(value)
  } catch {
    throw new Error('origin is not a valid URL')
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') throw new Error('origin must be http(s)')
  if (url.username !== '' || url.password !== '') throw new Error('origin must not contain userinfo')
  if (url.pathname !== '/' && url.pathname !== '') throw new Error('origin must not contain a path')
  if (url.search !== '' || url.hash !== '') throw new Error('origin must not contain a query or fragment')
  if (url.hostname.startsWith('[') || url.hostname.includes(':')) {
    throw new Error('IPv6 literal origins are not used in v1')
  }
  // URL.origin drops a default port and canonicalizes the host; any mismatch
  // means the input was not the canonical spelling.
  if (url.origin !== value) throw new Error('origin is not canonical (default port omitted, no path)')
  return url.origin
}

export function isCanonicalOrigin(value) {
  try {
    normalizeOrigin(value)
    return true
  } catch {
    return false
  }
}

export function isLoopbackOrigin(origin) {
  let url
  try {
    url = new URL(origin)
  } catch {
    return false
  }
  return url.hostname === '127.0.0.1' || url.hostname === 'localhost'
}

export function originPort(origin) {
  const url = new URL(normalizeOrigin(origin))
  if (url.port !== '') return Number(url.port)
  return url.protocol === 'https:' ? 443 : 80
}

export function replaceOriginPort(origin, port) {
  const url = new URL(normalizeOrigin(origin))
  url.port = String(port)
  return normalizeOrigin(url.origin)
}
