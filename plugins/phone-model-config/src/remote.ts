// SPDX-License-Identifier: MIT
/**
 * Hand-written Client contribution for `phone/modelConfig`.
 *
 * The generated descriptor form is small and stable; writing it here keeps the
 * package independent from the DSH monorepo build while still mounting through
 * the same `ctx.remote.$mount()` seam as generated `/remote` artifacts. The
 * descriptor is Source-JSON (no schema codec) because the value is a read-only
 * projection owned by this package.
 * @module @phone-dsh/dsh-phone-model-config/remote
 */
import type { TypertRemoteContribution } from '@deepseek-ai/dsh-typert-protocol'

/** Browser-side descriptor for the single read-only Remote method. */
export const MODEL_CONFIG_CONTRIBUTION: TypertRemoteContribution = Object.freeze({
  package: '@phone-dsh/dsh-phone-model-config',
  descriptors: Object.freeze([Object.freeze({
    id: '@phone-dsh/dsh-phone-model-config#phone/modelConfig',
    service: 'modelConfig',
    namespace: 'phone',
    method: 'modelConfig',
    invocation: Object.freeze({ kind: 'direct' as const }),
    parameters: Object.freeze([]),
    result: Object.freeze({ mode: 'src-json' as const }),
  })]),
})
