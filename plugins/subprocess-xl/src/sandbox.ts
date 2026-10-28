// SPDX-License-Identifier: MIT
/**
 * `ctx.sandbox` for the inverted execution world (PLAN D12, exec.md §3).
 *
 * `bash -c` and every write the workspace stays in the Worker's own shell, so
 * the host provider's `capabilities.confine` does not describe it. The Worker
 * VFS is the writable boundary for those commands; a mode the Worker shell
 * cannot enforce (read-only) still fails closed. A host accelerator is
 * read-only by construction, so it needs no confine wrapping and is never
 * rejected because the caller asked for `workspace-write` (D20).
 *
 * On the desktop transport (`node:http`) every command still executes in the
 * provider, so the original rule applies unchanged: delegate only a mode the
 * provider advertises, otherwise fail closed (silent unconfined passthrough is
 * forbidden).
 * @module @phone-dsh/dsh-subprocess-xl/sandbox
 */

import { SandboxProvider, SandboxUnavailableError } from '@deepseek-ai/dsh-sandbox'
import type { ConfinedArgv, SandboxPolicy } from '@deepseek-ai/dsh-sandbox'
import type {} from '@phone-dsh/dsh-exec-bridge'
import { CONFINE_MARKER } from './marker.ts'
import { resolveProgramIdentity } from './program.ts'

/** Denial text guest kernels print for blocked file effects. */
const DENIAL_SIGNATURES = ['Permission denied', 'Read-only file system', 'Operation not permitted']

export class XlGuestSandboxProvider extends SandboxProvider {
  static inject = ['xlExecBridge']

  override confine(argv: readonly string[], policy: SandboxPolicy, signal?: AbortSignal): Promise<ConfinedArgv> {
    signal?.throwIfAborted()
    const bridge = this.ctx.xlExecBridge
    const program = argv[0] ?? ''
    // The same identity normalization the subprocess dispatch uses: a caller
    // may name the program by an absolute executable path (for example the
    // packaged ripgrep's `resolveRgPath()`), and an advertised accelerator is
    // matched by its bare name.
    const identity = resolveProgramIdentity(program, bridge.hello.capabilities.accelerators ?? [])
    const accelerator = (bridge.hello.capabilities.accelerators ?? []).includes(identity)
    if (bridge.transport.kind !== 'node-http') {
      if (accelerator) {
        // Host accelerators are read-only by construction; no confine wrapper
        // is added, so no host could reject the request over a mode mismatch.
        return Promise.resolve({
          argv: [...argv],
          enforcement: 'full',
          denialSignatures: DENIAL_SIGNATURES,
          runnerFailureRules: [],
        })
      }
      if (policy.mode === 'read-only') {
        return Promise.reject(new SandboxUnavailableError(
          policy.mode,
          'the Worker shell cannot enforce a read-only workspace; only the host accelerator path is read-only',
        ))
      }
      // The Worker VFS is the writable boundary for a Worker-local command.
      return Promise.resolve(wrapped(argv, policy, policy.mode))
    }
    const modes = bridge.hello.capabilities.confine ?? []
    if (!modes.includes(policy.mode)) {
      return Promise.reject(new SandboxUnavailableError(
        policy.mode,
        `the exec provider ${bridge.hello.provider.name} enforces no per-execution confinement (capabilities.confine = ${JSON.stringify(modes)})`,
      ))
    }
    return Promise.resolve(wrapped(argv, policy, policy.mode))
  }
}

function wrapped(argv: readonly string[], policy: SandboxPolicy, mode: 'read-only' | 'workspace-write'): ConfinedArgv {
  return {
    argv: [CONFINE_MARKER, mode, policy.workspaceRoot, '--', ...argv],
    enforcement: 'full',
    denialSignatures: DENIAL_SIGNATURES,
    runnerFailureRules: [],
  }
}

export default XlGuestSandboxProvider
