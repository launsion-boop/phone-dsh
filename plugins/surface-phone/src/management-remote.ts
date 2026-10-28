// SPDX-License-Identifier: MIT
// Phone-only Remote facades over existing DSH services; no duplicate state.

import type { Context } from '@deepseek-ai/cordis'
import { Remote, TypertRemoteService } from '@deepseek-ai/dsh-typert-protocol'
import type { ScheduleCreateRequest, ScheduleRecord } from '@deepseek-ai/dsh-schedule'
import type {} from '@deepseek-ai/dsh-schedule'
import type {} from '@deepseek-ai/dsh-tools'
import type {} from '@deepseek-ai/dsh-tools'

export interface PhoneScheduleCreateRequest extends ScheduleCreateRequest {
  /** Existing host-visible session that receives the reminder. */
  readonly sessionId: string
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
    const { sessionId, ...scheduleRequest } = request
    return this.ctx.schedule.create(sessionId, scheduleRequest)
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
function markRemoteMethod(
  name: 'createSchedule' | 'listTools',
  options?: Parameters<typeof Remote>[0],
): void {
  const descriptor = Object.getOwnPropertyDescriptor(PhoneManagementRemote.prototype, name)
  if (typeof descriptor?.value !== 'function') throw new TypeError(`phone remote method is missing: ${name}`)
  let initializer: ((this: PhoneManagementRemote) => void) | undefined
  const context = {
    name,
    private: false,
    static: false,
    addInitializer(fn: (this: PhoneManagementRemote) => void) { initializer = fn },
  } as ClassMethodDecoratorContext<PhoneManagementRemote, (this: PhoneManagementRemote, ...args: never[]) => unknown>
  const decorator = options === undefined ? Remote : Remote(options)
  decorator(descriptor.value, context)
  if (initializer === undefined) throw new TypeError(`phone Remote decorator did not initialize: ${name}`)
  // Typert's initializer marks the prototype; a one-level prototype object
  // gives it the same receiver shape as the class initializer contract.
  initializer.call(Object.create(PhoneManagementRemote.prototype) as PhoneManagementRemote)
}

markRemoteMethod('createSchedule', {
  resources: { session: (request: PhoneScheduleCreateRequest) => request.sessionId },
})
markRemoteMethod('listTools')
