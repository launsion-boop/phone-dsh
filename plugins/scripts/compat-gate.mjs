// SPDX-License-Identifier: MIT
/**
 * Build-time M99 compatibility gate for the shared Worker TypeScript tree.
 *
 * The Worker sources are shared verbatim with the phone image: the same
 * TypeScript is compiled once and runs inside `com.huawei.webview`, whose
 * engine is pinned at roughly Chromium 99 / V8 9.9 and cannot be updated from
 * Play. `tsconfig.json` compiles against ES2024 libs, so nothing in the type
 * checker stops a new `Promise.withResolvers`, a `??=` in a DSH upgrade, or a
 * decorator from reaching the phone and failing at runtime, far from CI.
 *
 * This gate is the build-time complement of the runtime feature probes:
 * lexical scanning only (no TypeScript parser, no new dependency), two
 * families of rule read from `compat-baseline.json`:
 *
 * - runtime APIs (`.toSorted(`, `Object.groupBy(`, ...) and
 * - syntax (decorators, `using`, import attributes, ...).
 *
 * Rules carry the Chromium milestone that shipped the feature, and the verdict
 * is a single comparison: `sinceChromium <= M99` means the phone engine has it,
 * so the hit is recorded as a note; a later milestone blocks; `unverified`
 * warns and blocks only under `--strict`. ES years are kept as the `since`
 * field but never decide anything: `Array.prototype.at` is ES2022 yet shipped
 * in Chromium 92, `findLast` is ES2023 yet shipped in Chromium 97, and an
 * ES-year threshold would mark both as debt they are not.
 *
 * Hits can be exempted per path prefix through `allow[]`, whose entries must
 * carry a reason and an expiry date: an expired entry fails the gate, so a
 * freeze cannot silently become permanent. `polyfills[]` declares an API as
 * provided by a module that must exist in the tree.
 *
 * Files under `tests/` (and `*.test.*` next to sources) run on Node in CI, not
 * on the phone, so their hits warn instead of blocking; `--block-tests` flips
 * that. Comment lines and lines that are a single string literal are skipped,
 * because fixtures and docs contain the forbidden spelling on purpose.
 *
 * @module @phone-dsh/dsh-plugins/scripts/compat-gate
 */
import { existsSync, readFileSync, readdirSync, realpathSync } from 'node:fs'
import { dirname, extname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDirectory = dirname(fileURLToPath(import.meta.url))

/** Resolve a path when it exists, otherwise return it unchanged. */
function realpathOrSelf(path) {
  try {
    return realpathSync(path)
  } catch {
    return path
  }
}

/** Default baseline: always next to this script, never next to the scan root. */
export const DEFAULT_BASELINE_PATH = join(scriptDirectory, 'compat-baseline.json')

/** Default scan root: the `plugins` directory that contains this script. */
export const DEFAULT_ROOT = dirname(scriptDirectory)

/**
 * The Huawei WebView engine baseline. A feature whose `sinceChromium` is at or
 * below this milestone exists on the phone and is recorded, not blocked.
 */
export const BASELINE_CHROMIUM = 99

const SCANNED_EXTENSIONS = new Set(['.ts', '.mts', '.mjs', '.js'])
const EXCLUDED_DIRECTORIES = new Set(['node_modules', 'dist', '.build', '.git'])
const TEST_FILE_NAME = /\.test\.(?:ts|mts|mjs|js)$/
const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/

const USAGE = `usage: node plugins/scripts/compat-gate.mjs [options]

  --root <dir>        source tree to scan (default: the plugins directory)
  --baseline <file>   baseline JSON (default: scripts/compat-baseline.json)
  --today <date>      override the clock for allow/polyfill expiry (YYYY-MM-DD)
  --strict            treat "unverified" rules as blocking
  --block-tests       also block hits in test files
  --include-strings   scan obvious string-literal-only lines too
  --verbose           print allowed and inside-baseline (note) hits too
  --json              machine-readable report on stdout
  --help              this message
`

/**
 * One compiled rule from the baseline.
 * @typedef {object} CompiledRule
 * @property {string} name - reported API or syntax name.
 * @property {'api' | 'syntax'} kind - rule family.
 * @property {string} since - introducing ES version; explanation only.
 * @property {number | 'unverified'} sinceChromium - shipping milestone, decides the verdict.
 * @property {RegExp} regex - compiled detection pattern.
 */

/**
 * One exemption entry from `allow[]`.
 * @typedef {object} AllowEntry
 * @property {string} path - scan-root-relative path prefix.
 * @property {string} api - exact rule name.
 * @property {string} reason - why the exemption exists.
 * @property {string} expires - ISO date after which the entry fails.
 */

/**
 * One polyfill declaration from `polyfills[]`.
 * @typedef {object} PolyfillEntry
 * @property {string} api - exact rule name the module provides.
 * @property {string} provider - scan-root-relative module that installs it.
 * @property {string} note - what the polyfill does.
 * @property {string} expires - ISO date after which the declaration fails.
 */

/**
 * One reported hit.
 * @typedef {object} Hit
 * @property {string} path - scan-root-relative POSIX path.
 * @property {number} line - 1-based line number.
 * @property {string} api - rule name.
 * @property {'api' | 'syntax'} kind - rule family.
 * @property {string} since - introducing ES version; explanation only.
 * @property {number | 'unverified'} sinceChromium - shipping milestone, decides the verdict.
 * @property {'src' | 'test' | 'other'} origin - where the file lives.
 * @property {'error' | 'warning' | 'allowed' | 'note'} severity - gate effect.
 * @property {string | undefined} reason - why the severity was chosen.
 */

/**
 * Parse CLI arguments. Throws on unknown flags so a typo cannot disable the gate.
 * @param {readonly string[]} argv - arguments after the script name.
 * @returns {{root: string, baseline: string | undefined, today: string | undefined,
 *   strict: boolean, blockTests: boolean, includeStrings: boolean,
 *   verbose: boolean, json: boolean, help: boolean}} parsed options.
 */
export function parseArgs(argv) {
  const options = {
    root: DEFAULT_ROOT,
    baseline: undefined,
    today: undefined,
    strict: false,
    blockTests: false,
    includeStrings: false,
    verbose: false,
    json: false,
    help: false,
  }
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index]
    const value = () => {
      const next = argv[index + 1]
      if (next === undefined || next.startsWith('--')) throw new Error(`${flag} needs a value`)
      index += 1
      return next
    }
    switch (flag) {
      case '--root': options.root = value(); break
      case '--baseline': options.baseline = value(); break
      case '--today': options.today = value(); break
      case '--strict': options.strict = true; break
      case '--block-tests': options.blockTests = true; break
      case '--include-strings': options.includeStrings = true; break
      case '--verbose': options.verbose = true; break
      case '--json': options.json = true; break
      case '--help':
      case '-h': options.help = true; break
      default: throw new Error(`unknown argument: ${flag}`)
    }
  }
  if (options.today !== undefined && !ISO_DATE.test(options.today)) {
    throw new Error(`--today must be YYYY-MM-DD, got ${options.today}`)
  }
  return options
}

/** Today as a local ISO date, so expiry follows the reviewer's calendar. */
export function localToday(now = new Date()) {
  const pad = (part) => String(part).padStart(2, '0')
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`
}

/** Normalise a baseline path to scan-root-relative POSIX form. */
function normalizePath(path) {
  return path.replaceAll('\\', '/').replace(/^\.\//, '')
}

/**
 * Compile the baseline rule lists.
 * @param {any} raw - parsed baseline JSON.
 * @returns {{apis: CompiledRule[], syntax: CompiledRule[], allow: AllowEntry[],
 *   polyfills: PolyfillEntry[], problems: string[]}} compiled rules and errors.
 */
export function prepareRules(raw) {
  /** @type {string[]} */
  const problems = []
  const build = (entries, kind) => {
    /** @type {CompiledRule[]} */
    const rules = []
    const seen = new Set()
    if (!Array.isArray(entries)) {
      problems.push(`baseline: ${kind === 'api' ? 'forbiddenApis' : 'forbiddenSyntax'} must be an array`)
      return rules
    }
    entries.forEach((entry, index) => {
      const label = `${kind === 'api' ? 'forbiddenApis' : 'forbiddenSyntax'}[${index}]`
      if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) {
        problems.push(`${label}: not an object`)
        return
      }
      const name = entry.name
      if (typeof name !== 'string' || name.trim() === '') {
        problems.push(`${label}: missing name`)
        return
      }
      if (typeof entry.pattern !== 'string' || entry.pattern === '') {
        problems.push(`${label} (${name}): missing pattern`)
        return
      }
      if (typeof entry.since !== 'string' || entry.since.trim() === '') {
        problems.push(`${label} (${name}): missing since`)
        return
      }
      let regex
      try {
        regex = new RegExp(entry.pattern)
      } catch (error) {
        problems.push(`${label} (${name}): invalid pattern: ${error.message}`)
        return
      }
      const sinceChromium = entry.sinceChromium
      if (sinceChromium !== 'unverified' && !(Number.isInteger(sinceChromium) && sinceChromium > 0)) {
        problems.push(`${label} (${name}): sinceChromium must be a positive Chromium milestone or "unverified"`)
        return
      }
      if (seen.has(name)) {
        problems.push(`${label} (${name}): duplicate rule name`)
        return
      }
      seen.add(name)
      rules.push({
        name,
        kind,
        since: entry.since,
        sinceChromium,
        regex,
      })
    })
    return rules
  }

  const apis = build(raw.forbiddenApis, 'api')
  const syntax = build(raw.forbiddenSyntax, 'syntax')

  /** @type {AllowEntry[]} */
  const allow = []
  if (!Array.isArray(raw.allow)) {
    problems.push('baseline: allow must be an array')
  } else {
    raw.allow.forEach((entry, index) => {
      const label = `allow[${index}]`
      if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) {
        problems.push(`${label}: not an object`)
        return
      }
      for (const field of ['path', 'api', 'reason', 'expires']) {
        if (typeof entry[field] !== 'string' || entry[field].trim() === '') {
          problems.push(`${label}: missing ${field}`)
        }
      }
      if (typeof entry.expires === 'string' && !ISO_DATE.test(entry.expires)) {
        problems.push(`${label}: expires must be YYYY-MM-DD`)
      }
      allow.push({
        path: normalizePath(String(entry.path ?? '')),
        api: String(entry.api ?? ''),
        reason: String(entry.reason ?? ''),
        expires: String(entry.expires ?? ''),
      })
    })
  }

  /** @type {PolyfillEntry[]} */
  const polyfills = []
  if (!Array.isArray(raw.polyfills)) {
    problems.push('baseline: polyfills must be an array')
  } else {
    raw.polyfills.forEach((entry, index) => {
      const label = `polyfills[${index}]`
      if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) {
        problems.push(`${label}: not an object`)
        return
      }
      for (const field of ['api', 'provider', 'expires']) {
        if (typeof entry[field] !== 'string' || entry[field].trim() === '') {
          problems.push(`${label}: missing ${field}`)
        }
      }
      if (typeof entry.expires === 'string' && !ISO_DATE.test(entry.expires)) {
        problems.push(`${label}: expires must be YYYY-MM-DD`)
      }
      polyfills.push({
        api: String(entry.api ?? ''),
        provider: normalizePath(String(entry.provider ?? '')),
        note: typeof entry.note === 'string' ? entry.note : '',
        expires: String(entry.expires ?? ''),
      })
    })
  }

  for (const field of ['target', 'esVersion']) {
    if (typeof raw[field] !== 'string' || raw[field].trim() === '') {
      problems.push(`baseline: missing ${field}`)
    }
  }

  return { apis, syntax, allow, polyfills, problems }
}

/** A line whose first non-space characters open a comment. */
export function isCommentLine(line) {
  const trimmed = line.trimStart()
  return trimmed.startsWith('//') || trimmed.startsWith('/*') || trimmed.startsWith('*')
}

/**
 * A line that is one complete string literal plus optional punctuation.
 * Such lines are test data or documentation payloads, not executed calls.
 */
export function isStringOnlyLine(line) {
  const text = line.trim()
  const quote = text[0]
  if (quote !== '"' && quote !== "'" && quote !== '`') return false
  let index = 1
  for (; index < text.length; index += 1) {
    if (text[index] === '\\') {
      index += 1
      continue
    }
    if (text[index] === quote) break
  }
  if (index >= text.length) return false
  const rest = text.slice(index + 1).trim()
  return rest === '' || rest === ',' || rest === ';' || rest === ')' || rest === ');' || rest === '),'
}

/** Classify a scan-root-relative path. Test files run on Node, not the phone. */
export function classifyPath(relativePath) {
  if (relativePath.startsWith('tests/')) return 'test'
  if (TEST_FILE_NAME.test(relativePath)) return 'test'
  if (relativePath.split('/').includes('src')) return 'src'
  return 'other'
}

/**
 * List scan targets: every `<package>/src/**` plus the root `tests/**`.
 * Symlinks are skipped, as are the generated trees the brief excludes.
 * @param {string} root - absolute scan root.
 * @returns {string[]} sorted scan-root-relative POSIX paths.
 */
export function listScopeFiles(root) {
  /** @type {Array<[string, string]>} */
  const pending = []
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    if (!entry.isDirectory() || EXCLUDED_DIRECTORIES.has(entry.name)) continue
    if (entry.name === 'tests') pending.push([join(root, entry.name), entry.name])
    else pending.push([join(root, entry.name, 'src'), `${entry.name}/src`])
  }
  /** @type {string[]} */
  const files = []
  while (pending.length > 0) {
    const [directory, relativeDirectory] = pending.pop()
    let entries
    try {
      entries = readdirSync(directory, { withFileTypes: true })
    } catch {
      continue
    }
    for (const entry of entries) {
      const relativePath = `${relativeDirectory}/${entry.name}`
      if (entry.isDirectory()) {
        if (!EXCLUDED_DIRECTORIES.has(entry.name)) pending.push([join(directory, entry.name), relativePath])
        continue
      }
      if (!entry.isFile()) continue
      if (!SCANNED_EXTENSIONS.has(extname(entry.name))) continue
      files.push(relativePath)
    }
  }
  return files.sort()
}

/**
 * Scan one source file line by line.
 * @param {string} relativePath - reported path.
 * @param {string} source - file contents, read once.
 * @param {readonly CompiledRule[]} rules - compiled API and syntax rules.
 * @param {{includeStrings: boolean}} options - whether to scan literal payloads.
 * @returns {{matches: Array<{line: number, rule: CompiledRule}>, lines: number,
 *   skippedStrings: number}} raw matches.
 */
export function scanSource(relativePath, source, rules, options) {
  /** @type {Array<{line: number, rule: CompiledRule}>} */
  const matches = []
  const lines = source.split('\n')
  if (lines.length > 0 && lines[lines.length - 1] === '') lines.pop()
  let skippedStrings = 0
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index]
    if (isCommentLine(line)) continue
    if (!options.includeStrings && isStringOnlyLine(line)) {
      skippedStrings += 1
      continue
    }
    for (const rule of rules) {
      if (rule.regex.test(line)) matches.push({ line: index + 1, rule })
    }
  }
  return { matches, lines: lines.length, skippedStrings }
}

/**
 * Apply exemptions and the milestone verdict.
 *
 * The verdict is the milestone comparison, in this order: an explicit
 * exemption wins; a feature the M99 engine already ships is recorded as a
 * note even in test files; test-only hits warn; a declared polyfill downgrades
 * to a warning; an unverified milestone warns and blocks under `--strict`;
 * everything else blocks.
 *
 * @param {CompiledRule} rule - matched rule.
 * @param {'src' | 'test' | 'other'} origin - file origin.
 * @param {{strict: boolean, blockTests: boolean}} options - gate options.
 * @param {AllowEntry | undefined} allow - matching exemption, if any.
 * @param {PolyfillEntry | undefined} polyfill - matching polyfill, if any.
 * @returns {{severity: Hit['severity'], reason: string | undefined}} decision.
 */
function decide(rule, origin, options, allow, polyfill) {
  if (allow) return { severity: 'allowed', reason: allow.path }
  if (rule.sinceChromium !== 'unverified' && rule.sinceChromium <= BASELINE_CHROMIUM) {
    return { severity: 'note', reason: `Chromium ${rule.sinceChromium} <= ${BASELINE_CHROMIUM}` }
  }
  if (origin === 'test' && !options.blockTests) return { severity: 'warning', reason: 'test-only' }
  if (polyfill) return { severity: 'warning', reason: 'polyfilled' }
  if (rule.sinceChromium === 'unverified' && !options.strict) {
    return { severity: 'warning', reason: 'unverified' }
  }
  return { severity: 'error', reason: undefined }
}

/**
 * Run the gate.
 * @param {ReturnType<typeof parseArgs> & {root: string, baseline?: string}} options - gate options.
 * @returns {{report: any, problems: string[], exitCode: number}} report and verdict.
 */
export function runGate(options) {
  const started = Date.now()
  const today = options.today ?? localToday()
  const root = resolve(options.root)
  const baselinePath = options.baseline === undefined ? DEFAULT_BASELINE_PATH : resolve(options.baseline)
  /** @type {string[]} */
  const problems = []
  /** @type {any} */
  const report = {
    target: null,
    esVersion: null,
    root,
    baseline: baselinePath,
    today,
    baselineChromium: BASELINE_CHROMIUM,
    ok: false,
    exitCode: 1,
    totals: {},
    byApi: [],
    notesByApi: [],
    hits: [],
    problems,
    expired: [],
  }

  if (!existsSync(root)) {
    problems.push(`scan root does not exist: ${root}`)
    report.totals = emptyTotals(0)
    return { report, problems, exitCode: 1 }
  }

  let raw
  try {
    raw = JSON.parse(readFileSync(baselinePath, 'utf8'))
  } catch (error) {
    problems.push(`cannot read baseline ${baselinePath}: ${error.message}`)
    report.totals = emptyTotals(0)
    return { report, problems, exitCode: 1 }
  }

  const prepared = prepareRules(raw)
  problems.push(...prepared.problems)
  report.target = typeof raw.target === 'string' ? raw.target : null
  report.esVersion = typeof raw.esVersion === 'string' ? raw.esVersion : null

  const files = listScopeFiles(root)
  if (files.length === 0) problems.push(`no source files found under ${root}`)

  const expired = []
  const liveAllow = []
  for (const entry of prepared.allow) {
    if (entry.expires < today) expired.push({ kind: 'allow', ...entry })
    else liveAllow.push(entry)
  }
  const livePolyfills = []
  for (const entry of prepared.polyfills) {
    if (entry.expires < today) {
      expired.push({ kind: 'polyfill', ...entry })
      continue
    }
    const providerPath = resolve(root, ...entry.provider.split('/'))
    if (entry.provider === '' || !existsSync(providerPath)) {
      problems.push(`polyfills[] declares ${entry.api} via ${entry.provider}, but that module does not exist`)
      continue
    }
    livePolyfills.push(entry)
  }
  report.expired = expired

  const rules = [...prepared.apis, ...prepared.syntax]
  /** @type {Hit[]} */
  const hits = []
  const totals = emptyTotals(files.length)
  const usedAllow = new Set()
  const usedPolyfill = new Set()

  for (const relativePath of files) {
    let source
    try {
      source = readFileSync(resolve(root, ...relativePath.split('/')), 'utf8')
    } catch (error) {
      problems.push(`cannot read ${relativePath}: ${error.message}`)
      continue
    }
    const scanned = scanSource(relativePath, source, rules, { includeStrings: options.includeStrings })
    totals.lines += scanned.lines
    totals.skippedStringLines += scanned.skippedStrings
    if (scanned.matches.length > 0) totals.filesWithHits += 1
    const origin = classifyPath(relativePath)
    for (const match of scanned.matches) {
      const allow = liveAllow.find((entry) => relativePath.startsWith(entry.path) && entry.api === match.rule.name)
      const polyfill = livePolyfills.find((entry) => entry.api === match.rule.name)
      const { severity, reason } = decide(match.rule, origin, options, allow, polyfill)
      if (allow) usedAllow.add(allow)
      if (polyfill) usedPolyfill.add(polyfill)
      hits.push({
        path: relativePath,
        line: match.line,
        api: match.rule.name,
        kind: match.rule.kind,
        since: match.rule.since,
        sinceChromium: match.rule.sinceChromium,
        origin,
        severity,
        reason: reason ?? null,
      })
    }
  }

  hits.sort((left, right) => (left.path === right.path
    ? left.line - right.line || left.api.localeCompare(right.api)
    : left.path.localeCompare(right.path)))

  totals.hits = hits.length
  totals.blocking = hits.filter((hit) => hit.severity === 'error').length
  totals.warnings = hits.filter((hit) => hit.severity === 'warning').length
  totals.allowed = hits.filter((hit) => hit.severity === 'allowed').length
  totals.notes = hits.filter((hit) => hit.severity === 'note').length
  totals.allowEntries = prepared.allow.length
  totals.allowUsed = usedAllow.size
  totals.allowUnused = prepared.allow.length - usedAllow.size
  totals.expiredAllow = expired.filter((entry) => entry.kind === 'allow').length
  totals.polyfills = prepared.polyfills.length
  totals.polyfillUsed = usedPolyfill.size
  totals.expiredPolyfills = expired.filter((entry) => entry.kind === 'polyfill').length
  totals.elapsedMs = Date.now() - started

  report.hits = hits
  report.totals = totals
  report.byApi = groupByApi(hits.filter((hit) => hit.severity === 'error' || hit.severity === 'warning'))
  report.notesByApi = groupByApi(hits.filter((hit) => hit.severity === 'note'))
  report.exitCode = totals.blocking > 0 || problems.length > 0 || expired.length > 0 ? 1 : 0
  report.ok = report.exitCode === 0
  return { report, problems, exitCode: report.exitCode }
}

/** Zeroed totals so a fatal error still returns a shaped report. */
function emptyTotals(files) {
  return {
    files,
    lines: 0,
    filesWithHits: 0,
    hits: 0,
    blocking: 0,
    warnings: 0,
    allowed: 0,
    notes: 0,
    skippedStringLines: 0,
    allowEntries: 0,
    allowUsed: 0,
    allowUnused: 0,
    expiredAllow: 0,
    polyfills: 0,
    polyfillUsed: 0,
    expiredPolyfills: 0,
    elapsedMs: 0,
  }
}

/** Group hits by rule name, keeping a stable count order and severity split. */
function groupByApi(hits) {
  const counts = new Map()
  for (const hit of hits) {
    const bucket = counts.get(hit.api) ?? { total: 0, blocking: 0, warnings: 0 }
    bucket.total += 1
    if (hit.severity === 'error') bucket.blocking += 1
    if (hit.severity === 'warning') bucket.warnings += 1
    counts.set(hit.api, bucket)
  }
  return [...counts.entries()]
    .map(([api, bucket]) => ({
      api, count: bucket.total, blocking: bucket.blocking, warnings: bucket.warnings,
    }))
    .sort((left, right) => right.count - left.count || left.api.localeCompare(right.api))
}

/** Render the human report. */
export function formatReport(report, options = {}) {
  const lines = []
  lines.push(`compat-gate: target=${report.target ?? '?'} language=${report.esVersion ?? '?'}`)
  lines.push(`root=${report.root}`)
  lines.push(`baseline=${report.baseline} today=${report.today}`)
  lines.push('')
  const blocking = report.hits.filter((hit) => hit.severity === 'error')
  const warnings = report.hits.filter((hit) => hit.severity === 'warning')
  if (blocking.length === 0) lines.push('(no blocking hits)')
  for (const hit of blocking) lines.push(`${hit.path}:${hit.line}: ${hit.api}`)
  if (warnings.length > 0) {
    lines.push('')
    lines.push('warnings (non-blocking)')
    for (const hit of warnings) lines.push(`${hit.path}:${hit.line}: ${hit.api} [warning: ${hit.reason}]`)
  }
  if (options.verbose) {
    const quiet = report.hits.filter((hit) => hit.severity === 'allowed' || hit.severity === 'note')
    if (quiet.length > 0) lines.push('', 'allowed / inside baseline (--verbose)')
    for (const hit of quiet) {
      lines.push(`${hit.path}:${hit.line}: ${hit.api} [${hit.severity}: ${hit.reason}]`)
    }
  }
  lines.push('')
  for (const entry of report.expired) {
    lines.push(`EXPIRED ${entry.kind}: ${entry.api} ${entry.path ?? entry.provider} (expired ${entry.expires})`)
  }
  for (const problem of report.problems) lines.push(`PROBLEM ${problem}`)
  const totals = report.totals
  lines.push('summary')
  lines.push(`  files: ${totals.files} (with hits: ${totals.filesWithHits})`)
  lines.push(`  lines: ${totals.lines}`)
  lines.push(`  hits: ${totals.hits} (blocking ${totals.blocking}, warnings ${totals.warnings}, `
    + `allowed ${totals.allowed}, notes ${totals.notes})`)
  lines.push(`  allow entries: ${totals.allowEntries} (used ${totals.allowUsed}, unused ${totals.allowUnused}, `
    + `expired ${totals.expiredAllow})`)
  lines.push(`  polyfills: ${totals.polyfills} (used ${totals.polyfillUsed}, expired ${totals.expiredPolyfills})`)
  lines.push(`  skipped string-literal lines: ${totals.skippedStringLines}`)
  lines.push(`  scanned in ${totals.elapsedMs} ms`)
  if (report.byApi.length > 0) {
    lines.push('by api (blocking + warnings)')
    for (const entry of report.byApi) {
      lines.push(`  ${entry.api}: ${entry.count} (blocking ${entry.blocking}, warnings ${entry.warnings})`)
    }
  }
  if (report.notesByApi.length > 0) {
    lines.push(`inside the M99 baseline (Chromium <= ${BASELINE_CHROMIUM}, recorded, no action)`)
    for (const entry of report.notesByApi) lines.push(`  ${entry.api}: ${entry.count} recorded`)
  }
  lines.push(`result: ${report.ok ? 'PASS' : 'FAIL'}`)
  return `${lines.join('\n')}\n`
}

function main(argv) {
  let options
  try {
    options = parseArgs(argv)
  } catch (error) {
    process.stderr.write(`compat-gate: ${error.message}\n${USAGE}`)
    return 1
  }
  if (options.help) {
    process.stdout.write(USAGE)
    return 0
  }
  const result = runGate(options)
  if (options.json) process.stdout.write(`${JSON.stringify(result.report, null, 2)}\n`)
  else process.stdout.write(formatReport(result.report, options))
  for (const problem of result.problems) process.stderr.write(`compat-gate: ${problem}\n`)
  return result.exitCode
}

const invokedPath = process.argv[1] === undefined ? '' : resolve(process.argv[1])
if (invokedPath !== '' && realpathOrSelf(invokedPath) === realpathOrSelf(fileURLToPath(import.meta.url))) {
  process.exitCode = main(process.argv.slice(2))
}
