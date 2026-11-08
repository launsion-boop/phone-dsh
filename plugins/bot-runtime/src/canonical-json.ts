// SPDX-License-Identifier: MIT

export function canonicalStringify(value: unknown): string {
  return JSON.stringify(normalize(value))
}

function normalize(value: unknown): unknown {
  if (value === null || typeof value !== 'object') return value
  if (Array.isArray(value)) return value.map(normalize)
  const entries = Object.entries(value as Record<string, unknown>)
    .filter(([, member]) => member !== undefined)
    .sort(([left], [right]) => left < right ? -1 : left > right ? 1 : 0)
  return Object.fromEntries(entries.map(([key, member]) => [key, normalize(member)]))
}
