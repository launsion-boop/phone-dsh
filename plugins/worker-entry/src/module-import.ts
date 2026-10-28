// SPDX-License-Identifier: MIT
/**
 * Bounded, field-controlled diagnostics for image-module import failures.
 *
 * The pinned runtime evaluates a packed module body with `new Function(...)`.
 * JavaScriptCore's `Error.stack` contains only frames (`anonymous@` /
 * `global code@`) and never the error message, so app-boot's
 * `formatActivationError`, which prefers `stack` over `message`, reports a
 * failed plugin as `anonymous@` with no name, code or reason. That is enough to
 * see that an import failed and not enough to know why.
 *
 * This wrapper runs at the loader's import seam — after the runtime has
 * resolved the module and while its body evaluates — and rethrows a **new**
 * Error whose stack starts with a fixed diagnostic header. It never reads the
 * raw `message` or `stack` into the output, never attaches the raw error as
 * `cause`, and never copies arbitrary properties. Only controlled fields
 * participate:
 *
 *  - a known error type from a fixed allowlist (unknown types become `Error`);
 *  - the fixed `E_MODULE_IMPORT` code, plus a known loader code from a fixed
 *    allowlist when one is present;
 *  - a registry package specifier only when it matches strict package-name
 *    grammar (URLs, percent-encoding, queries, userinfo and paths are omitted);
 *  - a parent path only when it is the fixed profile directory shape;
 *  - at most a few locations from known static Worker files with pure numeric
 *    line/column numbers.
 *
 * A `ReferenceError` gets the fixed explanation `runtime global unavailable`;
 * no variable name or raw error text is forwarded. The result is a diagnostic,
 * not a recovery: the import still fails, and the plugin still reports as
 * failed.
 *
 * @module @phone-dsh/dsh-worker-entry/module-import
 */

/** Total characters retained in one enriched import diagnostic. */
export const MODULE_IMPORT_DIAGNOSTIC_LIMIT = 2048
/** Stack locations retained after the fixed header. */
export const MODULE_IMPORT_STACK_FRAMES = 8
/** Fixed diagnostic code emitted for every enriched import failure. */
export const MODULE_IMPORT_DIAGNOSTIC_CODE = 'E_MODULE_IMPORT'
/** Longest registry specifier retained in the fixed context. */
export const MODULE_IMPORT_SPECIFIER_LIMIT = 256

/** Construction inputs for {@link enrichModuleImportError}. */
export interface ModuleImportDiagnosticOptions {
  /** Specifier the loader was asked for. */
  readonly specifier?: string | undefined
  /** Base the loader resolved the specifier from. */
  readonly parentURL?: string | URL | undefined
  /** Maximum characters retained; defaults to {@link MODULE_IMPORT_DIAGNOSTIC_LIMIT}. */
  readonly limit?: number | undefined
}

/** Structural subset of the runtime loader this module wraps. */
export interface ImportSeamLoader {
  readonly internal: {
    import(specifier: string, parentURL?: string | URL, attributes?: unknown): Promise<unknown>
  }
}

/** Marker installed on the wrapped object so repeated boot wiring is a no-op. */
const WRAPPED = Symbol('phone-dsh.module-import-diagnostics')

type MarkedImportSeam = ImportSeamLoader['internal'] & { readonly [WRAPPED]?: true }

/**
 * Name of the error this layer raises. The first stack line carries it so the
 * activation audit, which prefers `stack` over `name`/`message` on
 * JavaScriptCore, still shows that the failure is an enriched import
 * diagnostic rather than a bare `anonymous@`.
 */
const DIAGNOSTIC_NAME = 'ModuleImportError'

/** Error types this layer may name; an unknown/custom name becomes `Error`. */
const KNOWN_ERROR_TYPES: ReadonlySet<string> = new Set([
  'Error',
  'TypeError',
  'RangeError',
  'ReferenceError',
  'SyntaxError',
  'URIError',
  'EvalError',
  'AggregateError',
])

/**
 * Loader codes that identify a resolution/evaluation failure without carrying
 * arbitrary text. Node's ESM codes and the pinned runtime's shorter spellings
 * are both listed; anything else is dropped in favour of `E_MODULE_IMPORT`.
 */
const KNOWN_ERROR_CODES: ReadonlySet<string> = new Set([
  'MODULE_NOT_FOUND',
  'ERR_MODULE_NOT_FOUND',
  'ERR_PACKAGE_PATH_NOT_EXPORTED',
  'ERR_PACKAGE_IMPORT_NOT_DEFINED',
  'ERR_UNSUPPORTED_DIR_IMPORT',
  'ERR_UNKNOWN_FILE_EXTENSION',
  'ERR_INVALID_MODULE_SPECIFIER',
  'ERR_UNSUPPORTED_ESM_URL_SCHEME',
  'ERR_IMPORT_ASSERTION_TYPE_MISSING',
  'ERR_IMPORT_ATTRIBUTE_MISSING',
  'ERR_IMPORT_ATTRIBUTE_TYPE_INCOMPATIBLE',
  'ERR_MODULE_LINK_MISMATCH',
  'ERR_INVALID_PACKAGE_CONFIG',
  'ERR_INVALID_PACKAGE_TARGET',
  'ERR_INVALID_URL',
  'ERR_UNKNOWN_BUILTIN_MODULE',
  'ERR_NETWORK_IMPORT_DISALLOWED',
  'ERR_NETWORK_IMPORT_BAD_RESPONSE',
])

/**
 * Strict registry package specifier: an optional `@scope/` followed by a
 * package name. No URL, percent-encoding, query, fragment, userinfo, filesystem
 * path or package subpath survives this grammar.
 */
const REGISTRY_SPECIFIER = /^(?:@[a-z0-9][a-z0-9._~-]*\/)?[a-z0-9_][a-z0-9._~-]*$/i

/** The only parent location retained: the fixed profile directory shape. */
const PROFILE_PARENT = /^\/dsh\/home\/profiles\/[a-z0-9_][a-z0-9._-]*\/?$/i

/**
 * Known static Worker files. A location from one of these is retained as a
 * fixed basename plus numeric line/column; frames from anywhere else are
 * dropped, so a stack cannot smuggle a path, function name or message.
 */
const STATIC_WORKER_LOCATION = /(?:^|[\\/])(worker-entry|web-boot|tool-worker-python)\.js:(\d{1,6}):(\d{1,6})(?![0-9])/g

/** Bound the raw stack scan; only known basenames/digits are extracted. */
const STACK_SCAN_LIMIT = 64 * 1024

/** Bound one composed field so an over-long header cannot exceed the limit. */
function bound(text: string, limit: number): string {
  if (text.length <= limit) return text
  if (limit <= 3) return text.slice(0, limit)
  return `${text.slice(0, limit - 3)}...`
}

/** Read a known error type without forwarding a custom name. */
function errorType(error: unknown): string {
  try {
    if (!(error instanceof Error)) return 'Error'
    const name = error.name
    return typeof name === 'string' && KNOWN_ERROR_TYPES.has(name) ? name : 'Error'
  } catch {
    return 'Error'
  }
}

/** Read a loader code only when it is one of the fixed known codes. */
function errorCode(error: unknown): string {
  try {
    if (!(error instanceof Error)) return ''
    const code = (error as { code?: unknown }).code
    return typeof code === 'string' && KNOWN_ERROR_CODES.has(code) ? code : ''
  } catch {
    return ''
  }
}

/** True when a specifier is a strict registry package name, never a path/URL. */
function safeSpecifier(specifier: string | undefined): string {
  if (typeof specifier !== 'string' || specifier.length === 0) return ''
  if (specifier.length > MODULE_IMPORT_SPECIFIER_LIMIT) return ''
  return REGISTRY_SPECIFIER.test(specifier) ? specifier : ''
}

/** Read the parent only when it is the fixed profile path, never a URL. */
function safeParent(parentURL: string | URL | undefined): string {
  if (parentURL === undefined) return ''
  try {
    if (parentURL instanceof URL) {
      if (parentURL.protocol !== 'file:') return ''
      if (parentURL.username !== '' || parentURL.password !== '') return ''
      if (parentURL.search !== '' || parentURL.hash !== '') return ''
      return PROFILE_PARENT.test(parentURL.pathname) ? parentURL.pathname : ''
    }
    const raw = String(parentURL)
    return PROFILE_PARENT.test(raw) ? raw : ''
  } catch {
    return ''
  }
}

/** Extract only known static Worker locations: fixed basename + numeric line/column. */
function knownStaticLocations(error: unknown, limit: number): string[] {
  let raw = ''
  try {
    if (error instanceof Error && typeof error.stack === 'string') raw = error.stack
  } catch {
    return []
  }
  if (raw === '') return []
  const locations: string[] = []
  const seen = new Set<string>()
  for (const match of raw.slice(0, STACK_SCAN_LIMIT).matchAll(STATIC_WORKER_LOCATION)) {
    const file = match[1]
    const line = match[2]
    const column = match[3]
    if (file === undefined || line === undefined || column === undefined) continue
    const location = `${file}.js:${line}:${column}`
    if (seen.has(location)) continue
    seen.add(location)
    locations.push(`at ${location}`)
    if (locations.length >= limit) break
  }
  return locations
}

/**
 * Turn one raw module-import failure into a bounded, field-controlled
 * diagnostic.
 *
 * The returned Error carries the fixed header in both `message` and the first
 * line of `stack`; at most a few known static Worker locations follow. It has
 * no `cause` and no copied properties, so a later logger cannot reach the raw
 * transport value. The raw `name`, `message`, `stack`, `code` and custom fields
 * are never copied; only allowlisted forms leave this function.
 * @param error - value thrown while resolving or evaluating an image module.
 * @param options - specifier, parent and length bound.
 * @returns a new Error safe to log and forward to the startup audit.
 */
export function enrichModuleImportError(
  error: unknown,
  options: ModuleImportDiagnosticOptions = {},
): Error {
  const limit = Math.max(256, options.limit ?? MODULE_IMPORT_DIAGNOSTIC_LIMIT)
  const type = errorType(error)
  const code = errorCode(error)
  const specifier = safeSpecifier(options.specifier)
  const parent = safeParent(options.parentURL)
  const reason = type === 'ReferenceError' ? ': runtime global unavailable' : ''
  const location = options.specifier === undefined
    ? ''
    : ` (importing ${specifier === '' ? '<omitted>' : specifier}${parent === '' ? '' : ` from ${parent}`})`
  const header = bound(
    `${DIAGNOSTIC_NAME}: ${type}: ${MODULE_IMPORT_DIAGNOSTIC_CODE}${reason}${location}${code === '' ? '' : ` [${code}]`}`,
    limit,
  )
  const frames = knownStaticLocations(error, MODULE_IMPORT_STACK_FRAMES)
  const stack = bound([header, ...frames].join('\n'), limit)
  const safe = new Error(header)
  // An engine may expose `stack` as an inherited accessor. Assigning in strict
  // mode would then throw (or be ignored) and replace the original failure with
  // a diagnostic error of its own; define an own, writable property so the
  // header is always the first stack line.
  Object.defineProperty(safe, 'name', { value: DIAGNOSTIC_NAME, configurable: true, writable: true })
  Object.defineProperty(safe, 'stack', { value: stack, configurable: true, writable: true })
  return safe
}

/**
 * Wrap one loader's `internal.import` seam with {@link enrichModuleImportError}.
 *
 * Resolution and evaluation still run unchanged; only the thrown value is
 * replaced. The marker makes repeated profile/boot wiring idempotent, so a
 * second call cannot nest two wrappers around the same failure.
 * @param loader - the active runtime module loader or a structural stub.
 * @param options - length bound applied to every failure.
 * @returns true when this call installed the wrapper, false when already present.
 */
export function installModuleImportDiagnostics(
  loader: ImportSeamLoader,
  options: Omit<ModuleImportDiagnosticOptions, 'specifier' | 'parentURL'> = {},
): boolean {
  const seam = loader.internal as MarkedImportSeam
  if (seam[WRAPPED] === true) return false
  const original = seam.import
  const wrapped = async (
    specifier: string,
    parentURL?: string | URL,
    attributes?: unknown,
  ): Promise<unknown> => {
    try {
      return await original.call(seam, specifier, parentURL, attributes)
    } catch (error) {
      throw enrichModuleImportError(error, { ...options, specifier, parentURL })
    }
  }
  Object.defineProperty(seam, 'import', { value: wrapped, configurable: true, writable: true })
  Object.defineProperty(seam, WRAPPED, { value: true })
  return true
}
