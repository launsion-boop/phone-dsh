// SPDX-License-Identifier: MIT
/**
 * `mcp.json` schema, input validation, environment-header resolution, and the
 * atomic file boundary. Header values never enter this module's return values
 * except the transient `resolveHeaders` result handed to the live client.
 *
 * @module @phone-dsh/dsh-phone-mcp/schema
 */

import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import type { McpServerConfig } from './protocol.ts'

/** The file format version written by this package. */
export const MCP_CONFIG_VERSION = 1

/** Default location in the Worker image. `DSH_HOME` may relocate the home tree. */
export const DEFAULT_MCP_CONFIG_FILE = '/dsh/home/mcp.json'

/** Server namespace accepted by `@deepseek-ai/dsh-mcp-client`. */
export const SERVER_NAME_PATTERN = /^[A-Za-z0-9_-]{1,32}$/

/** POSIX-style environment variable name. Values never persist. */
export const ENV_NAME_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*$/

/** RFC 9110 field-name token. */
export const HEADER_NAME_PATTERN = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/

/**
 * Value the Worker puts in a host-managed header. The native gateway drops it
 * and injects the scoped device Keychain value; it is never a real secret.
 */
export const HOST_MANAGED_HEADER_VALUE = 'phone-host-injects-mcp-key'

/** Default per-call timeout, matching `dsh-mcp-client`. */
export const DEFAULT_TOOL_CALL_TIMEOUT_MS = 60_000

/** Largest timeout accepted by Node timers and the MCP client. */
export const MAX_TOOL_CALL_TIMEOUT_MS = 2_147_483_647

/** One configuration-file document. */
export interface McpConfigDocument {
  readonly version: typeof MCP_CONFIG_VERSION
  readonly servers: readonly McpServerConfig[]
}

/** A validation or connection failure with a stable machine-readable code. */
export class McpError extends Error {
  readonly code: string

  constructor(code: string, message: string, options?: ErrorOptions) {
    super(message, options)
    this.name = 'McpError'
    this.code = code
  }
}

const SERVER_KEYS = new Set(['serverName', 'url', 'headersFromEnv', 'hostManagedHeaders', 'enabled', 'toolCallTimeoutMs'])
const DOCUMENT_KEYS = new Set(['version', 'servers'])

/** Return the effective configuration path without reading it. */
export function defaultConfigPath(env: NodeJS.ProcessEnv = process.env): string {
  const home = env.DSH_HOME
  return home !== undefined && home.length > 0 ? join(home, 'mcp.json') : DEFAULT_MCP_CONFIG_FILE
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function assertNoUnknownKeys(value: Record<string, unknown>, allowed: ReadonlySet<string>, path: string): void {
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) throw new McpError('MCP_SCHEMA_INVALID', `${path}.${key} is not a supported field`)
  }
}

/**
 * Validate one caller-provided server row and apply documented defaults.
 * Unknown fields (including `transport`, `command`, `headers`, and `token`) are
 * rejected so this surface cannot silently become a stdio or inline-secret API.
 *
 * @param input - untrusted caller object from the Remote or a test.
 * @returns The normalized, deeply plain configuration.
 */
export function validateServerInput(input: unknown): McpServerConfig {
  if (!isRecord(input)) throw new McpError('MCP_SCHEMA_INVALID', 'server must be an object')
  assertNoUnknownKeys(input, SERVER_KEYS, 'server')

  const serverName = input.serverName
  if (typeof serverName !== 'string' || !SERVER_NAME_PATTERN.test(serverName)) {
    throw new McpError('MCP_SERVER_NAME_INVALID', 'serverName must match [A-Za-z0-9_-]{1,32}')
  }

  const rawUrl = input.url
  if (typeof rawUrl !== 'string' || rawUrl.length === 0) {
    throw new McpError('MCP_URL_INVALID', 'url must be a non-empty string')
  }
  let parsed: URL
  try {
    parsed = new URL(rawUrl)
  } catch {
    throw new McpError('MCP_URL_INVALID', `url is not a valid absolute URL: ${rawUrl}`)
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new McpError('MCP_URL_INVALID', 'url must use http: or https:')
  }
  if (parsed.username !== '' || parsed.password !== '') {
    throw new McpError('MCP_URL_INVALID', 'url must not embed credentials; configure headersFromEnv instead')
  }

  const rawHeaders = input.headersFromEnv ?? {}
  if (!isRecord(rawHeaders)) throw new McpError('MCP_SCHEMA_INVALID', 'headersFromEnv must be an object')
  const headersFromEnv: Record<string, string> = {}
  const seenHeaders = new Set<string>()
  for (const [header, envName] of Object.entries(rawHeaders)) {
    if (!HEADER_NAME_PATTERN.test(header)) {
      throw new McpError('MCP_HEADER_INVALID', `headersFromEnv has an invalid HTTP header name: ${header}`)
    }
    const normalizedHeader = header.toLowerCase()
    if (seenHeaders.has(normalizedHeader)) {
      throw new McpError('MCP_HEADER_INVALID', `headersFromEnv repeats header ${header} with different casing`)
    }
    seenHeaders.add(normalizedHeader)
    if (typeof envName !== 'string' || !ENV_NAME_PATTERN.test(envName)) {
      throw new McpError('MCP_ENV_NAME_INVALID', `headersFromEnv.${header} must name an environment variable ([A-Za-z_][A-Za-z0-9_]*)`)
    }
    headersFromEnv[header] = envName
  }

  const rawHostManaged = input.hostManagedHeaders ?? []
  if (!Array.isArray(rawHostManaged)) {
    throw new McpError('MCP_SCHEMA_INVALID', 'hostManagedHeaders must be an array of header names')
  }
  const hostManagedHeaders: string[] = []
  const seenHostManaged = new Set<string>()
  for (const rawHeader of rawHostManaged) {
    if (typeof rawHeader !== 'string' || !HEADER_NAME_PATTERN.test(rawHeader)) {
      throw new McpError('MCP_HEADER_INVALID', `hostManagedHeaders has an invalid HTTP header name: ${String(rawHeader)}`)
    }
    const normalizedHeader = rawHeader.toLowerCase()
    if (seenHostManaged.has(normalizedHeader)) continue
    if (!Object.keys(headersFromEnv).some(header => header.toLowerCase() === normalizedHeader)) {
      throw new McpError('MCP_HEADER_INVALID', `hostManagedHeaders includes ${rawHeader} but headersFromEnv does not`)
    }
    seenHostManaged.add(normalizedHeader)
    hostManagedHeaders.push(rawHeader)
  }

  const enabled = input.enabled ?? true
  if (typeof enabled !== 'boolean') throw new McpError('MCP_SCHEMA_INVALID', 'enabled must be a boolean')

  const toolCallTimeoutMs = input.toolCallTimeoutMs ?? DEFAULT_TOOL_CALL_TIMEOUT_MS
  if (typeof toolCallTimeoutMs !== 'number' || !Number.isInteger(toolCallTimeoutMs) || toolCallTimeoutMs < 1 || toolCallTimeoutMs > MAX_TOOL_CALL_TIMEOUT_MS) {
    throw new McpError('MCP_SCHEMA_INVALID', `toolCallTimeoutMs must be an integer between 1 and ${MAX_TOOL_CALL_TIMEOUT_MS}`)
  }

  return {
    serverName,
    url: parsed.toString(),
    headersFromEnv,
    hostManagedHeaders,
    enabled,
    toolCallTimeoutMs,
  }
}

/**
 * Resolve configured headers from the process environment at connect time.
 * A missing or empty value fails the mount; it is never replaced with an empty
 * header. The returned values must not be logged or persisted.
 *
 * @param config - normalized server row.
 * @param env - environment to read.
 * @returns Header values for the live transport only.
 */
export function resolveHeaders(
  config: Pick<McpServerConfig, 'headersFromEnv' | 'hostManagedHeaders'>,
  env: NodeJS.ProcessEnv = process.env,
): Record<string, string> {
  const managed = new Set(config.hostManagedHeaders.map(header => header.toLowerCase()))
  const headers: Record<string, string> = {}
  for (const [header, envName] of Object.entries(config.headersFromEnv)) {
    if (managed.has(header.toLowerCase())) {
      headers[header] = HOST_MANAGED_HEADER_VALUE
      continue
    }
    const value = env[envName]
    if (typeof value !== 'string' || value.length === 0) {
      throw new McpError('MCP_ENV_MISSING', `headersFromEnv.${header}: environment variable ${envName} is not set`)
    }
    headers[header] = value
  }
  return headers
}

/** Validate one complete document and reject duplicate namespaces. */
export function validateConfigDocument(input: unknown): McpConfigDocument {
  if (!isRecord(input)) throw new McpError('MCP_SCHEMA_INVALID', 'mcp.json must contain an object')
  assertNoUnknownKeys(input, DOCUMENT_KEYS, 'mcp.json')
  if (input.version !== MCP_CONFIG_VERSION) {
    throw new McpError('MCP_SCHEMA_INVALID', `mcp.json.version must be ${MCP_CONFIG_VERSION}`)
  }
  if (!Array.isArray(input.servers)) throw new McpError('MCP_SCHEMA_INVALID', 'mcp.json.servers must be an array')
  const servers: McpServerConfig[] = []
  const names = new Set<string>()
  input.servers.forEach((row, index) => {
    const config = validateServerInput(row)
    if (names.has(config.serverName)) {
      throw new McpError('MCP_DUPLICATE_SERVER', `mcp.json.servers[${index}] repeats serverName ${config.serverName}`)
    }
    names.add(config.serverName)
    servers.push(config)
  })
  return { version: MCP_CONFIG_VERSION, servers }
}

/** Render one document deterministically, without any environment value. */
export function serializeConfigDocument(servers: readonly McpServerConfig[]): string {
  const document: McpConfigDocument = {
    version: MCP_CONFIG_VERSION,
    servers: [...servers]
      .sort((a, b) => a.serverName.localeCompare(b.serverName))
      .map(config => ({
        serverName: config.serverName,
        url: config.url,
        headersFromEnv: Object.fromEntries(Object.entries(config.headersFromEnv).sort(([a], [b]) => a.localeCompare(b))),
        hostManagedHeaders: [...config.hostManagedHeaders],
        enabled: config.enabled,
        toolCallTimeoutMs: config.toolCallTimeoutMs,
      })),
  }
  return `${JSON.stringify(document, null, 2)}\n`
}

/**
 * Read and validate `mcp.json`; a missing file is an empty registry.
 *
 * @param file - absolute path.
 * @returns The validated document.
 */
export async function readConfigFile(file: string): Promise<McpConfigDocument> {
  let text: string
  try {
    text = await readFile(file, 'utf8')
  } catch (error) {
    if (isNodeError(error) && error.code === 'ENOENT') return { version: MCP_CONFIG_VERSION, servers: [] }
    throw new McpError('MCP_CONFIG_READ_FAILED', `cannot read ${file}: ${messageOf(error)}`, { cause: error })
  }
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch (error) {
    throw new McpError('MCP_SCHEMA_INVALID', `${file} is not valid JSON: ${messageOf(error)}`, { cause: error })
  }
  try {
    return validateConfigDocument(parsed)
  } catch (error) {
    if (error instanceof McpError) throw new McpError(error.code, `${file}: ${error.message}`, { cause: error })
    throw error
  }
}

/**
 * Write one document atomically: a private temporary file in the same directory
 * is renamed over the target, so a crash leaves either the old or the new file.
 * Only environment variable names are serialized.
 *
 * @param file - absolute target path.
 * @param servers - validated rows.
 */
export async function writeConfigFile(file: string, servers: readonly McpServerConfig[]): Promise<void> {
  const text = serializeConfigDocument(servers)
  // The document can only contain env-var names, but keep the file private: a
  // later schema extension cannot accidentally expose a value through it.
  const temporary = `${file}.${process.pid}.${Date.now()}.${Math.random().toString(16).slice(2)}.tmp`
  try {
    await mkdir(dirname(file), { recursive: true })
    await writeFile(temporary, text, { encoding: 'utf8', mode: 0o600 })
    await rename(temporary, file)
  } catch (error) {
    await rm(temporary, { force: true }).catch(() => {})
    throw new McpError('MCP_CONFIG_WRITE_FAILED', `cannot write ${file}: ${messageOf(error)}`, { cause: error })
  }
}

function isNodeError(error: unknown): error is NodeJS.ErrnoException {
  return error instanceof Error && 'code' in error
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

