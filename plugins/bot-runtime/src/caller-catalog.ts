// SPDX-License-Identifier: MIT
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import { scopeOf } from '@deepseek-ai/dsh-scope'
import { botOwnedSessions } from './bot-sessions.ts'
import type { BotOwnedSessions } from './bot-sessions.ts'

/**
 * The App's MCP `tools/list` has no caller identity of its own. The Worker
 * names the App-minted session explicitly on its own per-session catalog
 * request; the host egress still injects the real bearer. The App resolves the
 * session through the same principal `tools/call` attribution uses.
 */
export const CALLER_SESSION_HEADER = 'x-pdsh-bot-session'
/** The App appends this roster line only after it identified a caller. */
export const CALLER_CATALOG_ROSTER_MARKER = 'Available bots:'
export const CALLER_CATALOG_TOOL_NAMES = Object.freeze(['SendToAgent', 'CreateTeammate'])

const PHONE_TOOL_PREFIX = 'mcp__phone__'
const DEFAULT_TIMEOUT_MS = 2_000
const DEFAULT_CACHE_TTL_MS = 2_000

export interface CallerCatalogTool {
  readonly name: string
  readonly description: string
}

export interface CallerCatalog {
  readonly tools: readonly CallerCatalogTool[]
}

export interface CallerCatalogRequestOptions {
  readonly timeoutMs: number
  readonly signal?: AbortSignal
}

export interface CallerCatalogConfig {
  /** App MCP endpoint (`.../mcp`). Defaults to `PDSH_PHONE_MCP_URL`. */
  readonly url?: string
  /** Bearer placeholder; the host egress replaces it for the loopback route. */
  readonly token?: string
  readonly timeoutMs?: number
  readonly cacheTtlMs?: number
  /**
   * Shared Worker-local Bot session registry. The identity bridge already
   * owns it; passing it avoids providing the same service twice during one
   * plugin apply.
   */
  readonly ownedSessions?: BotOwnedSessions
  /** Test seam: replace the HTTP request while keeping the same transport shape. */
  readonly request?: (sessionId: string, options: CallerCatalogRequestOptions) => Promise<CallerCatalog | undefined>
  /** Test seam: replace `fetch` for the default HTTP request. */
  readonly fetch?: typeof fetch
}

/**
 * One identified caller's team-tool surface. `descriptions` contains only the
 * tools the App still advertises; an absent `CreateTeammate` means the caller
 * is not the main Bot.
 */
export interface CallerToolPlan {
  readonly descriptions: Readonly<Record<string, string>>
  readonly includeCreateTeammate: boolean
}

/** Derive the `/mcp` endpoint from the identity-register URL. */
export function callerCatalogUrl(registerUrl: string): string {
  return registerUrl
    .replace(/\/identity\/register\/?$/, '/mcp')
    .replace(/\/mcp\/$/, '/mcp')
}

export function defaultCallerCatalogUrl(env: NodeJS.ProcessEnv = process.env): string {
  const raw = String(env.PDSH_PHONE_MCP_URL ?? '').trim()
  if (!raw) return ''
  return callerCatalogUrl(raw)
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

/** Validate the JSON-RPC `tools/list` result without trusting extra fields. */
export function parseCallerCatalogResponse(value: unknown): CallerCatalog | undefined {
  if (!isRecord(value) || !isRecord(value.result) || !Array.isArray(value.result.tools)) {
    return undefined
  }
  const tools: CallerCatalogTool[] = []
  for (const entry of value.result.tools) {
    if (!isRecord(entry) || typeof entry.name !== 'string' || typeof entry.description !== 'string') {
      continue
    }
    tools.push(Object.freeze({ name: entry.name, description: entry.description }))
  }
  return Object.freeze({ tools: Object.freeze(tools) })
}

export function createCallerCatalogRequest(
  config: Pick<CallerCatalogConfig, 'url' | 'token' | 'fetch'> = {},
): (sessionId: string, options: CallerCatalogRequestOptions) => Promise<CallerCatalog | undefined> {
  const url = String(config.url ?? defaultCallerCatalogUrl()).trim()
  const token = String(config.token ?? process.env.PDSH_PHONE_MCP_TOKEN ?? '')
  const fetchImpl = config.fetch ?? fetch
  return async (sessionId, options) => {
    if (!url || !token || !sessionId) return undefined
    // The host-issued per-run egress credential. Missing/empty omits the
    // header so the host fails this catalog read closed instead of treating
    // the request as a trusted MCP client.
    const egressToken = String(process.env.PDSH_MCP_EGRESS_TOKEN ?? '')
    const egress: Record<string, string> = egressToken === '' ? {} : { 'X-PDSH-MCP-Egress': egressToken }
    const controller = new AbortController()
    const timer = setTimeout(
      () => controller.abort(new Error('caller catalog request timed out')),
      Math.max(1, options.timeoutMs),
    )
    const abort = (): void => controller.abort(options.signal?.reason)
    options.signal?.addEventListener('abort', abort, { once: true })
    try {
      const response = await fetchImpl(url, {
        method: 'POST',
        headers: {
          authorization: `Bearer ${token}`,
          'content-type': 'application/json',
          accept: 'application/json',
          [CALLER_SESSION_HEADER]: sessionId,
          ...egress,
        },
        body: JSON.stringify({
          jsonrpc: '2.0',
          id: 'dshbot-tools-list',
          method: 'tools/list',
          params: {},
        }),
        signal: options.signal === undefined
          ? controller.signal
          : AbortSignal.any([controller.signal, options.signal]),
      })
      if (!response.ok) return undefined
      return parseCallerCatalogResponse(await response.json())
    } catch {
      return undefined
    } finally {
      clearTimeout(timer)
      options.signal?.removeEventListener('abort', abort)
    }
  }
}

/**
 * Interpret one App catalog response.
 *
 * The roster marker is the only proof that the App identified a caller: a
 * static fallback has no roster line, so it must not change any Bot's surface.
 */
export function planCallerCatalog(catalog: CallerCatalog | undefined): CallerToolPlan | undefined {
  if (catalog === undefined) return undefined
  const byName = new Map(catalog.tools.map(tool => [tool.name, tool]))
  const send = byName.get('SendToAgent')
  if (send === undefined || !send.description.includes(CALLER_CATALOG_ROSTER_MARKER)) {
    return undefined
  }
  const descriptions: Record<string, string> = {}
  for (const name of CALLER_CATALOG_TOOL_NAMES) {
    const tool = byName.get(name)
    if (tool !== undefined) descriptions[name] = tool.description
  }
  return Object.freeze({
    descriptions: Object.freeze(descriptions),
    includeCreateTeammate: byName.has('CreateTeammate'),
  })
}

export function agentSessionId(agent: Agent | undefined): string {
  return String(agent?.id || agent?.session?.id || '')
}

interface CallerCatalogState {
  readonly scope: Context
  readonly registrations: Map<string, () => void>
  readonly descriptions: Map<string, string>
  restriction?: () => void
  plan?: CallerToolPlan
}

/**
 * Install the per-caller tool-surface hook.
 *
 * DSH 0.2.2 collects the prompt tool schemas before the
 * `system-prompt/assemble` waterfall and re-attaches them afterwards, so a
 * listener cannot mutate that turn's tool list. The supported seam is the
 * scoped registry: a scoped registration shadows the global MCP tool and a
 * scoped `restrict()` hides it. `agent/created` is awaited before the first
 * prompt assembly; later refreshes run on status/assembly/tool-result events
 * and land before the next step or turn.
 */
export function installCallerCatalog(ctx: Context, config: CallerCatalogConfig = {}): void {
  const request = config.request ?? createCallerCatalogRequest(config)
  const timeoutMs = Math.max(1, config.timeoutMs ?? DEFAULT_TIMEOUT_MS)
  const cacheTtlMs = Math.max(0, config.cacheTtlMs ?? DEFAULT_CACHE_TTL_MS)
  const owned = config.ownedSessions ?? botOwnedSessions(ctx)
  const cache = new Map<string, { readonly at: number; readonly value: CallerCatalog | undefined }>()
  const inFlight = new Map<string, Promise<CallerCatalog | undefined>>()
  const states = new Map<string, CallerCatalogState>()

  const catalogFor = (sessionId: string, signal?: AbortSignal): Promise<CallerCatalog | undefined> => {
    const cached = cache.get(sessionId)
    if (cached !== undefined && Date.now() - cached.at < cacheTtlMs) {
      return Promise.resolve(cached.value)
    }
    const pending = inFlight.get(sessionId)
    if (pending !== undefined) return pending
    const requestPromise = request(sessionId, {
      timeoutMs,
      ...signal === undefined ? {} : { signal },
    }).then(value => {
      cache.set(sessionId, { at: Date.now(), value })
      return value
    }).catch(() => {
      cache.set(sessionId, { at: Date.now(), value: undefined })
      return undefined
    }).finally(() => {
      inFlight.delete(sessionId)
    })
    inFlight.set(sessionId, requestPromise)
    return requestPromise
  }

  type GlobalTool = NonNullable<ReturnType<typeof ctx.tools.get>>
  const globals = new Map<string, GlobalTool>()

  const cacheGlobals = (): void => {
    for (const name of CALLER_CATALOG_TOOL_NAMES) {
      const publicName = `${PHONE_TOOL_PREFIX}${name}`
      if (globals.has(publicName)) continue
      const current = ctx.tools.get(publicName)
      if (current !== undefined) globals.set(publicName, current)
    }
  }

  const ensureTool = (state: CallerCatalogState, name: string): void => {
    const publicName = `${PHONE_TOOL_PREFIX}${name}`
    if (state.registrations.has(publicName)) return
    const global = globals.get(publicName) ?? ctx.tools.get(publicName)
    if (global === undefined) return
    globals.set(publicName, global)
    // The description is read during prompt collection, so a getter keeps it
    // current without re-registering the scoped shadow. `CreateTeammate` is
    // also gated by `when` so a non-main Bot never admits the scoped clone;
    // the scoped restriction hides the global definition in the same scope.
    const definition = {
      ...global,
      get description(): string {
        return state.descriptions.get(publicName) ?? global.description
      },
    }
    try {
      const dispose = name === 'CreateTeammate'
        ? state.scope.tools.register(definition, {
            when: () => state.plan?.includeCreateTeammate === true,
          })
        : state.scope.tools.register(definition)
      state.registrations.set(publicName, dispose)
    } catch {
      // The scope is already unwinding or the global tool list is changing;
      // the next event retries.
    }
  }

  const applyPlan = (state: CallerCatalogState, plan: CallerToolPlan): void => {
    cacheGlobals()
    state.plan = plan
    for (const name of CALLER_CATALOG_TOOL_NAMES) {
      const publicName = `${PHONE_TOOL_PREFIX}${name}`
      const description = plan.descriptions[name]
      if (description !== undefined) state.descriptions.set(publicName, description)
      ensureTool(state, name)
    }

    const createName = `${PHONE_TOOL_PREFIX}CreateTeammate`
    if (plan.includeCreateTeammate) {
      state.restriction?.()
      state.restriction = undefined
    } else if (state.restriction === undefined) {
      try {
        state.restriction = state.scope.tools.restrict({ deny: [createName] })
      } catch {
        // `mcp-phone` has not published the global tool yet (or the scope is
        // unwinding); the next event retries.
      }
    }
  }

  const stateFor = (agent: Agent): CallerCatalogState | undefined => {
    const sessionId = agentSessionId(agent)
    if (sessionId === '') return undefined
    const existing = states.get(sessionId)
    if (existing !== undefined) return existing
    const context = (agent as { ctx?: Context }).ctx
    if (context === undefined || scopeOf(context) === undefined) return undefined
    const state: CallerCatalogState = {
      scope: context,
      registrations: new Map(),
      descriptions: new Map(),
    }
    states.set(sessionId, state)
    return state
  }

  const refresh = async (agent: Agent | undefined, signal?: AbortSignal): Promise<void> => {
    if (agent === undefined) return
    const sessionId = agentSessionId(agent)
    if (sessionId === '' || !owned.has(sessionId)) return
    const state = stateFor(agent)
    if (state === undefined) return
    const catalog = await catalogFor(sessionId, signal)
    const plan = planCallerCatalog(catalog)
    // A missing/failed catalog keeps the last successfully applied surface;
    // on first use there is no state yet, so the static catalog stays.
    if (plan === undefined) return
    applyPlan(state, plan)
  }

  ctx.on('agent/created', async ({ agent }) => {
    await refresh(agent)
  })
  ctx.on('agent/status', ({ agent }) => {
    void refresh(agent)
  })
  ctx.on('agent/disposed', ({ agent }) => {
    const sessionId = agentSessionId(agent)
    if (sessionId !== '') states.delete(sessionId)
  })
  ctx.on('tools/result', exec => {
    const bare = exec.name.startsWith(PHONE_TOOL_PREFIX)
      ? exec.name.slice(PHONE_TOOL_PREFIX.length)
      : exec.name
    if (exec.agent === undefined || !CALLER_CATALOG_TOOL_NAMES.includes(bare)) return
    void refresh(exec.agent)
  })
  ctx.on('system-prompt/assemble', (assembly, context, next) => {
    const agent = (context as { agent?: Agent }).agent
    if (agent !== undefined) void refresh(agent)
    return next()
  })
}
