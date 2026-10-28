// SPDX-License-Identifier: MIT
/**
 * Host half of `@phone-dsh/dsh-phone-model-config`.
 *
 * A read-only Remote over the non-secret `PDSH_MODEL_PROVIDER_JSON` the app
 * injects at Worker start. It neither reads the Keychain nor accepts writes:
 * the native host owns editing and credentials.
 * @module @phone-dsh/dsh-phone-model-config
 */
import type { Context } from '@deepseek-ai/cordis'
import { Remote, TypertRemoteService } from '@deepseek-ai/dsh-typert-protocol'
import { type ModelConfigSnapshot, readModelConfig } from './model-config.ts'

/** Loader row name; the profile mounts this package by name. */
export const name = 'phone-model-config'

/** Expose the projection on the Host's `phone` Remote namespace. */
export class PhoneModelConfigRemote extends TypertRemoteService {
  static inject = ['typert']

  constructor(ctx: Context) {
    super(ctx, 'modelConfig', { namespace: 'phone' })
  }

  /** Read the current non-secret provider projection; never sees a key. */
  modelConfig(): ModelConfigSnapshot {
    return readModelConfig()
  }
}

// The Worker's Node type stripping cannot evaluate TypeScript decorators, so
// apply the canonical Remote marker explicitly. This is the same pattern the
// phone surface uses for its own Remote methods.
function markRemoteMethod(method: 'modelConfig'): void {
  const descriptor = Object.getOwnPropertyDescriptor(PhoneModelConfigRemote.prototype, method)
  if (typeof descriptor?.value !== 'function') throw new TypeError(`phone model config method is missing: ${method}`)
  let initializer: ((this: PhoneModelConfigRemote) => void) | undefined
  const context = {
    name: method,
    private: false,
    static: false,
    addInitializer(fn: (this: PhoneModelConfigRemote) => void) { initializer = fn },
  } as ClassMethodDecoratorContext<PhoneModelConfigRemote, (this: PhoneModelConfigRemote, ...args: any[]) => any>
  Remote(descriptor.value, context)
  if (initializer === undefined) throw new TypeError(`phone model config Remote decorator did not initialize: ${method}`)
  initializer.call(Object.create(PhoneModelConfigRemote.prototype) as PhoneModelConfigRemote)
}

markRemoteMethod('modelConfig')

/** Mount the Remote service; the loader row only names this package. */
export function apply(ctx: Context): void {
  ctx.plugin(PhoneModelConfigRemote)
}
