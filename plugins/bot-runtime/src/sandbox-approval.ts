// SPDX-License-Identifier: MIT
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import { approvalUrl, postApproval } from './approval-gate.ts'
import type { ApprovalOutcome } from './approval-gate.ts'
import { argsDigest } from './identity-bridge.ts'
import type { BotIdentityCall } from './identity-bridge.ts'

export type SandboxApprovalOutcome = 'allowed-once' | 'rejected' | 'cancelled' | 'unavailable'

export interface SandboxApprovalRequest {
  readonly agent?: Agent
  readonly callId?: string
  readonly signal?: AbortSignal
  readonly reason?: string
  readonly displayReason?: { zh?: string; en?: string }
  readonly toolName?: string
  readonly arguments?: Record<string, unknown>
}

export interface SandboxApprovalConfig {
  readonly approvalUrl?: string
  readonly bridgeToken?: string
  readonly lookup?: (callId: string, sessionId?: string) => BotIdentityCall | undefined
  readonly request?: (payload: Record<string, unknown>, signal?: AbortSignal) => Promise<ApprovalOutcome>
}

export function describeEscalation(req: SandboxApprovalRequest): { action: string; detail: string; mode: string; resource: string } {
  const reason = String(req.reason ?? '').trim()
  const match = /^escalate sandbox to ([^:]+):\s*([\s\S]*)$/.exec(reason)
  const mode = match?.[1]?.trim() ?? ''
  const justification = match
    ? match[2]!.trim()
    : String(req.displayReason?.zh ?? req.displayReason?.en ?? '').trim()
  const action = mode ? `放寬檔案沙箱到 ${mode}` : '放寬檔案沙箱'
  return {
    action,
    detail: justification || (reason && reason !== action ? reason : ''),
    mode,
    resource: reason || action,
  }
}

export function approvalPayload(req: SandboxApprovalRequest, identity?: BotIdentityCall): Record<string, unknown> {
  const described = describeEscalation(req)
  const tool = identity?.name ?? String(req.toolName ?? 'bash')
  const args = identity?.arguments ?? req.arguments ?? {}
  return {
    source: 'structural',
    sessionId: req.agent?.id ? String(req.agent.id) : '',
    onceOnly: true,
    tool,
    action: described.action,
    detail: described.detail,
    command: String(args.command ?? ''),
    argsDigest: argsDigest(args),
    alwaysScope: 'none',
    target: described.resource,
    askAction: 'sandbox-escalation',
    callId: req.callId ?? null,
    pattern: 'sandbox-escalation',
    effects: [{
      tool,
      operation: 'sandbox-escalation',
      resource: described.resource,
      label: described.action,
      detail: described.detail,
      target: described.resource,
      kind: 'sandbox-escalation',
      mutability: 'write',
      policy: 'ask',
    }],
  }
}

export function outcomeFromDecision(decision: ApprovalOutcome & { timedOut?: boolean }): SandboxApprovalOutcome {
  if (!decision || decision.ok !== true) {
    const error = String(decision?.error ?? decision?.message ?? '')
    return /cancel|timed out/i.test(error) ? 'cancelled' : 'unavailable'
  }
  if (decision.timedOut) return 'cancelled'
  return decision.allowed ? 'allowed-once' : 'rejected'
}

export async function answerSandboxApproval(req: SandboxApprovalRequest, config: SandboxApprovalConfig = {}): Promise<SandboxApprovalOutcome> {
  if (!req.agent?.id) return 'unavailable'
  if (req.signal?.aborted) return 'cancelled'
  const identity = config.lookup?.(String(req.callId ?? ''), String(req.agent.id)) ?? (req.arguments === undefined ? undefined : {
    sessionId: String(req.agent.id), name: String(req.toolName ?? 'bash'),
    arguments: req.arguments, argsDigest: argsDigest(req.arguments),
  })
  if (!identity) return 'unavailable'
  try {
    const send = config.request ?? ((payload: Record<string, unknown>, signal?: AbortSignal) => postApproval(
      config.approvalUrl ?? approvalUrl(),
      config.bridgeToken ?? String(process.env.PDSH_PHONE_MCP_TOKEN ?? ''),
      payload,
      signal,
    ))
    return outcomeFromDecision(await send(approvalPayload(req, identity), req.signal))
  } catch {
    return 'unavailable'
  }
}

export default function dshbotSandboxApproval(ctx: Context, config: SandboxApprovalConfig = {}): void {
  const registry = ctx.get('dshbotIdentityCalls') as { get(callId: string, sessionId?: string): BotIdentityCall | undefined } | undefined
  const lookup = config.lookup ?? ((callId: string, sessionId?: string) => registry?.get(callId, sessionId))
  ctx.on('approval/request', (req: SandboxApprovalRequest) => answerSandboxApproval(req, { ...config, lookup }))
}

dshbotSandboxApproval.inject = ['approval']
