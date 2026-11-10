// SPDX-License-Identifier: MIT
// IP parsing and per-source-IP keying.
//
// PCLink counts IPv6 sources by their /64 prefix (§3.5).  X-Forwarded-For is
// consulted only when the direct peer is in PCLINK_TRUSTED_PROXIES; otherwise
// it is ignored.  All returned keys are opaque strings, not addresses, so the
// caller can log a hash without retaining the raw address.

import net from 'node:net'

export function stripAddress(address) {
  if (typeof address !== 'string') return ''
  let value = address.trim()
  if (value.startsWith('[') && value.endsWith(']')) value = value.slice(1, -1)
  const zone = value.indexOf('%')
  if (zone !== -1) value = value.slice(0, zone)
  value = value.toLowerCase()
  if (value.startsWith('::ffff:')) {
    const mapped = value.slice('::ffff:'.length)
    if (net.isIP(mapped) === 4) return mapped
  }
  return value
}

export function isIPv4(address) {
  return net.isIP(stripAddress(address)) === 4
}

export function isIPv6(address) {
  return net.isIP(stripAddress(address)) === 6
}

function ipv4Bytes(text) {
  return Uint8Array.from(text.split('.').map(part => Number(part)))
}

function expandTailIpv4(text) {
  if (!text.includes('.')) return text
  const lastColon = text.lastIndexOf(':')
  const tail = text.slice(lastColon + 1)
  if (net.isIP(tail) !== 4) throw new Error('bad IPv4 suffix in IPv6 address')
  const [a, b, c, d] = tail.split('.').map(Number)
  const first = ((a << 8) | b).toString(16)
  const second = ((c << 8) | d).toString(16)
  return `${text.slice(0, lastColon + 1)}${first}:${second}`
}

function ipv6Hextets(address) {
  let text = stripAddress(address)
  if (net.isIP(text) !== 6) throw new Error('not an IPv6 address')
  text = expandTailIpv4(text)
  const halves = text.split('::')
  if (halves.length > 2) throw new Error('bad IPv6 address')
  const head = halves[0] === '' ? [] : halves[0].split(':')
  const tail = halves.length === 2 ? (halves[1] === '' ? [] : halves[1].split(':')) : []
  if (halves.length === 1 && head.length !== 8) throw new Error('bad IPv6 address')
  if (halves.length === 2 && head.length + tail.length > 8) throw new Error('bad IPv6 address')
  const values = []
  for (const part of head) {
    if (!/^[0-9a-f]{1,4}$/.test(part)) throw new Error('bad IPv6 hextet')
    values.push(Number.parseInt(part, 16))
  }
  if (halves.length === 2) {
    for (let index = 0; index < 8 - head.length - tail.length; index += 1) values.push(0)
  }
  for (const part of tail) {
    if (!/^[0-9a-f]{1,4}$/.test(part)) throw new Error('bad IPv6 hextet')
    values.push(Number.parseInt(part, 16))
  }
  if (values.length !== 8) throw new Error('bad IPv6 address')
  return values
}

export function parseIpBytes(address) {
  const value = stripAddress(address)
  const family = net.isIP(value)
  if (family === 4) return { family: 4, bytes: ipv4Bytes(value) }
  if (family === 6) {
    const hextets = ipv6Hextets(value)
    const bytes = new Uint8Array(16)
    hextets.forEach((hextet, index) => {
      bytes[index * 2] = hextet >>> 8
      bytes[index * 2 + 1] = hextet & 0xff
    })
    return { family: 6, bytes }
  }
  return null
}

export function ipKey(address) {
  const value = stripAddress(address)
  const family = net.isIP(value)
  if (family === 4) return value
  if (family === 6) {
    const hextets = ipv6Hextets(value)
    return `${hextets.slice(0, 4).map(part => part.toString(16)).join(':')}::/64`
  }
  return 'unknown'
}

export function parseTrustedProxies(value) {
  if (value === undefined || value === null || value === '') return []
  const entries = Array.isArray(value) ? value : String(value).split(',')
  const parsed = []
  for (const rawEntry of entries) {
    // accept an already-parsed entry so createRelayServer(loadConfig(...)) is
    // idempotent
    if (rawEntry !== null && typeof rawEntry === 'object'
      && (rawEntry.family === 4 || rawEntry.family === 6)
      && rawEntry.bytes !== undefined && Number.isInteger(rawEntry.prefix)) {
      parsed.push({
        family: rawEntry.family,
        bytes: Uint8Array.from(rawEntry.bytes),
        prefix: rawEntry.prefix,
      })
      continue
    }
    const entry = String(rawEntry).trim()
    if (entry === '') continue
    const slash = entry.indexOf('/')
    const ipText = slash === -1 ? entry : entry.slice(0, slash)
    const parsedIp = parseIpBytes(ipText)
    if (parsedIp === null) throw new Error(`PCLINK_TRUSTED_PROXIES: invalid IP ${JSON.stringify(ipText)}`)
    let prefix = parsedIp.family === 4 ? 32 : 128
    if (slash !== -1) {
      const prefixText = entry.slice(slash + 1)
      if (!/^[0-9]{1,3}$/.test(prefixText)) throw new Error(`PCLINK_TRUSTED_PROXIES: invalid prefix ${JSON.stringify(entry)}`)
      prefix = Number(prefixText)
      if (prefix > (parsedIp.family === 4 ? 32 : 128)) {
        throw new Error(`PCLINK_TRUSTED_PROXIES: prefix out of range ${JSON.stringify(entry)}`)
      }
    }
    parsed.push({ family: parsedIp.family, bytes: parsedIp.bytes, prefix })
  }
  return parsed
}

function samePrefix(left, right) {
  if (left.family !== right.family) return false
  const fullBytes = Math.floor(left.prefix / 8)
  const remainder = left.prefix % 8
  for (let index = 0; index < fullBytes; index += 1) {
    if (left.bytes[index] !== right.bytes[index]) return false
  }
  if (remainder === 0) return true
  const mask = 0xff << (8 - remainder)
  return (left.bytes[fullBytes] & mask) === (right.bytes[fullBytes] & mask)
}

export function isTrustedIp(address, trustedProxies) {
  if (!Array.isArray(trustedProxies) || trustedProxies.length === 0) return false
  const parsed = parseIpBytes(address)
  if (parsed === null) return false
  return trustedProxies.some(proxy => samePrefix(proxy, parsed))
}

function xffEntries(header) {
  if (header === undefined || header === null) return []
  const text = Array.isArray(header) ? header.join(',') : String(header)
  return text.split(',').map(part => stripAddress(part)).filter(part => net.isIP(part) !== 0)
}

// Resolve the source address used for per-IP limits.  With a trusted direct
// peer, walk X-Forwarded-For from right to left and take the first address that
// is not itself a trusted proxy.  Without a trusted peer, XFF is ignored.
export function resolveClientIp(remoteAddress, forwardedFor, trustedProxies) {
  const remote = stripAddress(remoteAddress)
  if (net.isIP(remote) === 0) return 'unknown'
  if (!isTrustedIp(remote, trustedProxies)) return remote
  const entries = xffEntries(forwardedFor)
  if (entries.length === 0) return remote
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    if (!isTrustedIp(entries[index], trustedProxies)) return entries[index]
  }
  return entries[0]
}
