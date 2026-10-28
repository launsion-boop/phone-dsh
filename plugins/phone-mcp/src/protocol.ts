// SPDX-License-Identifier: MIT
/**
 * Wire and file vocabulary shared by the phone-mcp host, its Remote face, and
 * the browser Settings tab. This module has no runtime dependency so the client
 * bundle can import it type-only.
 *
 * @module @phone-dsh/dsh-phone-mcp/protocol
 */

/** One validated Streamable HTTP MCP server row. */
export interface McpServerConfig {
  /** Stable local namespace; `[A-Za-z0-9_-]{1,32}`. */
  readonly serverName: string
  /** Absolute `http:` or `https:` Streamable HTTP endpoint. */
  readonly url: string
  /** Header name to environment-variable name. Values are resolved only at connect time. */
  readonly headersFromEnv: Readonly<Record<string, string>>
  /**
   * Headers whose real values are injected by the native host for this exact
   * URL. The Worker sends the documented non-secret placeholder; the host
   * gateway drops it and applies the device Keychain value (if any).
   */
  readonly hostManagedHeaders: readonly string[]
  /** Whether the server is mounted at startup and after every successful upsert. */
  readonly enabled: boolean
  /** Per `tools/call` and resource request timeout in milliseconds. */
  readonly toolCallTimeoutMs: number
}

/** Caller input for one upsert; omitted settings use the documented defaults. */
export interface McpServerUpsertRequest {
  readonly serverName: string
  readonly url: string
  readonly headersFromEnv?: Readonly<Record<string, string>>
  readonly hostManagedHeaders?: readonly string[]
  readonly enabled?: boolean
  readonly toolCallTimeoutMs?: number
}

/** Server identity for remove and reconnect. */
export interface McpServerRef {
  readonly serverName: string
}

/** Generic `phone/mcp` dispatcher payload; the specific endpoints stay available. */
export type McpDispatchRequest =
  | { readonly action: 'list' }
  | { readonly action: 'upsert'; readonly request: McpServerUpsertRequest }
  | { readonly action: 'remove'; readonly request: McpServerRef }
  | { readonly action: 'reconnect'; readonly request: McpServerRef }

/** Truthful mount state; `connected` means the initial MCP handshake and tool sync succeeded. */
export type McpServerState = 'disabled' | 'connecting' | 'connected' | 'error'

/** One server as returned to the Settings tab; never carries a header value. */
export interface McpServerView extends McpServerConfig {
  /** Current mount state, derived from the live mcp-client fiber. */
  readonly status: McpServerState
  /** Initial-connection or reconnect failure, when one is known. */
  readonly error?: string
  /** Exact live ToolRuntime registrations owned by this row's mount, never a prefix scan or fabricated list. */
  readonly tools: readonly string[]
  /**
   * Whether requests carry configured headers. `none` is unauthenticated,
   * `headers-env` resolves environment values in the Worker, and
   * `host-managed` receives the placeholder here while the native host injects
   * the dedicated-Keychain value for the exact URL.
   */
  readonly authentication: 'none' | 'headers-env' | 'host-managed'
}

/** One complete Host snapshot for the Settings tab. */
export interface McpSnapshot {
  /** Absolute configuration path (`/dsh/home/mcp.json` by default). */
  readonly file: string
  /** Validated rows plus live status. */
  readonly servers: readonly McpServerView[]
  /** Configuration-file read or schema failure; rows are empty when set. */
  readonly error?: string
}
