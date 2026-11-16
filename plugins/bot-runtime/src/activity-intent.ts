// SPDX-License-Identifier: MIT
import type { Agent } from '@deepseek-ai/dsh-agent'
import type { Context } from '@deepseek-ai/cordis'
import { scopeChainOf, scopeOf } from '@deepseek-ai/dsh-scope'
import { botOwnedSessions } from './bot-sessions.ts'

/**
 * Bot-only activity metadata for the read/search tools. The phone-bot preset
 * registers its own tool-fs/tool-fs-search/tool-web definitions in the preset
 * scope; an Agent is a child scope. This is a global row: on agent/created it
 * installs the shadow in the Agent's own scope, wrapping the current Bot-scope
 * definition. The plugin row is not inside the preset because preset plugin
 * contexts are not the Agent scope the first prompt is collected from. A later
 * source re-registration updates the held source instead of re-registering the
 * shadow.
 */
const TOOL_NAMES = ['read', 'glob', 'grep', 'web_search', 'web_fetch'] as const
type ToolName = typeof TOOL_NAMES[number]
type RegisteredTool = NonNullable<ReturnType<Context['tools']['get']>>
type PresentationMeta = NonNullable<RegisteredTool['output']['presentationMeta']>
type PresentResult = NonNullable<RegisteredTool['presentResult']>
type ScopeKey = object

const WRAPPED = Symbol('phone-dsh.activity-intent')
const ACTIVITY_DESCRIPTION =
  '可选：本次调用的公开进展，一句用户当前语言的话：当前任务对象 + 当前进展'
  + '（约 10–20 个中文字，带结果最多约 28 字）。不要写命令摘要、完整路径、'
  + '长 URL、凭证或内部 id。宿主执行前会删除此字段。'

interface SourceState {
  source: RegisteredTool
}

interface InstalledTool {
  readonly state: SourceState
  readonly dispose: () => void
}

interface AgentState {
  readonly scope: ScopeKey
  readonly context: Context
  readonly installed: Map<ToolName, InstalledTool>
  queue: Promise<void>
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function isWrapped(tool: RegisteredTool): boolean {
  return (tool as RegisteredTool & { [WRAPPED]?: boolean })[WRAPPED] === true
}

/** Remove the display-only field without mutating the logged arguments. */
export function stripActivity(args: unknown): unknown {
  if (!isRecord(args)) return args
  const { activity: _activity, ...rest } = args
  return rest
}

function withActivityParameters(parameters: RegisteredTool['parameters']): RegisteredTool['parameters'] {
  const root = isRecord(parameters) ? parameters : { type: 'object' }
  const properties = isRecord(root.properties) ? root.properties : {}
  return {
    ...root,
    type: 'object',
    properties: {
      ...properties,
      activity: { type: 'string', maxLength: 160, description: ACTIVITY_DESCRIPTION },
    },
  }
}

function withActivityOutput(output: RegisteredTool['output']): RegisteredTool['output'] {
  const presentationMeta = output.presentationMeta
  return {
    ...output,
    render(args, value) {
      return output.render(stripActivity(args), value)
    },
    ...presentationMeta === undefined ? {} : {
      presentationMeta(args: unknown, value: Parameters<PresentationMeta>[1]) {
        return presentationMeta(stripActivity(args), value)
      },
    },
  }
}

/** Stable wrapper whose getters always follow the current Bot-scope source. */
function activityWrapper(name: string, state: SourceState): RegisteredTool {
  const wrapper: RegisteredTool = {
    name,
    get description() { return state.source.description },
    get parameters() { return withActivityParameters(state.source.parameters) },
    get output() { return withActivityOutput(state.source.output) },
    get deferLoading() { return state.source.deferLoading },
    get timeoutMs() { return state.source.timeoutMs },
    get presentCall() {
      const present = state.source.presentCall
      return present === undefined ? undefined : (args: unknown) => present(stripActivity(args))
    },
    get presentResult() {
      const present = state.source.presentResult
      return present === undefined ? undefined : (args: unknown, result: Parameters<PresentResult>[1]) => present(stripActivity(args), result)
    },
    get isConcurrencySafe() {
      const classify = state.source.isConcurrencySafe
      return classify === undefined ? undefined : (args: unknown) => classify(stripActivity(args))
    },
    get projectContent() { return state.source.projectContent },
    get finalizeContent() { return state.source.finalizeContent },
    async execute(args, exec) {
      return state.source.execute(stripActivity(args), exec)
    },
  }
  Object.defineProperty(wrapper, WRAPPED, { value: true })
  return wrapper
}

/**
 * Install the Agent-scoped shadows from a global row. Only a Bot-owned session
 * (the `gb-*` namespace / `phone/botClaimSession`) is admitted; the
 * `agent/created` listener is awaited before the first prompt assembly, so the
 * wrapper is present in the tool schema collection. Workbench/global agents
 * are untouched.
 */
export default function activityIntent(ctx: Context): void {
  const states = new Map<ScopeKey, AgentState>()

  const contextOfAgent = (agent: Agent | undefined): Context | undefined =>
    (agent as { ctx?: Context } | undefined)?.ctx

  const sessionIdOf = (agent: Agent | undefined): string =>
    String(agent?.id || agent?.session?.id || '')

  /** Nearest inherited non-wrapper definition. */
  const sourceFor = (scope: ScopeKey, name: ToolName): RegisteredTool | undefined => {
    const global = ctx.tools.get(name)
    for (const key of scopeChainOf(scope)) {
      const candidate = ctx.tools.get(name, key)
      if (candidate !== undefined && candidate !== global && !isWrapped(candidate)) return candidate
    }
    // No inherited Bot definition: skip rather than silently wrapping a
    // global tool with different configuration. The next tools/change retries.
    return undefined
  }

  const webReady = (name: ToolName, provider: string): boolean => {
    if (name !== 'web_search' && name !== 'web_fetch') return true
    const web = ctx.get('web') as {
      searchReady?(provider: string): boolean
      fetchReady?(provider: string): boolean
    } | undefined
    return name === 'web_search'
      ? web?.searchReady?.(provider) === true
      : web?.fetchReady?.(provider) === true
  }

  const install = async (state: AgentState, name: ToolName): Promise<void> => {
    const source = sourceFor(state.scope, name)
    const current = state.installed.get(name)
    if (source === undefined) {
      if (current !== undefined) {
        current.dispose()
        state.installed.delete(name)
      }
      return
    }
    if (current !== undefined) {
      current.state.source = source
      return
    }
    const sourceState: SourceState = { source }
    const when = name === 'web_search'
      ? ({ modelSelection }: { modelSelection: { provider: string } }) => webReady(name, modelSelection.provider)
      : name === 'web_fetch'
        ? ({ modelSelection }: { modelSelection: { provider: string } }) => webReady(name, modelSelection.provider)
        : undefined
    let dispose: (() => void) | undefined
    try {
      const fiber = await state.context.plugin({
        inject: ['tools'],
        apply(scoped: Context) {
          dispose = scoped.tools.register(activityWrapper(name, sourceState),
            when === undefined ? undefined : { when })
        },
      })
      if (dispose === undefined) return
      state.installed.set(name, { state: sourceState, dispose: () => { void fiber.dispose() } })
    } catch {
      // The Agent scope is unwinding or another definition owns this layer;
      // the next tools/change or agent/status retries.
    }
  }

  const installAll = async (state: AgentState): Promise<void> => {
    for (const name of TOOL_NAMES) await install(state, name)
  }

  const enqueue = (state: AgentState): Promise<void> => {
    state.queue = state.queue.then(() => installAll(state)).catch(() => {})
    return state.queue
  }

  const stateFor = (agent: Agent | undefined): AgentState | undefined => {
    const sessionId = sessionIdOf(agent)
    // Only a session the channel/identity actually claimed. `has` intentionally
    // accepts an App-claimed legacy non-`gb-` Bot; an unclaimed workbench does
    // not match. Do not replace this with a namespace-only predicate.
    if (agent === undefined || !botOwnedSessions(ctx).has(sessionId)) return undefined
    const context = contextOfAgent(agent)
    const scope = context === undefined ? undefined : scopeOf(context)
    if (context === undefined || scope === undefined) return undefined
    const existing = states.get(scope)
    if (existing !== undefined) return existing
    const state: AgentState = { scope, context, installed: new Map(), queue: Promise.resolve() }
    states.set(scope, state)
    return state
  }

  ctx.on('agent/created', async ({ agent }) => {
    const state = stateFor(agent)
    if (state !== undefined) await enqueue(state)
  })
  ctx.on('agent/status', ({ agent }) => {
    const state = stateFor(agent)
    if (state !== undefined) void enqueue(state)
  })
  ctx.on('agent/disposed', ({ agent }) => {
    const context = contextOfAgent(agent)
    const scope = context === undefined ? undefined : scopeOf(context)
    if (scope === undefined) return
    const state = states.get(scope)
    if (state === undefined) return
    for (const entry of state.installed.values()) entry.dispose()
    states.delete(scope)
  })
  ctx.on('tools/change', () => {
    for (const state of states.values()) void enqueue(state)
  })
  ctx.effect(() => () => {
    for (const state of states.values()) {
      for (const entry of state.installed.values()) entry.dispose()
    }
    states.clear()
  })
}

activityIntent.inject = ['tools']
