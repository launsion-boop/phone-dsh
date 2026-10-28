// SPDX-License-Identifier: MIT
/** One Host-side refusal with a code the browser contract can carry. */
import type { FeatureAdminFailureCode } from './contracts.ts'

/** Refusal raised by the management helpers and translated at the Remote edge. */
export class FeatureAdminError extends Error {
  readonly code: FeatureAdminFailureCode
  readonly domainCode: string | undefined

  constructor(code: FeatureAdminFailureCode, reason: string, domainCode?: string) {
    super(reason)
    this.name = 'FeatureAdminError'
    this.code = code
    this.domainCode = domainCode
  }
}

/** Refuse a capability whose Host service is not mounted. */
export function unsupported(reason: string): FeatureAdminError {
  return new FeatureAdminError('unsupported', reason)
}

/** Refuse malformed input before touching the filesystem or a profile. */
export function invalidRequest(reason: string): FeatureAdminError {
  return new FeatureAdminError('invalid-request', reason)
}

/** Refuse a target that does not exist in the current composition. */
export function notFound(reason: string, domainCode?: string): FeatureAdminError {
  return new FeatureAdminError('not-found', reason, domainCode)
}
