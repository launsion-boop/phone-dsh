// SPDX-License-Identifier: MIT
/**
 * The Android WebView gate must measure the same surface the Worker runs on.
 *
 * `WebViewKernelProbe.SCRIPT` (Kotlin, `android/engine`) decides whether a
 * WebView may run this Worker. The Worker's first imports are its prelude —
 * `boot.ts` imports `./jsc-compat.ts`, `./es2023-compat.ts`,
 * `./abort-signal-compat.ts` and `./scheduler-compat.ts` before any DSH module
 * evaluates — so the gate is only honest if it measures the engine *after*
 * that prelude. The probe carries a copy of the prelude for the page realm
 * (same engine, different global), because Chromium <124 has no native
 * `ReadableStream` async iteration and would otherwise be refused on kernels
 * that actually work: the bug measured on the `android-33` image (WebView
 * 109.0.5414.123).
 *
 * A copy can drift — the probe once installed only `@@asyncIterator` while the
 * prelude installed `values` and `@@asyncIterator` as one function object, so
 * the gate measured a weaker surface than the Worker got. This file therefore
 * extracts the properties both sides install, runs the *real* installers of
 * the four prelude modules (no copy), evaluates the *real* Kotlin script on an
 * engine made bare exactly where the prelude patches, and fails — naming the
 * missing property — when the probe's surface is not a superset of the
 * prelude's.
 * @module @phone-dsh/dsh-worker-entry/webview-kernel-probe.test
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

import { installAbortSignalAny, type AbortSignalCompatScope } from './abort-signal-compat.ts'
import { installEs2023Compat, type Es2023CompatScope } from './es2023-compat.ts'
import { createStubSymbol } from './fixtures/jsc-stub-globals.ts'
import { installJscCompat, type JscCompatScope } from './jsc-compat.ts'
import { installSchedulerYield, type SchedulerCompatScope } from './scheduler-compat.ts'

const here = dirname(fileURLToPath(import.meta.url))
const KOTLIN_SOURCE = join(
  here, '..', '..', '..',
  'android', 'engine', 'src', 'main', 'kotlin', 'com', 'phonedsh', 'engine', 'WebViewKernel.kt',
)

/** The four ids `WebViewKernelProbe.parse` accepts. */
const FEATURE_IDS = [
  'decompression-stream-gzip',
  'readable-stream-async-iteration',
  'readable-stream-pipe-through',
  'symbol-dispose',
] as const

/**
 * Read `WebViewKernelProbe.SCRIPT` out of the Kotlin source.
 *
 * The declaration is a raw string followed by `.trimIndent()`, so the test
 * applies the same dedent: drop the delimiter-only first/last lines and the
 * common leading whitespace.
 * @returns The JavaScript the WebView evaluates.
 */
function kotlinProbeScript(): string {
  const text = readFileSync(KOTLIN_SOURCE, 'utf8')
  const match = /public val SCRIPT: String = """\n([\s\S]*?)\n *"""\.trimIndent\(\)/.exec(text)
  if (match === null) {
    throw new Error(`${KOTLIN_SOURCE} no longer declares SCRIPT as a """ raw string plus trimIndent()`)
  }
  const lines = (match[1] ?? '').split('\n')
  const indents = lines
    .filter(line => line.trim() !== '')
    .map(line => /^ */.exec(line)![0].length)
  const common = indents.length === 0 ? 0 : Math.min(...indents)
  return lines.map(line => line.slice(common)).join('\n')
}

/** One probe run in a child process, so prototype edits stay isolated. */
interface ProbeRun {
  readonly ua: string
  readonly features: Record<string, boolean>
}

/** `ReadableStream` async-iteration methods to delete before the probe runs. */
type StreamMethod = 'values' | 'asyncIterator'

/**
 * Evaluate the extracted script in a fresh Node process.
 * @param script - The probe body from the Kotlin source.
 * @param missing - Native stream method(s) to delete first: both is the
 *   Chromium-109 shape, `['asyncIterator']` is the partially-native shape.
 * @returns The decoded probe result.
 */
function runProbe(script: string, missing: readonly StreamMethod[]): ProbeRun {
  const program = `
    if (typeof navigator === 'undefined') globalThis.navigator = { userAgent: 'probe-test' }
    if (${missing.includes('values')}) delete ReadableStream.prototype.values
    if (${missing.includes('asyncIterator')}) delete ReadableStream.prototype[Symbol.asyncIterator]
    const source = ${JSON.stringify(script)}
    process.stdout.write(eval(source))
  `
  const child = spawnSync(process.execPath, ['-'], { input: program, encoding: 'utf8' })
  assert.equal(child.status, 0, `probe child failed:\n${child.stderr}${child.stdout}`)
  const parsed: unknown = JSON.parse(child.stdout)
  assert.ok(parsed !== null && typeof parsed === 'object', 'the probe must return a JSON object')
  const run = parsed as ProbeRun
  assert.equal(typeof run.ua, 'string')
  return run
}

/**
 * One property that a prelude (or the probe's copy of it) installs.
 *
 * `carrier` is a dotted path from `globalThis` (`'globalThis'`, `'Symbol'`,
 * `'ReadableStream.prototype'`, `'scheduler'`, ...). `key` is either a string
 * property name or a well-known `Symbol` name such as `asyncIterator`.
 */
interface PatchedProperty {
  readonly carrier: string
  readonly key: string | { readonly wellKnown: string }
}

/** `global`, `Symbol.dispose`, `ReadableStream.prototype[Symbol.asyncIterator]`, ... */
function surfaceName(property: PatchedProperty): string {
  if (typeof property.key === 'string') {
    return property.carrier === 'globalThis' ? property.key : `${property.carrier}.${property.key}`
  }
  const symbol = `[Symbol.${property.key.wellKnown}]`
  return property.carrier === 'globalThis' ? symbol : `${property.carrier}${symbol}`
}

/** The child-process form: `{ carrier, key, wellKnown }`, resolvable by lookup. */
interface SerializedPatch {
  readonly carrier: string
  readonly key: string
  readonly wellKnown: boolean
}

/** Flatten an entry so a child process can resolve `Symbol[key]` vs `target[key]`. */
function serialize(property: PatchedProperty): SerializedPatch {
  return typeof property.key === 'string'
    ? { carrier: property.carrier, key: property.key, wellKnown: false }
    : { carrier: property.carrier, key: property.key.wellKnown, wellKnown: true }
}

/** Well-known symbols this extraction can name (`Symbol.asyncIterator`, ...). */
const WELL_KNOWN_SYMBOLS: ReadonlyArray<readonly [symbol, string]> = [
  [Symbol.asyncIterator, 'asyncIterator'],
  [Symbol.iterator, 'iterator'],
]

/** The bare name of a well-known symbol; the extraction only installs those. */
function wellKnownName(key: symbol): string {
  for (const [symbol, name] of WELL_KNOWN_SYMBOLS) {
    if (symbol === key) return name
  }
  return Symbol.keyFor(key) ?? key.description ?? String(key)
}

/**
 * The properties the Worker prelude installs, extracted by invoking its **real**
 * installers (imported from `boot.ts`'s four modules) against a stub scope.
 *
 * `Object.defineProperty` is intercepted for the duration of the calls. The
 * installers receive the scope as an argument, so every definition lands on an
 * object whose surface path this function registered; a prelude change that
 * adds a property shows up here without touching this test.
 * @returns The installed properties, in the prelude's install order.
 */
function preludeSurface(): PatchedProperty[] {
  const carriers = new Map<object, string>()
  const register = <T extends object>(path: string, value: T): T => {
    carriers.set(value, path)
    return value
  }

  // A bare engine: every prelude feature is missing, so each installer takes
  // its "install" branch instead of being skipped by native feature detection.
  // The scope object *is* the `globalThis` carrier, because `jsc-compat.ts`
  // installs the Node `global` alias on the scope it is handed.
  const scope = register('globalThis', {} as Record<PropertyKey, unknown>)
  scope.Symbol = register('Symbol', createStubSymbol())
  const streamPrototype = register('ReadableStream.prototype', {} as Record<PropertyKey, unknown>)
  scope.ReadableStream = register(
    'ReadableStream',
    Object.assign(function ReadableStreamStub(): void {}, { prototype: streamPrototype }),
  )
  scope.Promise = register('Promise', {} as Record<PropertyKey, unknown>)
  scope.AbortSignal = register('AbortSignal', {} as Record<PropertyKey, unknown>)
  scope.AbortController = function AbortControllerStub(): void {}
  scope.Array = { prototype: register('Array.prototype', {} as Record<PropertyKey, unknown>) }
  scope.String = { prototype: register('String.prototype', {} as Record<PropertyKey, unknown>) }
  scope.scheduler = register('scheduler', {} as Record<PropertyKey, unknown>)
  scope.setTimeout = (): number => 0

  const patched: PatchedProperty[] = []
  const originalDefineProperty = Object.defineProperty
  const record = (target: object, key: PropertyKey, descriptor: PropertyDescriptor): void => {
    const carrier = carriers.get(target)
    if (carrier !== undefined) {
      const name = typeof key === 'symbol' ? wellKnownName(key) : String(key)
      patched.push({ carrier, key: typeof key === 'symbol' ? { wellKnown: name } : name })
      // A definition that creates an object (jsc-compat has none, the scheduler
      // does) becomes a carrier too, so a follow-up patch is attributable.
      const value = descriptor.value as unknown
      if (typeof value === 'object' || typeof value === 'function') {
        if (value !== null && !carriers.has(value)) {
          carriers.set(value, carrier === 'globalThis' ? name : `${carrier}.${name}`)
        }
      }
    }
    originalDefineProperty(target, key, descriptor)
  }
  Object.defineProperty = record as unknown as typeof Object.defineProperty
  try {
    // The order `boot.ts` imports them in.
    installJscCompat(scope as unknown as JscCompatScope)
    installEs2023Compat(scope as unknown as Es2023CompatScope)
    installAbortSignalAny(scope as unknown as AbortSignalCompatScope)
    installSchedulerYield(scope as unknown as SchedulerCompatScope)
  } finally {
    Object.defineProperty = originalDefineProperty
  }
  return patched
}

/**
 * The properties `WebViewKernelProbe.SCRIPT` installs, extracted by evaluating
 * the real script in a child process.
 *
 * The child starts from an engine made bare **exactly where the Worker prelude
 * patches**: every property in `prelude` is deleted first (plus the `Symbol`
 * binding, whose well-known properties are non-configurable), so the probe's
 * copy takes its "install" branch for each. `Object.defineProperty` is
 * intercepted while the script runs and each definition is attributed to a
 * registered carrier, the same way {@link preludeSurface} does it.
 * @param prelude - The surface the Worker prelude installs, used as the list of
 *   natives to remove before the probe runs.
 * @returns The properties the probe installed.
 */
function probeSurface(prelude: readonly PatchedProperty[]): string[] {
  const program = `
    if (typeof navigator === 'undefined') globalThis.navigator = { userAgent: 'probe-surface-test' }
    const entries = ${JSON.stringify(prelude.map(serialize))}
    const script = ${JSON.stringify(kotlinProbeScript())}

    const realSymbol = Symbol
    function stubSymbol(description) { return realSymbol(description) }
    for (const key of Reflect.ownKeys(realSymbol)) {
      if (key === 'dispose' || key === 'asyncDispose' || key === 'prototype' || key === 'length' || key === 'name') continue
      const descriptor = Object.getOwnPropertyDescriptor(realSymbol, key)
      if (descriptor !== undefined) Object.defineProperty(stubSymbol, key, descriptor)
    }
    stubSymbol.prototype = realSymbol.prototype
    globalThis.Symbol = stubSymbol

    function carrier(path) {
      if (path === 'globalThis') return globalThis
      let current = globalThis
      for (const segment of path.split('.')) {
        if (current === undefined || current === null) return undefined
        current = current[segment]
      }
      return current
    }
    for (const entry of entries) {
      const target = carrier(entry.carrier)
      if (target === undefined || target === null) continue
      const key = entry.wellKnown ? realSymbol[entry.key] : entry.key
      const descriptor = Object.getOwnPropertyDescriptor(target, key)
      if (descriptor === undefined || descriptor.configurable === false) continue
      delete target[key]
    }

    const paths = new Map([
      [globalThis, 'globalThis'],
      [globalThis.Symbol, 'Symbol'],
      [ReadableStream.prototype, 'ReadableStream.prototype'],
      [Promise, 'Promise'],
      [AbortSignal, 'AbortSignal'],
      [Array.prototype, 'Array.prototype'],
      [String.prototype, 'String.prototype'],
    ])
    const recorded = []
    function keyLabel(key) {
      if (typeof key === 'string') return key
      if (key === realSymbol.asyncIterator) return 'Symbol.asyncIterator'
      if (key === realSymbol.iterator) return 'Symbol.iterator'
      return String(key)
    }
    function label(carrierPath, key) {
      const name = keyLabel(key)
      if (carrierPath === 'globalThis') return name
      return typeof key === 'string' ? carrierPath + '.' + name : carrierPath + '[' + name + ']'
    }
    const realDefineProperty = Object.defineProperty
    Object.defineProperty = function (target, key, descriptor) {
      const carrierPath = paths.get(target)
      if (carrierPath !== undefined) {
        recorded.push(label(carrierPath, key))
        const value = descriptor.value
        if (value !== null && (typeof value === 'object' || typeof value === 'function') && !paths.has(value)) {
          const name = keyLabel(key)
          paths.set(value, carrierPath === 'globalThis' ? name : carrierPath + '.' + name)
        }
      }
      return realDefineProperty(target, key, descriptor)
    }
    eval(script)
    process.stdout.write(JSON.stringify(recorded))
  `
  const child = spawnSync(process.execPath, ['-'], { input: program, encoding: 'utf8' })
  assert.equal(child.status, 0, `probe-surface child failed:\n${child.stderr}${child.stdout}`)
  const parsed: unknown = JSON.parse(child.stdout)
  assert.ok(Array.isArray(parsed), 'the probe-surface child must return a JSON array')
  return parsed as string[]
}

test('the Kotlin probe script is a self-contained IIFE that returns JSON', () => {
  const script = kotlinProbeScript()
  assert.ok(script.startsWith('(function () {'), script.slice(0, 40))
  assert.ok(script.includes('JSON.stringify(out)'))
  assert.ok(script.includes('navigator.userAgent'))
  for (const id of FEATURE_IDS) assert.ok(script.includes(`"${id}"`), `probe lacks ${id}`)
})

test('a Chromium-109-shaped engine reports async iteration present through the prelude', () => {
  // Chromium 109 has neither half of the Web IDL pair: `values()` and the
  // `[Symbol.asyncIterator]` method that derives from it both shipped in 124.
  const run = runProbe(kotlinProbeScript(), ['values', 'asyncIterator'])

  assert.deepEqual(Object.keys(run.features).sort(), [...FEATURE_IDS])
  assert.equal(
    run.features['readable-stream-async-iteration'], true,
    'the prelude mirror must flip the feature on where the native pair is absent',
  )
  assert.equal(run.features['readable-stream-pipe-through'], true)
  assert.equal(run.features['decompression-stream-gzip'], true)
  assert.equal(run.features['symbol-dispose'], true, 'the Symbol.dispose shim path must stay effective')
  assert.ok(run.ua.length > 0, 'the probe must report the engine user agent')
})

test('a native engine reports every feature without being patched', () => {
  const run = runProbe(kotlinProbeScript(), [])

  assert.deepEqual(run.features, {
    'readable-stream-async-iteration': true,
    'readable-stream-pipe-through': true,
    'decompression-stream-gzip': true,
    'symbol-dispose': true,
  })
})

test('the probe installs values() and [Symbol.asyncIterator] as one function object', () => {
  // Web IDL § 3.7.10 defines `values` as an enumerable data property and
  // `[Symbol.asyncIterator]` as a non-enumerable method, both pointing at the
  // same function. A second, behaviourally-equal wrapper would pass a surface
  // check and every behaviour check, so the identity is asserted on its own.
  const program = `
    if (typeof navigator === 'undefined') globalThis.navigator = { userAgent: 'probe-identity-test' }
    delete ReadableStream.prototype.values
    delete ReadableStream.prototype[Symbol.asyncIterator]
    eval(${JSON.stringify(kotlinProbeScript())})
    const proto = ReadableStream.prototype
    const values = Object.getOwnPropertyDescriptor(proto, 'values')
    const iterator = Object.getOwnPropertyDescriptor(proto, Symbol.asyncIterator)
    process.stdout.write(JSON.stringify({
      same: proto.values === proto[Symbol.asyncIterator],
      valuesEnumerable: values !== undefined && values.enumerable === true,
      iteratorEnumerable: iterator !== undefined && iterator.enumerable === true,
    }))
  `
  const child = spawnSync(process.execPath, ['-'], { input: program, encoding: 'utf8' })
  assert.equal(child.status, 0, `identity child failed:\n${child.stderr}${child.stdout}`)
  assert.deepEqual(JSON.parse(child.stdout), {
    same: true,
    valuesEnumerable: true,
    iteratorEnumerable: false,
  })
})

test('the surface extraction covers every module boot.ts installs first', () => {
  // The extraction calls the four installers by name. A fifth prelude module
  // would be measured by neither side, so it must be added here — and this
  // assertion is what makes that red instead of silent.
  const boot = readFileSync(join(here, 'boot.ts'), 'utf8')
  const imported = [...boot.matchAll(/^import\s+'\.\/([^']+)'\s*$/gm)].map(match => match[1] ?? '')
  assert.deepEqual(
    imported.sort(),
    ['abort-signal-compat.ts', 'es2023-compat.ts', 'jsc-compat.ts', 'scheduler-compat.ts'],
    'boot.ts changed its prelude: extend preludeSurface() to call the new module\'s installer(s)',
  )
})

test('the probe installs every property the Worker prelude installs', () => {
  const prelude = preludeSurface()
  const preludeNames = prelude.map(surfaceName)

  // If the extraction itself broke (a module renamed, an installer signature
  // changed), a subset comparison would pass by measuring nothing.
  for (const anchor of [
    'ReadableStream.prototype.values',
    'ReadableStream.prototype[Symbol.asyncIterator]',
  ]) {
    assert.ok(preludeNames.includes(anchor), `the prelude extraction did not observe ${anchor}`)
  }

  const probe = probeSurface(prelude)
  const missing = preludeNames.filter(name => !probe.includes(name))
  assert.deepEqual(
    missing,
    [],
    'WebViewKernelProbe.SCRIPT installs a weaker surface than the Worker prelude.\n' +
      `Missing ${missing.length} of ${preludeNames.length}:${missing.map(name => `\n  - ${name}`).join('')}\n` +
      `The probe currently installs:${probe.map(name => `\n  - ${name}`).join('')}`,
  )
})
