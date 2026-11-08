// SPDX-License-Identifier: MIT
// Phone-only Remote facades over existing DSH services; no duplicate state.

import type { Context } from '@deepseek-ai/cordis'
import { Remote, TypertRemoteService } from '@deepseek-ai/dsh-typert-protocol'
import type { ScheduleCreateRequest, ScheduleRecord } from '@deepseek-ai/dsh-schedule'
import { SessionId } from '@deepseek-ai/dsh-session'
import type {} from '@deepseek-ai/dsh-tools'

type ScheduleTiming = ScheduleCreateRequest['timing']

export interface PhoneScheduleCreateRequest {
  readonly sessionId: string
  readonly title: string
  readonly prompt: string
  readonly after_seconds?: Extract<ScheduleTiming, { kind: 'after' }>['after_seconds']
  readonly at?: Extract<ScheduleTiming, { kind: 'at' }>['at']
  readonly every_seconds?: Extract<ScheduleTiming, { kind: 'every' }>['every_seconds']
  readonly daily?: Extract<ScheduleTiming, { kind: 'daily' }>['daily']
  readonly weekly?: Extract<ScheduleTiming, { kind: 'weekly' }>['weekly']
  readonly cron?: Extract<ScheduleTiming, { kind: 'cron' }>['cron']
}

export interface PhoneToolInventoryValue {
  /** Indicates the inventory belongs to the shared host composition. */
  readonly scope: 'global'
  /** Current globally visible tool schemas; MCP tool names are server-qualified. */
  readonly tools: ReturnType<Context['tools']['schemas']>
}

/** Narrow phone UI additions that call the Worker’s existing DSH services. */
export class PhoneManagementRemote extends TypertRemoteService {
  static inject = ['schedule', 'tools', 'typert']

  constructor(ctx: Context) {
    super(ctx, 'phoneManagementRemote', { namespace: 'phone' })
  }

  /** Create one reminder by invoking the already mounted DSH ScheduleService. */
  createSchedule(request: PhoneScheduleCreateRequest): Promise<ScheduleRecord> {
    const { sessionId, title, prompt, after_seconds, at, every_seconds, daily, weekly, cron } = request
    const timings: ScheduleTiming[] = []
    if (after_seconds !== undefined) timings.push({ kind: 'after', after_seconds })
    if (at !== undefined) timings.push({ kind: 'at', at })
    if (every_seconds !== undefined) timings.push({ kind: 'every', every_seconds })
    if (daily !== undefined) timings.push({ kind: 'daily', daily })
    if (weekly !== undefined) timings.push({ kind: 'weekly', weekly })
    if (cron !== undefined) timings.push({ kind: 'cron', cron })
    const [timing] = timings
    if (timing === undefined || timings.length !== 1) {
      throw new Error('Exactly one reminder selector is required.')
    }
    return this.ctx.schedule.create({ title, prompt, timing, target: { kind: 'session', sessionId: SessionId(sessionId) } })
  }

  /** Read current global tool schemas without reaching into ToolRuntime internals. */
  listTools(): PhoneToolInventoryValue {
    return { scope: 'global', tools: this.ctx.tools.schemas() }
  }
}

// Apply the same standard DSH method decorators explicitly instead of using
// `@Remote` syntax. Node's built-in TypeScript type stripping can then import
// the phone surface directly in tests, while Typert still receives the
// canonical method markers when the service module is evaluated.
function markRemoteMethod<Args extends unknown[], Result>(
  name: 'createSchedule' | 'listTools',
  method: (this: PhoneManagementRemote, ...args: Args) => Result,
  decorate: (value: typeof method, context: ClassMethodDecoratorContext<PhoneManagementRemote, typeof method>) => void,
): void {
  let initializer: ((this: PhoneManagementRemote) => void) | undefined
  decorate(method, {
    kind: 'method',
    name,
    private: false,
    static: false,
    metadata: undefined,

    access: { has: target => name in target, get: () => method },
    addInitializer(fn) { initializer = fn },
  })
  if (initializer === undefined) throw new TypeError(`phone Remote decorator did not initialize: ${name}`)
  // Typert marks the receiver's prototype, as it would on service construction.
  initializer.call(Object.create(PhoneManagementRemote.prototype))
}

markRemoteMethod('createSchedule', PhoneManagementRemote.prototype.createSchedule,
  Remote<PhoneManagementRemote, [PhoneScheduleCreateRequest], Promise<ScheduleRecord>>({
    resources: { session: request => SessionId(request.sessionId) },
  }))
markRemoteMethod('listTools', PhoneManagementRemote.prototype.listTools, Remote)
