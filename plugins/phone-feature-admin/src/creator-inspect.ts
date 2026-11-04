// SPDX-License-Identifier: MIT
/** The official read-only inspector, without mounting the desktop VM runner. */
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import { CordisInspectRegistryService } from '@deepseek-ai/dsh-cordis-host-runner'
import type {} from '@deepseek-ai/dsh-system-prompt'

export const name = 'phone-cordis-inspect'
export const inject = ['systemPrompt']

export function apply(ctx: Context): CordisInspectRegistryService {
  ctx.systemPrompt.section({
    name: 'phone-preset-authoring',
    order: 100,
    text: ({scope}) => (scope as Partial<Agent> | undefined)?.session?.header.agentPreset !== 'cordis' ? ''
      : 'Phone Creator supports workspace-local declarative Agent preset bundles. Inspect the Host Config/Tool providers first. Author package.json and cordis.patch.yml in a workspace directory, using only modules already present in the shipped presets, then call plugin_manager install_bundle with the absolute directory. The manifest must have no dependency installation or lifecycle scripts; the patch may insert @deepseek-ai/dsh-agent-preset declarations only, without !!js. The phone installer keeps an owned copy and verifies live activation; read back the roster and YAML before reporting success. npm/Git packages and new JavaScript plugins require desktop DSH. Do not edit the shipped home patch or claim an unsupported package was installed. Opening Creator does not submit a task: act only after the user sends a request. Usual permission approval still applies to profile changes.',
  })
  return new CordisInspectRegistryService(ctx, 15_000)
}
