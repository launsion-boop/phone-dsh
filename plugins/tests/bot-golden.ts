// SPDX-License-Identifier: MIT
import { existsSync, readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const METADATA_KEYS = new Set(['schemaVersion', 'vector', 'source', 'upstream', 'delta'])

type JsonObject = Record<string, unknown>

function isObject(value: unknown): value is JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function goldenURL(name: string): URL {
  return new URL(`../../spec/bot/v1/golden/${name}.json`, import.meta.url)
}

export function readBotGolden(name: string): JsonObject {
  const value = JSON.parse(readFileSync(goldenURL(name), 'utf8')) as unknown
  if (!isObject(value)) throw new Error(`${name}.json is not an object`)
  return value
}

/** Load the upstream batch plus its same-name `.phone.json` overlay. */
export function readBotGoldenMerged(name: string): JsonObject {
  const upstream = readBotGolden(name)
  const overlayURL = goldenURL(`${name}.phone`)
  if (!existsSync(fileURLToPath(overlayURL))) return upstream
  const overlay = JSON.parse(readFileSync(overlayURL, 'utf8')) as unknown
  if (!isObject(overlay)) throw new Error(`${name}.phone.json is not an object`)
  return mergeObject(upstream, overlay)
}

function mergeObject(upstream: JsonObject, overlay: JsonObject): JsonObject {
  const merged: JsonObject = { ...upstream }
  for (const [key, value] of Object.entries(overlay)) {
    if (METADATA_KEYS.has(key)) continue
    if (key in merged) merged[key] = mergeValue(merged[key], value)
    else merged[key] = value
  }
  return merged
}

function mergeValue(upstream: unknown, overlay: unknown): unknown {
  if (isObject(upstream) && isObject(overlay)) return mergeObject(upstream, overlay)
  if (Array.isArray(upstream) && Array.isArray(overlay)) return mergeArray(upstream, overlay)
  return overlay
}

function mergeArray(upstream: unknown[], overlay: unknown[]): unknown[] {
  const merged = [...upstream]
  const positions = new Map<string, number>()
  merged.forEach((item, index) => {
    const identifier = identity(item)
    if (identifier !== null) positions.set(identifier, index)
  })
  const seen = new Set(merged.map(canonical))
  for (const item of overlay) {
    const identifier = identity(item)
    if (identifier !== null && positions.has(identifier)) {
      merged[positions.get(identifier)!] = item
      continue
    }
    const text = canonical(item)
    if (identifier === null && seen.has(text)) continue
    if (identifier !== null) positions.set(identifier, merged.length)
    seen.add(text)
    merged.push(item)
  }
  return merged
}

function identity(value: unknown): string | null {
  if (!isObject(value)) return null
  for (const key of ['name', 'id', 'nonce']) {
    const item = value[key]
    if (typeof item === 'string') return `${key}:${item}`
  }
  const action = value.action
  if (isObject(action) && typeof action.nonce === 'string') return `action.nonce:${action.nonce}`
  return null
}

function canonical(value: unknown): string {
  return JSON.stringify(sortKeys(value))
}

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys)
  if (!isObject(value)) return value
  return Object.fromEntries(Object.keys(value).sort().map(key => [key, sortKeys(value[key])]))
}
