// SPDX-License-Identifier: MIT
/** Node-style ancestor lookup for package metadata, independent of JS loading. */
import { posix } from 'node:path'

export function metadataSearchPaths(directory: string): string[] {
  if (!posix.isAbsolute(directory)) throw new TypeError('Package metadata lookup needs an absolute VFS directory')
  const result: string[] = []
  let current = posix.normalize(directory)
  for (;;) {
    if (posix.basename(current) !== 'node_modules') result.push(posix.join(current, 'node_modules'))
    const parent = posix.dirname(current)
    if (parent === current) return result
    current = parent
  }
}
