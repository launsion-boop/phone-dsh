// SPDX-License-Identifier: MIT
/**
 * The Worker capability manifest path and the shell's fallback payload.
 *
 * `contract.ts` renders every `not-available` hint with
 * {@link SHELL_MANIFEST_PATH}. Before G2-FIX-58 that path was a dangling
 * referent: the hint told the model to read `/dsh/home/capabilities.json`, no
 * boot path ever created it, so the model spent a tool call on `not found`
 * (G2-A09: the 127 hint at transcript line 10, the `read` at 29-30).
 *
 * The file has one owner: the Worker boot entry
 * (`worker-entry/src/capabilities.ts`, G2-ENG-05) publishes the full
 * `pdsh-capabilities/1` document from the real command registry
 * (`workerCommandSurface`: just-bash's instantiated table plus
 * `createWorkerCommands()` plus the installed toolbox plus the HELLO
 * accelerators) before the first request. That document answers more than the
 * program list (limits, Python modules, egress, recorded bash deviations), so
 * this module must never rewrite it: any manifest file already at the path is
 * the referent, and replacing it with the minimal `{format, programs}` payload
 * would delete the environment priors the boot just promised the model
 * (G2-FIX-58 repair round).
 *
 * The shell keeps a fallback writer for embeddings without a boot entry (the
 * desktop tests, a bare `WorkerShell` over a local VFS): it writes the
 * minimal document only when the path does not exist yet. `not-available` is
 * the only reason that names the manifest, and
 * {@link materializeCapabilityManifest} returns undefined when the backend
 * refuses that write: the caller then omits the path from the hint instead of
 * advertising a referent that does not exist (see `unavailableHint`).
 * @module @phone-dsh/dsh-shell-ext/capabilities
 */

import type { IFileSystem } from 'just-bash/browser'
import { SHELL_MANIFEST_PATH } from './contract.ts'

/** Format version of the shell's minimal fallback payload (one JSON object). */
export const CAPABILITY_MANIFEST_FORMAT = 1

/** The shell's minimal fallback payload, written only when no boot manifest exists. */
export interface WorkerCapabilityManifest {
  /** Payload format; 1 for the shape described here. */
  readonly format: number
  /** Every program the Worker shell dispatches, sorted, without duplicates. */
  readonly programs: readonly string[]
}

/**
 * Build the minimal fallback manifest from a command registry.
 * @param names - the shell's command names (as materialised on `PATH`).
 * @returns the sorted, de-duplicated manifest payload.
 */
export function capabilityManifest(names: readonly string[]): WorkerCapabilityManifest {
  const programs = [...new Set(names)]
    .filter(name => /^[A-Za-z0-9_+.-]+$/u.test(name))
    .sort()
  return { format: CAPABILITY_MANIFEST_FORMAT, programs }
}

/**
 * Render the fallback payload as the exact bytes the VFS holds.
 * @param names - the shell's command names.
 * @returns UTF-8 JSON with a trailing newline.
 */
export function capabilityManifestJson(names: readonly string[]): string {
  return `${JSON.stringify(capabilityManifest(names), undefined, 2)}\n`
}

/**
 * Ensure the manifest path exists in the Worker VFS.
 *
 * The boot entry publishes the authoritative `pdsh-capabilities/1` document
 * before the first command (see the module doc). Any regular file already at
 * {@link SHELL_MANIFEST_PATH} — whatever schema its publisher used — is the
 * hint's referent, so this function never writes over it. It writes the
 * minimal {@link WorkerCapabilityManifest} only when the path is absent, for
 * an embedding without a boot entry; the write is best-effort at the
 * filesystem boundary and never invents a root: the boot's
 * `seedNamespaceRoots` creates `/dsh/home`, and a filesystem without it (a
 * read-only desktop tree, a synthetic test double) returns undefined so the
 * caller advertises no path at all.
 * @param fs - the shell filesystem.
 * @param names - every command name the shell serves.
 * @returns {@link SHELL_MANIFEST_PATH} when the file is present (pre-existing
 *   or just written), undefined when the backend refused the write.
 */
export async function materializeCapabilityManifest(
  fs: IFileSystem,
  names: readonly string[],
): Promise<string | undefined> {
  try {
    const existing = await fs.stat(SHELL_MANIFEST_PATH)
    if (existing.isFile) return SHELL_MANIFEST_PATH
  } catch {
    // Missing (the first command) or unreadable: the write below decides.
  }
  try {
    await fs.writeFile(SHELL_MANIFEST_PATH, capabilityManifestJson(names))
    return SHELL_MANIFEST_PATH
  } catch {
    return undefined
  }
}
