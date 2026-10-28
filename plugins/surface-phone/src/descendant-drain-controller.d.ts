// SPDX-License-Identifier: MIT
// Type surface for the phone-only scoped descendant drain used by the Node
// tests. The production plugin is JavaScript; this declaration keeps the test
// suite under the workspace's strict TypeScript gate.

export const DESCENDANT_DRAIN_PATH: string
export const DESCENDANT_DRAIN_PROTOCOL: string
export const DESCENDANT_DRAIN_MAX_BODY_BYTES: number
export const DESCENDANT_DRAIN_DEFAULT_BUDGET_MS: number
export const DESCENDANT_DRAIN_MAX_BUDGET_MS: number
export const DESCENDANT_DRAIN_MAX_ROOTS: number

export class DescendantDrainError extends Error {
  readonly code: string
  readonly status: number
  constructor(code: string, message: string, status?: number)
}

export interface DescendantDrainRequest {
  rootSessionIds: string[]
  budgetMs: number
}

export interface DescendantDrainReceipt {
  protocol: string
  roots: string[]
  missing: string[]
  /** Live/drained descendant session ids, including cold-resumed old headers. */
  descendants: string[]
  durationMs: number
}

export function validateDescendantDrainRequest(body: unknown): DescendantDrainRequest
export function drainDescendantSessions(
  ctx: {
    agents?: {
      get(id: string): { id: string } | undefined
      roots?(): Array<{ id: string }>
    }
    get?(name: string): unknown
    subagents?: unknown
  },
  rootSessionIds: readonly string[],
  signal?: AbortSignal,
): Promise<DescendantDrainReceipt>
export function registerDescendantDrainRoute(
  ctx: { effect(run: () => unknown): () => void },
  connection: { fetch: { register(options: Record<string, unknown>): () => void } },
): () => void
