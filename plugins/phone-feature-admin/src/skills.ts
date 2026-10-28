// SPDX-License-Identifier: MIT
/**
 * Flat Markdown skills under the phone home root.
 *
 * Every read and write is rooted at `realpath(/dsh/home/skills)` and accepts
 * only one kebab-case `.md` basename. Symlinks, `..`, NUL, absolute targets
 * and nested paths are refused before any filesystem call can escape the root.
 * Writes are staged in the same directory and renamed into place, then the DSH
 * skills catalog is invalidated so the next slash list re-discovers the file.
 * @module @phone-dsh/dsh-feature-admin/skills
 */

import { randomUUID } from 'node:crypto'
import { lstat, mkdir, open, readFile, readdir, realpath, rename, unlink } from 'node:fs/promises'
import { isAbsolute, join, relative, resolve, sep } from 'node:path'
import type { Context } from '@deepseek-ai/cordis'
import type {} from '@deepseek-ai/dsh-skill'
import {
  type SkillDocumentView,
  type SkillFileView,
  type SkillMutationView,
} from './contracts.ts'
import { FeatureAdminError, invalidRequest, notFound, unsupported } from './errors.ts'

/** Flat skill file accepted by the DSH filesystem provider. */
const SKILL_FILE = /^[a-z0-9]+(?:-[a-z0-9]+)*\.md$/u
/** Defensive cap: a skill is instruction text, not workspace data. */
const MAX_SKILL_BYTES = 2 * 1024 * 1024

/** How one mutation reached the DSH skills catalog. */
export type SkillInvalidation = SkillMutationView['invalidation']

/** Validate one wire name and return the accepted flat file name. */
export function skillFileName(name: unknown): string {
  if (typeof name !== 'string' || name === '') throw invalidRequest('skill name must be a non-empty string')
  if (name.includes('\0')) throw invalidRequest('skill name must not contain NUL')
  if (name.includes('\\')) throw invalidRequest('skill name must not contain a backslash')
  if (name.includes('/')) throw invalidRequest('skill name must be a flat file, not a path')
  if (isAbsolute(name) || name.startsWith('~')) throw invalidRequest('skill name must be relative to the skills root')
  if (name.split('/').some(segment => segment === '..' || segment === '.')) {
    throw invalidRequest('skill name must not contain . or .. segments')
  }
  if (!SKILL_FILE.test(name)) {
    throw invalidRequest('skill name must be kebab-case and end in .md')
  }
  return name
}

/** Strip the flat-file suffix for the catalog name. */
export function skillNameOf(fileName: string): string {
  return fileName.slice(0, -'.md'.length)
}

/** Ensure a resolved path is strictly below the canonical root. */
function assertInside(root: string, target: string): void {
  const rel = relative(root, target)
  if (rel === '' || rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    throw invalidRequest('resolved skill path escapes the skills root')
  }
  if (!resolve(root, rel).startsWith(`${root}${sep}`)) {
    throw invalidRequest('resolved skill path escapes the skills root')
  }
}

/** Refuse a symlinked root: the root itself is the authority, never a link. */
async function canonicalRoot(root: string, create: boolean): Promise<string | undefined> {
  if (create) await mkdir(root, { recursive: true, mode: 0o700 })
  let info
  try {
    info = await lstat(root)
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return undefined
    throw error
  }
  if (info.isSymbolicLink()) throw new FeatureAdminError('conflict', `skills root must not be a symbolic link: ${root}`)
  if (!info.isDirectory()) throw new FeatureAdminError('conflict', `skills root is not a directory: ${root}`)
  // Ancestor links (macOS /tmp, the app container) are normal; the root
  // itself was checked above, and every child is checked below.
  return await realpath(root)
}

/** One in-root target after symlink and boundary checks. */
async function inspectTarget(root: string, name: string): Promise<{ candidate: string; exists: boolean }> {
  const candidate = join(root, name)
  assertInside(root, candidate)
  try {
    const info = await lstat(candidate)
    if (info.isSymbolicLink()) {
      throw new FeatureAdminError('conflict', `skill path is a symbolic link and is refused: ${name}`)
    }
    if (!info.isFile()) throw new FeatureAdminError('conflict', `skill path is not a regular file: ${name}`)
    // The lstat check refuses links; realpath then confirms no ancestor link
    // moved an existing target outside the canonical root.
    const actual = await realpath(candidate)
    assertInside(root, actual)
    return { candidate, exists: true }
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return { candidate, exists: false }
    throw error
  }
}

/**
 * Confirm the live skills registry can really drop its catalog cache.
 *
 * DSH 0.2.1 exposes no public registry invalidation; the registry's own
 * `invalidateCache()` is the only call that clears the completed-catalog
 * cache. An event alone does not clear that cache, so a write that could only
 * emit `skills/change` would report success while the slash list stayed stale.
 * Refuse before touching disk instead.
 * @param ctx - Host context.
 */
interface SkillCatalogInvalidationCapability {
  /**
   * DSH 0.2.1's `SkillRegistry` keeps this as a private implementation
   * method; it is the only operation that purges completed catalogs. The
   * public registry face has no direct invalidation, so the Host probes the
   * live service instead of intersecting its public type with a private
   * member (which TypeScript reduces to `never`).
   */
  readonly invalidateCache?: () => void
}

/** Read the live registry's capability seam without narrowing its public type. */
function skillCatalogInvalidation(ctx: Context): SkillCatalogInvalidationCapability | undefined {
  return ctx.get('skills') as unknown as SkillCatalogInvalidationCapability | undefined
}

export function assertSkillCatalogInvalidation(ctx: Context): void {
  const skills = skillCatalogInvalidation(ctx)
  if (skills === undefined) {
    throw unsupported('ctx.skills is not mounted, so a skill write cannot make the next slash list re-discover it.')
  }
  if (typeof skills.invalidateCache !== 'function') {
    throw unsupported(
      'ctx.skills is mounted but does not expose the catalog invalidation this Host needs; '
      + 'the slash list would keep serving its cached catalog, so the skill was not changed.',
    )
  }
}

/** Tell the live DSH skills registry the catalog changed. */
export function invalidateSkillCatalog(ctx: Context): SkillInvalidation {
  assertSkillCatalogInvalidation(ctx)
  const skills = skillCatalogInvalidation(ctx) as Required<SkillCatalogInvalidationCapability>
  skills.invalidateCache()
  return 'catalog'
}

/** Filesystem operations bound to one canonical skills root. */
export class SkillsStore {
  readonly root: string
  private readonly invalidate: () => SkillInvalidation

  constructor(root: string, invalidate: () => SkillInvalidation) {
    this.root = root
    this.invalidate = invalidate
  }

  /** List flat regular `.md` files; absent root means an empty catalog. */
  async list(): Promise<readonly SkillFileView[]> {
    const root = await canonicalRoot(this.root, false)
    if (root === undefined) return []
    const entries = await readdir(root, { withFileTypes: true })
    const files: SkillFileView[] = []
    for (const entry of entries) {
      if (!entry.isFile() || !SKILL_FILE.test(entry.name)) continue
      const path = join(root, entry.name)
      try {
        const info = await lstat(path)
        if (!info.isFile() || info.isSymbolicLink()) continue
        const actual = await realpath(path)
        assertInside(root, actual)
        files.push({
          name: entry.name,
          skillName: skillNameOf(entry.name),
          bytes: info.size,
          modifiedAt: info.mtime.toISOString(),
        })
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ENOENT') continue
        throw error
      }
    }
    return files.sort((left, right) => left.name.localeCompare(right.name))
  }

  /** Read one flat skill body. */
  async read(name: unknown): Promise<SkillDocumentView> {
    const fileName = skillFileName(name)
    const root = await canonicalRoot(this.root, false)
    if (root === undefined) throw notFound(`skill does not exist: ${fileName}`)
    const target = await inspectTarget(root, fileName)
    if (!target.exists) throw notFound(`skill does not exist: ${fileName}`)
    return { name: fileName, content: await readFile(target.candidate, 'utf8') }
  }

  /** Atomically create or replace one flat skill and invalidate the catalog. */
  async write(name: unknown, content: unknown): Promise<SkillMutationView> {
    const fileName = skillFileName(name)
    if (typeof content !== 'string') throw invalidRequest('skill content must be a string')
    if (Buffer.byteLength(content, 'utf8') > MAX_SKILL_BYTES) {
      throw invalidRequest(`skill content exceeds ${String(MAX_SKILL_BYTES)} bytes`)
    }
    const root = await canonicalRoot(this.root, true)
    if (root === undefined) throw new FeatureAdminError('io-error', `skills root could not be created: ${this.root}`)
    const target = await inspectTarget(root, fileName)
    const temporary = join(root, `.${fileName}.${randomUUID()}.tmp`)
    assertInside(root, temporary)
    try {
      const handle = await open(temporary, 'wx', 0o600)
      try {
        await handle.writeFile(content, 'utf8')
        await handle.sync()
      } finally {
        await handle.close()
      }
      await rename(temporary, target.candidate)
    } catch (error) {
      await unlink(temporary).catch(() => {})
      throw error
    }
    return { name: fileName, invalidation: this.invalidate() }
  }

  /** Remove one flat skill and invalidate the catalog. */
  async delete(name: unknown): Promise<SkillMutationView> {
    const fileName = skillFileName(name)
    const root = await canonicalRoot(this.root, false)
    if (root === undefined) throw notFound(`skill does not exist: ${fileName}`)
    const target = await inspectTarget(root, fileName)
    if (!target.exists) throw notFound(`skill does not exist: ${fileName}`)
    await unlink(target.candidate)
    return { name: fileName, deleted: true, invalidation: this.invalidate() }
  }
}
