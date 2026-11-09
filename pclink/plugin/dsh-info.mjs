/** Discover the running DSH version (and commit when this is a source checkout). */
import { createRequire } from 'node:module'
import { existsSync, readFileSync, statSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { execFileSync } from 'node:child_process'

/**
 * Read DSH version/commit from the running CLI installation.
 * @param {(...args: unknown[]) => void} [log] Logger.
 * @returns {{version: string, commit?: string, source: string}} runtime facts.
 */
export function dshRuntimeInfo(log = () => {}) {
  const info = { version: '0.0.0', source: 'fallback' }
  try {
    const entry = typeof process.argv[1] === 'string' ? process.argv[1] : import.meta.url
    const requireFromCli = createRequire(entry)
    const manifestPath = requireFromCli.resolve('@deepseek-ai/dsh-app-boot/package.json')
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
    if (typeof manifest.version === 'string' && manifest.version !== '') {
      info.version = manifest.version
      info.source = 'dsh-app-boot/package.json'
    }
    const commit = readGitHead(dirname(manifestPath))
    if (commit !== undefined) info.commit = commit
  } catch (error) {
    log(`DSH runtime info unavailable: ${error.message}`)
  }
  if (process.env.DSH_CLIENT_VERSION !== undefined) {
    info.version = process.env.DSH_CLIENT_VERSION
    info.source = 'DSH_CLIENT_VERSION'
  }
  if (process.env.DSH_CLIENT_COMMIT_HASH !== undefined) info.commit = process.env.DSH_CLIENT_COMMIT_HASH
  if (info.commit !== undefined && !/^[0-9a-f]{7,64}$/.test(info.commit)) delete info.commit
  return info
}

function readGitHead(start) {
  let current = start
  for (let depth = 0; depth < 12; depth += 1) {
    const gitPath = join(current, '.git')
    if (existsSync(gitPath)) {
      try {
        let gitDir = gitPath
        if (!statSync(gitPath).isDirectory()) {
          const pointer = readFileSync(gitPath, 'utf8')
          gitDir = pointer.replace(/^gitdir:\s*/, '').trim()
          if (!gitDir.startsWith('/')) gitDir = join(current, gitDir)
        }
        let head = readFileSync(join(gitDir, 'HEAD'), 'utf8').trim()
        if (head.startsWith('ref: ')) {
          const ref = head.slice(5).trim()
          const loose = join(gitDir, ref)
          if (existsSync(loose)) return readFileSync(loose, 'utf8').trim()
          const packed = join(gitDir, 'packed-refs')
          if (existsSync(packed)) {
            for (const line of readFileSync(packed, 'utf8').split('\n')) {
              const [sha, packedRef] = line.trim().split(' ')
              if (packedRef === ref) return sha
            }
          }
          try {
            return execFileSync('git', ['-C', current, 'rev-parse', 'HEAD'], {
              encoding: 'utf8', timeout: 2000, stdio: ['ignore', 'pipe', 'ignore'],
            }).trim()
          } catch {
            return undefined
          }
        }
        return head
      } catch {
        return undefined
      }
    }
    const parent = dirname(current)
    if (parent === current) break
    current = parent
  }
  return undefined
}
