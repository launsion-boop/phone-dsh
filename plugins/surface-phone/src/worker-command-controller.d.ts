// SPDX-License-Identifier: MIT
// Type surface for the Worker command acceptance route used by the Node tests.
// The production plugin is JavaScript; this declaration keeps the test suite
// under the workspace's strict TypeScript gate without changing runtime code.

export const WORKER_COMMAND_PATH: string
export const WORKER_COMMAND_PROTOCOL: string
export const WORKER_COMMAND_MAX_BODY_BYTES: number
export const WORKER_COMMAND_DEFAULT_BUDGET_MS: number
export const WORKER_COMMAND_MAX_BUDGET_MS: number
export const WORKER_COMMAND_MAX_OUTPUT_BYTES: number
export const WORKER_COMMAND_MAX_SNAPSHOT_ENTRIES: number
export const WORKER_COMMAND_MAX_SNAPSHOT_BYTES: number
export const WORKER_COMMAND_SNAPSHOT_TIMEOUT_MS: number
export const WORKER_COMMAND_LOCATION_ENV: string
export const WORKER_COMMAND_FORK_ENV: string
export const WORKER_COMMAND_ROOTS: readonly string[]
export const WORKER_COMMAND_BOUNDED_OPENDIR: symbol
export const WORKER_COMMAND_BOUNDED_DIRECTORY_OPENER: symbol
export function markBoundedDirectoryOpener<T extends (...args: never[]) => unknown>(opendir: T): T

export class WorkerCommandError extends Error {
  readonly code: string
  readonly status: number
  constructor(code: string, message: string, status?: number)
}

export interface WorkerCommandRequest {
  command: string
  program: string
  cwd: string
  budgetMs: number
  scenarioId: string
  sessionId: string
  turn: number
  assertionIndex: number
  completionWatermark?: number
}

export interface WorkerCommandReceipt {
  protocol: string
  receipt_id: string
  location: {
    kind: string
    carrier: string
    worker_vfs: boolean
    host_process: boolean
    fork: string
  }
  binding: {
    scenario_id: string
    session_id: string
    turn: number
    assertion_index: number
    completion_watermark?: number
  }
  source: {
    kind: string
    fork: boolean
    roots?: string[]
    missing_roots?: string[]
    source_mseq_start?: number
    source_mseq_end?: number
    source_frozen?: boolean
    digest: string
    entries: number
    bytes: number
    failure?: string
    failure_detail?: string
    timed_out?: boolean
  }
  execution: {
    program: string
    cwd: string
    budget_ms: number
    duration_ms: number
    exit_code: number
    timed_out: boolean
    cancelled: boolean
    stdout: string
    stderr: string
    stdout_bytes: number
    stderr_bytes: number
    stdout_truncated: boolean
    stderr_truncated: boolean
    failure?: string
    failure_detail?: string
  }
  model_requests: number
  live_workspace_unchanged: boolean
  verification?: {
    unchanged: boolean
    method: string
    digest?: string
    failure?: string
    failure_detail?: string
  }
  side_effects: {
    isolated: boolean
    live_workspace: boolean
    journal: boolean
    changes: Array<{ path: string, change: string, bytes: number }>
    changed: number
  }
}

export function validateWorkerCommandRequest(body: unknown): WorkerCommandRequest
export function normalizeWorkerVfsPath(path: string): string
export function workerCommandEnvironment(cwd: string): Record<string, string>
export function captureWorkerVfsFork(options?: {
  roots?: readonly string[]
  requiredPaths?: readonly string[]
  fs?: Record<string, unknown>
  root?: string
  mseqStart?: number
  mseqEnd?: number
  maxEntries?: number
  maxBytes?: number
  deadline?: number
  signal?: AbortSignal
}): Promise<{
  backend: unknown
  entries: Map<string, Uint8Array>
  digest: string
  bytes: number
  roots: string[]
  missing: string[]
  mseqStart?: number
  mseqEnd?: number
  sourceFrozen: boolean
}>
export interface ForkFileSystemFace {
  readFile(path: string): Promise<Buffer>
  writeFile(path: string, data: string | Uint8Array, options?: { flag?: string, mode?: number, encoding?: string }): Promise<void>
  appendFile(path: string, data: string | Uint8Array, options?: { encoding?: string }): Promise<void>
  stat(path: string): Promise<unknown>
  lstat(path: string): Promise<unknown>
  access(path: string): Promise<void>
  mkdir(path: string, options?: { recursive?: boolean, mode?: number }): Promise<void>
  readdir(path: string, options?: { withFileTypes?: boolean }): Promise<unknown>
  rm(path: string, options?: { recursive?: boolean, force?: boolean }): Promise<void>
  cp(from: string, to: string, options?: { recursive?: boolean }): Promise<void>
  rename(from: string, to: string): Promise<void>
  chmod(path: string, mode: number): Promise<void>
  link(existing: string, next: string): Promise<void>
}

export function createForkFileSystemFace(backend: unknown): {
  face: ForkFileSystemFace
  syncReaddir: (path: string, options: { withFileTypes: true }) => unknown
}
export function executeWorkerCommandInFork(
  request: WorkerCommandRequest,
  options?: Record<string, unknown>,
): Promise<WorkerCommandReceipt>
export function registerWorkerCommandRoute(
  ctx: { effect(run: () => unknown): () => void },
  connection: { fetch: { register(options: Record<string, unknown>): () => void } },
  options?: Record<string, unknown>,
): () => void
