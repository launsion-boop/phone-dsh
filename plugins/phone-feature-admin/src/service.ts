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
import { FeatureAdminError } from './errors.ts'
import { proxyAgentPresets } from './agent-presets.ts'
import { listInstalledPlugins, setInstalledPluginEnabled } from './plugin-toggle.ts'
import { assertSkillCatalogInvalidation, invalidateSkillCatalog, SkillsStore } from './skills.ts'

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

  constructor(ctx: Context, config: FeatureAdminConfig = {}) {
    super(ctx, 'featureAdmin', { namespace: FEATURE_ADMIN_NAMESPACE })
    this.skills = new SkillsStore(
      config.skillsRoot ?? SKILLS_ROOT,
      () => invalidateSkillCatalog(this.ctx),
    )
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

  /** Atomically write one skill, then invalidate the live skills catalog. */
  skillsWrite(name: string, content: string): Promise<FeatureAdminResult<SkillMutationView>> {
    return attempt(() => {
      assertSkillCatalogInvalidation(this.ctx)
      return this.skills.write(name, content)
    })
  }

  /** Delete one skill, then invalidate the live skills catalog. */
  skillsDelete(name: string): Promise<FeatureAdminResult<SkillMutationView>> {
    return attempt(() => {
      assertSkillCatalogInvalidation(this.ctx)
      return this.skills.delete(name)
    })
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
