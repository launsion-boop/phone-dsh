// SPDX-License-Identifier: MIT
/** `phone/featureAdmin` Remote: installed capabilities only, no package install. */

import type { Context } from '@deepseek-ai/cordis'
import type {} from '@deepseek-ai/dsh-app-boot'
import type {} from '@deepseek-ai/dsh-host-plugin-inventory'
import type {} from '@deepseek-ai/dsh-skill'
import type {} from '@deepseek-ai/dsh-agent'
import type {} from '@deepseek-ai/dsh-agent-preset-registry'
import { Remote, TypertRemoteService } from '@deepseek-ai/dsh-typert-protocol'
import {
  FEATURE_ADMIN_NAMESPACE,
  SKILLS_ROOT,
  type AgentPresetsRequest,
  type AgentPresetsValue,
  type FeatureAdminConfig,
  type FeatureAdminFailureCode,
  type FeatureAdminResult,
  type PluginListView,
  type PluginToggleView,
  type SkillDocumentView,
  type SkillFileView,
  type SkillMutationView,
} from './contracts.ts'
import { FeatureAdminError, invalidRequest } from './errors.ts'
import { proxyAgentPresets } from './agent-presets.ts'
import { listInstalledPlugins, setInstalledPluginEnabled } from './plugin-toggle.ts'
import {
  assertSkillCatalogInvalidation,
  invalidateSkillCatalog,
  MAX_SKILL_BYTES,
  skillFileName,
  SkillsStore,
} from './skills.ts'
import {
  HostSkillMutationJournal,
  MAX_RECORDED_CONTENT_BYTES,
  newSkillMutationOperationId,
  skillMutationFailureCode,
  type SkillMutationJournal,
} from './mutation-records.ts'

/** Translate any helper failure into the stable browser contract. */
function failure(error: unknown): FeatureAdminResult<never> {
  if (error instanceof FeatureAdminError) {
    return {
      ok: false,
      code: error.code,
      reason: error.message,
      ...error.domainCode === undefined ? {} : { domainCode: error.domainCode },
    }
  }
  const reason = error instanceof Error ? error.message : String(error)
  const code = typeof error === 'object' && error !== null && 'code' in error && typeof error.code === 'string'
    ? error.code
    : ''
  const failureCode: FeatureAdminFailureCode = code.startsWith('E') ? 'io-error' : 'internal'
  return { ok: false, code: failureCode, reason }
}

async function attempt<Value>(work: () => Value | Promise<Value>): Promise<FeatureAdminResult<Value>> {
  try {
    return { ok: true, value: await work() }
  } catch (error) {
    return failure(error)
  }
}

/**
 * Host service exposed as `phone/pluginList`, `phone/pluginSetEnabled`,
 * `phone/skills*` and `phone/agentPresets`.
 */
export class PhoneFeatureAdmin extends TypertRemoteService {
  private readonly skills: SkillsStore
  private readonly mutations: SkillMutationJournal

  constructor(ctx: Context, config: FeatureAdminConfig = {}) {
    super(ctx, 'featureAdmin', { namespace: FEATURE_ADMIN_NAMESPACE })
    this.skills = new SkillsStore(
      config.skillsRoot ?? SKILLS_ROOT,
      () => invalidateSkillCatalog(this.ctx),
    )
    this.mutations = config.skillMutations ?? new HostSkillMutationJournal()
  }

  /** Read DSH's own inventory and state the no-install platform boundary. */
  pluginList(): Promise<FeatureAdminResult<PluginListView>> {
    return attempt(() => listInstalledPlugins(
      this.ctx.get('pluginInventory'),
      this.ctx.get('profileContext'),
    ))
  }

  /** Atomically write disable/enable to the live home profile patch. */
  pluginSetEnabled(entryId: string, enabled: boolean): Promise<FeatureAdminResult<PluginToggleView>> {
    return attempt(() => setInstalledPluginEnabled(
      this.ctx.get('profileContext'),
      this.ctx.get('pluginInventory'),
      entryId,
      enabled,
    ))
  }

  /** List flat `.md` files under the one allowed skills root. */
  skillsList(): Promise<FeatureAdminResult<readonly SkillFileView[]>> {
    return attempt(() => this.skills.list())
  }

  /** Read one skill body after the realpath/symlink checks. */
  skillsRead(name: string): Promise<FeatureAdminResult<SkillDocumentView>> {
    return attempt(() => this.skills.read(name))
  }

  /**
   * Atomically write one skill, then invalidate the live skills catalog.
   *
   * The raw `requested` fact is durable before the file is touched. A real
   * file success then appends `applied`; only that fact feeds the host's one
   * `skill.changed`. A request append failure leaves the file untouched.
   */
  skillsWrite(name: string, content: string): Promise<FeatureAdminResult<SkillMutationView>> {
    return attempt(async () => {
      assertSkillCatalogInvalidation(this.ctx)
      const fileName = this.validateWrite(name, content)
      const operationId = newSkillMutationOperationId()
      await this.mutations.begin({
        operationId, action: 'write', file: fileName, content,
      })
      let view: SkillMutationView
      try {
        view = await this.skills.write(fileName, content)
      } catch (error) {
        await this.recordFailed(operationId, error)
        throw error
      }
      try {
        await this.mutations.applied(operationId)
      } catch {
        throw new FeatureAdminError(
          'io-error',
          'the skill file changed but its applied raw record could not be appended; '
          + 'the change is not indexed. Save again as a new operation to repair it.',
          'record-not-applied',
        )
      }
      return view
    })
  }

  /**
   * Delete one skill after its exact body becomes the raw input of the
   * requested fact. The commit re-reads the file and refuses to unlink a body
   * that changed during the requested append.
   */
  skillsDelete(name: string): Promise<FeatureAdminResult<SkillMutationView>> {
    return attempt(async () => {
      assertSkillCatalogInvalidation(this.ctx)
      const fileName = skillFileName(name)
      const handle = await this.skills.prepareDelete(fileName)
      const operationId = newSkillMutationOperationId()
      await this.mutations.begin({
        operationId, action: 'delete', file: fileName, content: handle.content,
      })
      let view: SkillMutationView
      try {
        view = await handle.commit()
      } catch (error) {
        await this.recordFailed(operationId, error)
        throw error
      }
      try {
        await this.mutations.applied(operationId)
      } catch {
        throw new FeatureAdminError(
          'io-error',
          'the skill file was deleted but its applied raw record could not be appended; '
          + 'the change is not indexed. Save again as a new operation to repair it.',
          'record-not-applied',
        )
      }
      return view
    })
  }

  /** Validate before any raw fact exists; an invalid page request touches nothing. */
  private validateWrite(name: unknown, content: unknown): string {
    const fileName = skillFileName(name)
    if (typeof content !== 'string') throw invalidRequest('skill content must be a string')
    const bytes = Buffer.byteLength(content, 'utf8')
    if (bytes > MAX_SKILL_BYTES) {
      throw invalidRequest(`skill content exceeds ${String(MAX_SKILL_BYTES)} bytes`)
    }
    if (bytes > MAX_RECORDED_CONTENT_BYTES) {
      throw new FeatureAdminError(
        'invalid-request',
        `skill content exceeds the ${String(MAX_RECORDED_CONTENT_BYTES)}-byte raw-record bound; `
        + 'the skill was not written',
        'record-content-too-large',
      )
    }
    return fileName
  }

  /** A failed file operation is recorded with its bounded code; never applied. */
  private async recordFailed(operationId: string, error: unknown): Promise<void> {
    try {
      await this.mutations.failed(operationId, skillMutationFailureCode(error))
    } catch {
      // The requested fact is durable and the file did not change. A missing
      // failed fact is a bounded repair item, not a false applied/current.
    }
  }

  /**
   * Proxy the official preset list/read/select; refuse honestly when absent.
   *
   * The Remote accepts either one request object (`{ request: {...} }`) or the
   * flattened fields (`{ action, presetId, sessionId }`), so an older page and
   * a direct in-process caller use the same method without a second endpoint.
   */
  agentPresets(
    action?: AgentPresetsRequest['action'] | AgentPresetsRequest,
    presetId?: string,
    sessionId?: string,
    request?: AgentPresetsRequest,
  ): Promise<FeatureAdminResult<AgentPresetsValue>> {
    const normalized = request
      ?? (typeof action === 'object' && action !== null ? action : { action, presetId, sessionId })
    return attempt(() => proxyAgentPresets(this.ctx, normalized as AgentPresetsRequest))
  }
}

/**
 * Mark one class method with the standard Typert Remote decorator without
 * TS decorator syntax, so Node's type-stripping tests can import this module.
 */
type FeatureAdminRemoteMethod = (this: PhoneFeatureAdmin, ...args: unknown[]) => unknown

/** Mark one already-defined prototype method through the public decorator face. */
function markRemoteMethod(name: keyof PhoneFeatureAdmin): void {
  const methodName = String(name)
  const descriptor = Object.getOwnPropertyDescriptor(PhoneFeatureAdmin.prototype, name)
  if (typeof descriptor?.value !== 'function') {
    throw new TypeError(`phone feature admin method is missing: ${methodName}`)
  }
  const method = descriptor.value as FeatureAdminRemoteMethod
  let initializer: ((this: PhoneFeatureAdmin) => void) | undefined
  const context: ClassMethodDecoratorContext<PhoneFeatureAdmin, FeatureAdminRemoteMethod> = {
    kind: 'method',
    name: methodName,
    private: false,
    static: false,
    access: {
      has: object => methodName in object,
      get: object => object[methodName as keyof PhoneFeatureAdmin] as FeatureAdminRemoteMethod,
    },
    metadata: {},
    addInitializer(fn: (this: PhoneFeatureAdmin) => void) { initializer = fn },
  }
  Remote(method, context)
  if (initializer === undefined) {
    throw new TypeError(`phone feature admin Remote decorator did not initialize: ${methodName}`)
  }
  initializer.call(Object.create(PhoneFeatureAdmin.prototype) as PhoneFeatureAdmin)
}

markRemoteMethod('pluginList')
markRemoteMethod('pluginSetEnabled')
markRemoteMethod('skillsList')
markRemoteMethod('skillsRead')
markRemoteMethod('skillsWrite')
markRemoteMethod('skillsDelete')
markRemoteMethod('agentPresets')
