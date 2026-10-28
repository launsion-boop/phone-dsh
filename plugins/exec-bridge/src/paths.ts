// SPDX-License-Identifier: MIT
/**
 * Host ↔ guest path mapping over the bridge's mount table (hello.guest.mounts).
 * The longest matching prefix wins; matches respect path-segment boundaries.
 *
 * The ordered channel HELLO publishes caps only, so it has no host mount table.
 * A guest-only mapper is the honest representation of that fact: guest paths
 * pass through unchanged (the trusted Native cwd protocol uses `/dsh/...`
 * directly) while `toHost` never claims an arbitrary host path is mounted.
 * @module @phone-dsh/dsh-exec-bridge/paths
 */

import { posix } from 'node:path'
import type { Mount } from './client.ts'

/** Constructor options for the two mapper shapes. */
export interface PathMapperOptions {
  /**
   * No host mount facts are published. Guest paths pass through and host
   * paths are never mapped. The mount table must be empty.
   */
  readonly guestOnly?: boolean
  /** Default guest working directory in guest-only mode; defaults to `/dsh/workspace`. */
  readonly defaultGuestRoot?: string
}

function normalize(path: string): string {
  const normalized = posix.normalize(path)
  return normalized.length > 1 && normalized.endsWith('/') ? normalized.slice(0, -1) : normalized
}

function under(path: string, root: string): string | undefined {
  if (path === root) return ''
  const prefix = root === '/' ? '/' : `${root}/`
  return path.startsWith(prefix) ? path.slice(prefix.length) : undefined
}

export class PathMapper {
  private readonly mounts: Array<{ host: string; guest: string; readOnly: boolean }>
  private readonly guestOnly: boolean
  private readonly guestDefault: string

  /**
   * A mapper over the real host mounts, or a guest-only mapper when the HELLO
   * published no host mount facts.
   */
  constructor(mounts: readonly Mount[], options: PathMapperOptions = {}) {
    this.guestOnly = options.guestOnly === true
    if (this.guestOnly) {
      if (mounts.length !== 0) {
        throw new Error('a guest-only mapper cannot carry host mounts')
      }
      const root = options.defaultGuestRoot ?? '/dsh/workspace'
      if (!posix.isAbsolute(root)) throw new Error(`guest-only default root must be absolute: ${JSON.stringify(root)}`)
      this.mounts = []
      this.guestDefault = normalize(root)
      return
    }
    if (mounts.length === 0) throw new Error('exec bridge published no guest mounts')
    this.mounts = mounts.map(mount => {
      if (!posix.isAbsolute(mount.host_path) || !posix.isAbsolute(mount.guest_path)) {
        throw new Error(`exec bridge mount paths must be absolute: ${JSON.stringify(mount)}`)
      }
      return { host: normalize(mount.host_path), guest: normalize(mount.guest_path), readOnly: mount.read_only === true }
    })
    this.guestDefault = (this.mounts[0] as { guest: string }).guest
  }

  /** Build the mapper for a HELLO that published no host mount facts. */
  static guestOnly(defaultGuestRoot = '/dsh/workspace'): PathMapper {
    return new PathMapper([], { guestOnly: true, defaultGuestRoot })
  }

  /** True when the mapper has no host facts (the ordered channel HELLO). */
  get isGuestOnly(): boolean {
    return this.guestOnly
  }

  /** True when every mount maps a path to itself (the recommended deployment). */
  get identity(): boolean {
    return !this.guestOnly && this.mounts.every(mount => mount.host === mount.guest)
  }

  /**
   * Map a host path to its guest path.
   *
   * In guest-only mode the input is already a guest path (there is no host
   * path space to translate), so an absolute guest path passes through.
   * @param hostPath - absolute host path, or an absolute guest path in guest-only mode.
   * @returns the guest path, or undefined when no mount covers it.
   */
  toGuest(hostPath: string): string | undefined {
    if (this.guestOnly) return posix.isAbsolute(hostPath) ? normalize(hostPath) : undefined
    return this.map(hostPath, 'host', 'guest')
  }

  /**
   * Map a guest path to its host path.
   *
   * In guest-only mode no host mount facts exist, so this never maps a path:
   * an arbitrary host path such as `/etc` must not look like a published mount.
   * @param guestPath - absolute guest path.
   * @returns the host path, or undefined when no mount covers it.
   */
  toHost(guestPath: string): string | undefined {
    if (this.guestOnly) return undefined
    return this.map(guestPath, 'guest', 'host')
  }

  /** The guest path of the first mount, or the trusted Native default in guest-only mode. */
  get defaultGuestRoot(): string {
    return this.guestDefault
  }

  private map(path: string, from: 'host' | 'guest', to: 'host' | 'guest'): string | undefined {
    if (!posix.isAbsolute(path)) return undefined
    const normalized = normalize(path)
    let best: { rest: string; target: string; length: number } | undefined
    for (const mount of this.mounts) {
      const rest = under(normalized, mount[from])
      if (rest === undefined) continue
      if (best === undefined || mount[from].length > best.length) best = { rest, target: mount[to], length: mount[from].length }
    }
    if (best === undefined) return undefined
    return best.rest === '' ? best.target : posix.join(best.target, best.rest)
  }
}
