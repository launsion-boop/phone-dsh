// SPDX-License-Identifier: MIT
/**
 * Agent-preset proxy over the official registry.
 *
 * The phone profile may compose no preset roster. In that case every action
 * refuses with the actual missing service; this module never fabricates a
 * default preset or an empty list that could be mistaken for a real roster.
 * `select` also validates the target against the real Host Session index; a
 * retained subagent fallback is not a preset target.
 * @module @phone-dsh/dsh-feature-admin/agent-presets
 */

import type { Context } from '@deepseek-ai/cordis'
import type { TypertRegistryContract } from '@deepseek-ai/dsh-typert-protocol'
import type { Agent } from '@deepseek-ai/dsh-agent'
import type {} from '@deepseek-ai/dsh-agent'
import type { AgentPresetRegistry } from '@deepseek-ai/dsh-agent-preset-registry'
import type {} from '@deepseek-ai/dsh-agent-preset-registry'
import type { SessionListValue } from '@deepseek-ai/dsh-api-session-controller'
import type {
  AgentPresetsRequest,
  AgentPresetsValue,
} from './contracts.ts'
import { FeatureAdminError, invalidRequest, notFound, unsupported } from './errors.ts'

/** The official registry methods this proxy forwards. */
export type AgentPresetService = Pick<AgentPresetRegistry, 'remoteExportList' | 'readDocument' | 'select'>

/** Resolve a wire session identity to the Agent the registry selects on. */
export interface AgentLookup {
  resolve(id: string): Agent | undefined | Promise<Agent | undefined>
}

/** Live-only Agent registry, kept as a fallback for compositions without Typert. */
interface LiveAgentRegistry {
  get(id: string): Agent | undefined
  resolve?(id: string): Agent | undefined | Promise<Agent | undefined>
}

/** The Host Session list the shipped Web client also reads. */
interface HostSessionCatalog {
  list(request: { readonly cursor?: string }, signal: AbortSignal): Promise<SessionListValue>
}

/** Attached Sessions when a composition mounts the store without the API controller. */
interface LiveSessionStore {
  list(): readonly {
    readonly id: string
    readonly header: { readonly origin?: 'subagent' }
  }[]
}

/** The one Host-managed Session index a preset target must belong to. */
export interface HostManagedSessions {
  readonly source: 'host-list' | 'live-store'
  readonly ids: ReadonlySet<string>
}

/**
 * Read the real Host-managed Session set rather than guessing from an id.
 *
 * `sessionController.list()` is the same attached+cold list the Web Session
 * list uses; `ctx.sessions.list()` is the attached fallback for compositions
 * that mount the store without the API controller. Subagent-origin Sessions
 * are not preset targets even when the Host catalog can read them.
 * @param ctx - Host context.
 * @returns the managed Session ids and which real source supplied them.
 */
export async function hostManagedSessions(ctx: Context): Promise<HostManagedSessions> {
  const catalog = ctx.get('sessionController') as HostSessionCatalog | undefined
  if (catalog !== undefined && typeof catalog.list === 'function') {
    try {
      const value = await catalog.list({}, new AbortController().signal)
      return {
        source: 'host-list',
        ids: new Set(value.items
          .filter(item => item.origin !== 'subagent')
          .map(item => String(item.sessionId))),
      }
    } catch (error) {
      throw translatePresetError(error)
    }
  }
  const sessions = ctx.get('sessions') as LiveSessionStore | undefined
  if (sessions !== undefined && typeof sessions.list === 'function') {
    return {
      source: 'live-store',
      ids: new Set(sessions.list()
        .filter(session => session.header?.origin !== 'subagent')
        .map(session => String(session.id))),
    }
  }
  throw unsupported(
    'Neither ctx.sessionController nor ctx.sessions is mounted, so no Host-managed Session set can validate a preset target.',
  )
}

/**
 * Resolve the Agent the same way the official gateway does.
 *
 * `ctx.typert.lookups.get('agent')` is the lookup
 * `ApiSessionAgentController` configures to resume cold and restarted blank
 * Sessions. `ctx.agents.get()` sees live Agents only, so it is just a fallback
 * for a composition that did not configure the lookup.
 * @param ctx - Host context.
 * @param sessionId - wire Session identity.
 * @returns the resolved Agent.
 */
async function resolveAgent(ctx: Context, sessionId: string): Promise<Agent> {
  const typert = ctx.get('typert') as TypertRegistryContract | undefined
  const lookup = typert?.lookups.get('agent') as unknown as AgentLookup | undefined
  const agents = ctx.get('agents') as unknown as LiveAgentRegistry | undefined
  if (lookup === undefined && agents === undefined) {
    throw unsupported('Neither ctx.typert agent lookups nor ctx.agents is mounted, so no Agent can be bound to the requested preset.')
  }
  if (lookup !== undefined) {
    try {
      const agent = await lookup.resolve(sessionId)
      if (agent !== undefined) return agent
    } catch (error) {
      throw translatePresetError(error)
    }
  }
  const agent = agents?.resolve === undefined ? agents?.get(sessionId) : await agents.resolve(sessionId)
  if (agent === undefined) {
    throw notFound(`No live or resumable Agent is bound to session ${JSON.stringify(sessionId)}`)
  }
  return agent
}

function requiredString(value: unknown, field: string): string {
  if (typeof value !== 'string' || value === '') throw invalidRequest(`${field} must be a non-empty string`)
  return value
}

/** Forward one of the three official preset reads/writes. */
export async function proxyAgentPresets(
  ctx: Context,
  request: AgentPresetsRequest,
): Promise<AgentPresetsValue> {
  const presets = ctx.get('agentPresets')
  if (presets === undefined) {
    throw unsupported(
      'ctx.agentPresets is not mounted in this profile. There is no preset roster to list, read or select; '
      + 'the settings tab does not invent one.',
    )
  }
  if (request === null || typeof request !== 'object' || typeof request.action !== 'string') {
    throw invalidRequest('agentPresets request must carry an action')
  }
  const input = request as {
    readonly action?: unknown
    readonly presetId?: unknown
    readonly sessionId?: unknown
  }
  switch (input.action) {
    case 'list':
      return { action: 'list', roster: await presets.remoteExportList() }
    case 'read': {
      const presetId = requiredString(input.presetId, 'presetId')
      try {
        return { action: 'read', document: await presets.readDocument(presetId) }
      } catch (error) {
        throw translatePresetError(error)
      }
    }
    case 'select': {
      const presetId = requiredString(input.presetId, 'presetId')
      const sessionId = requiredString(input.sessionId, 'sessionId')
      const managed = await hostManagedSessions(ctx)
      if (!managed.ids.has(sessionId)) {
        throw notFound(
          `Session ${JSON.stringify(sessionId)} is not in this Host's managed Session list (${managed.source}); `
          + 'a retained subagent or unlisted id is not a preset target.',
          'session/not-found',
        )
      }
      const agent = await resolveAgent(ctx, sessionId)
      try {
        return { action: 'select', presetId: await presets.select(agent, presetId) }
      } catch (error) {
        throw translatePresetError(error)
      }
    }
    default:
      throw invalidRequest(`unknown agentPresets action: ${String(input.action)}`)
  }
}

/** Preserve the official domain code while narrowing it to the wire vocabulary. */
function translatePresetError(error: unknown): FeatureAdminError {
  if (error instanceof FeatureAdminError) return error
  const code = typeof error === 'object' && error !== null && 'code' in error && typeof error.code === 'string'
    ? error.code
    : undefined
  const reason = error instanceof Error ? error.message : String(error)
  if (code === 'agent-preset/not-found' || code === 'session/not-found') return notFound(reason, code)
  if (code === 'agent-preset/invalid') return new FeatureAdminError('conflict', reason, code)
  if (code === 'agent-preset/locked' || code === 'session/agent-busy' || code === 'session/writer-held') {
    return new FeatureAdminError('conflict', reason, code)
  }
  return new FeatureAdminError('internal', reason, code)
}
