// SPDX-License-Identifier: MIT
import type { Context } from '@deepseek-ai/cordis'
import { scopeOf } from '@deepseek-ai/dsh-scope'

/**
 * Bot-only scoped shadows that give the read/search tools an optional public
 * `activity` sentence. DSH logs `tool/call.arguments` before the tool body, so
 * the field stays in the durable event; the shadow strips it before the
 * original handler runs. These five tools have no identity registration and no
 * structural approval, so the field never enters an attribution or approval
 * digest.
 */
const TOOL_NAMES = ['read', 'glob', 'grep', 'web_search', 'web_fetch'] as const
type ToolName = typeof TOOL_NAMES[number]
type RegisteredTool = NonNullable<ReturnType<Context['tools']['get']>>
type PresentationMeta = NonNullable<RegisteredTool['output']['presentationMeta']>
type PresentResult = NonNullable<RegisteredTool['presentResult']>

const ACTIVITY_DESCRIPTION =
  '可选：本次调用的公开进展，一句用户当前语言的话：当前任务对象 + 当前进展'
  + '（约 10–20 个中文字，带结果最多约 28 字）。不要写命令摘要、完整路径、'
  + '长 URL、凭证或内部 id。宿主执行前会删除此字段。'

interface InstalledTool {
  readonly source: RegisteredTool
  readonly dispose: () => void
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

/** Remove the display-only field without mutating the logged arguments. */
export function stripActivity(args: unknown): unknown {
  if (!isRecord(args)) return args
  const { activity: _activity, ...rest } = args
  return rest
}

/** Clone one tool definition with an optional model-facing `activity` field. */
export function withActivityField(tool: RegisteredTool): RegisteredTool {
  const parameters = isRecord(tool.parameters) ? tool.parameters : { type: 'object' }
  const properties = isRecord(parameters.properties) ? parameters.properties : {}
  return {
    ...tool,
    parameters: {
      ...parameters,
      type: 'object',
      properties: {
        ...properties,
        activity: { type: 'string', maxLength: 160, description: ACTIVITY_DESCRIPTION },
      },
    },
    async execute(args, exec) {
      return tool.execute(stripActivity(args), exec)
    },
    output: {
      ...tool.output,
      render(args, value) {
        return tool.output.render(stripActivity(args), value)
      },
      ...tool.output.presentationMeta === undefined ? {} : {
        presentationMeta(args: unknown, value: Parameters<PresentationMeta>[1]) {
          return tool.output.presentationMeta!(stripActivity(args), value)
        },
      },
    },
    ...tool.presentCall === undefined ? {} : {
      presentCall(args: unknown) {
        return tool.presentCall!(stripActivity(args))
      },
    },
    ...tool.presentResult === undefined ? {} : {
      presentResult(args: unknown, result: Parameters<PresentResult>[1]) {
        return tool.presentResult!(stripActivity(args), result)
      },
    },
    ...tool.isConcurrencySafe === undefined ? {} : {
      isConcurrencySafe(args: unknown) {
        return tool.isConcurrencySafe!(stripActivity(args))
      },
    },
  }
}

/**
 * Register the Bot-scoped shadows in the current agent scope. The plugin is
 * mounted in `preset-phone-bot`; an unscoped mount is ignored so the workbench
 * surface never gains the field.
 */
export default function activityIntent(ctx: Context): void {
  if (scopeOf(ctx) === undefined) return
  const installed = new Map<ToolName, InstalledTool>()

  const install = (name: ToolName): void => {
    const source = ctx.tools.get(name)
    if (source === undefined) return
    const current = installed.get(name)
    if (current?.source === source) return
    if (current !== undefined) {
      current.dispose()
      installed.delete(name)
    }
    try {
      const dispose = ctx.tools.register(withActivityField(source))
      installed.set(name, { source, dispose })
    } catch {
      // The scope is unwinding or another install already owns the shadow;
      // the next tools/change or assembly retries.
    }
  }

  const installAll = (): void => {
    for (const name of TOOL_NAMES) install(name)
  }

  installAll()
  ctx.on('tools/change', installAll)
  // The first prompt assembly is already covered by the preset composition;
  // this retry covers a tool that appears after this plugin's apply.
  ctx.on('system-prompt/assemble', (_assembly, _context, next) => {
    installAll()
    return next()
  })
  ctx.effect(() => () => {
    for (const entry of installed.values()) entry.dispose()
    installed.clear()
  })
}

activityIntent.inject = ['tools']
