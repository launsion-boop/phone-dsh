// SPDX-License-Identifier: MIT
/**
 * `git tag`: list, create and delete tag refs.
 *
 * Tags are ordinary refs under `refs/tags/`, so a lightweight tag is one file
 * write and no object. An annotated tag is a real `tag` object whose header
 * (`object`/`type`/`tag`/`tagger`) and message follow git's own serialisation;
 * the tagger comes from `GIT_COMMITTER_*` or `user.*`, and
 * `GIT_COMMITTER_DATE` fixes its timestamp. The Worker has no editor, so an
 * annotated tag without `-m` fails loudly instead of writing an empty message.
 * Tag creation never writes a reflog, matching git's default for `refs/tags/`.
 * @module @phone-dsh/dsh-wasi-toolbox/git/tag
 */
import { fatal, usage } from './errors.ts'
import { compareStrings, encodeText } from './fs.ts'
import { parseGitDate } from './porcelain.ts'
import { wildmatchBytes } from './wildmatch.ts'
import {
  deleteRef, listRefs, readCommit, resolveRef, resolveRevision, shortOid, writeRef,
} from './repo.ts'
import type { Repository } from './repo.ts'
import type { CommandContext } from './cli.ts'

/**
 * Match one listing glob with git's `*`, `?` and `[...]` metacharacters.
 *
 * The comparison is on UTF-8 bytes, as git's wildmatch is: `?` consumes one
 * byte, so it does not match a whole CJK code point. This is the same
 * matcher `branch --list` uses.
 */
function matchesTagPattern(pattern: string, name: string): boolean {
  return wildmatchBytes(encodeText(pattern), encodeText(name))
}

/** Git's `strbuf_stripspace` for the default `strip` cleanup mode. */
function cleanupTagMessage(text: string): string {
  const kept: string[] = []
  for (const raw of text.split('\n')) {
    // Comment lines are removed in CLEANUP_ALL mode, which `-m` uses by
    // default; trailing whitespace is stripped from every other line.
    if (raw.startsWith('#')) continue
    const line = raw.replace(/[ \t\r]+$/, '')
    if (line === '') {
      if (kept.length === 0 || kept[kept.length - 1] === '') continue
      kept.push('')
    } else {
      kept.push(line)
    }
  }
  while (kept.length > 0 && kept[kept.length - 1] === '') kept.pop()
  return kept.length === 0 ? '' : `${kept.join('\n')}\n`
}

/** The message `git tag -n` renders: an annotated tag's body or a commit's message. */
async function tagMessage(repository: Repository, oid: string): Promise<string> {
  const object = await repository.odb.read(oid)
  if (object.type === 'tag') {
    const text = new TextDecoder().decode(object.data)
    const separator = text.indexOf('\n\n')
    return separator < 0 ? '' : text.slice(separator + 2)
  }
  if (object.type === 'commit') return (await readCommit(repository, oid)).message
  return ''
}

/** Render `%(contents:lines=N)`: the subject, then four-space-indented lines. */
function renderMessageLines(message: string, lines: number): string {
  if (lines <= 0) return ''
  const split = message.replace(/\n+$/, '').split('\n')
  if (split.length === 1 && split[0] === '') return ''
  return split.slice(0, lines).map((line, index) => index === 0 ? line : `    ${line}`).join('\n')
}

/** `git check-ref-format --allow-onelevel refs/tags/<name>`. */
function isValidTagName(name: string): boolean {
  return !(name === '' || name.startsWith('/') || name.endsWith('/')
    || name.endsWith('.') || name.includes('//') || name.includes('..') || name.includes('@{')
    || /[\x00-\x20\x7f~^:?*\[\\]/.test(name)
    || name.split('/').some(part => part === '' || part.startsWith('.') || part.endsWith('.') || part.endsWith('.lock')))
}

/** Fail the way `git tag <name>` does for a name git cannot make a ref from. */
function checkTagName(name: string): void {
  // `git tag -- -foo` rejects an option-shaped name before ref validation,
  // even though `git check-ref-format refs/tags/-foo` accepts the ref itself.
  if (name.startsWith('-') || !isValidTagName(name)) throw fatal(`'${name}' is not a valid tag name.`)
}

/** git's "switch/option is incompatible" usage failure (exit 129). */
function incompatible(kind: 'option' | 'switch', option: string, other: string): Error {
  return usage(`error: ${kind} \`${option}' is incompatible with --${other}`)
}

/** The `tagger` ident line, from `GIT_COMMITTER_*` or `user.*`. */
function taggerIdentity(context: CommandContext, repository: Repository): string {
  const name = context.env.GIT_COMMITTER_NAME ?? repository.config.get('user.name')
  const email = context.env.GIT_COMMITTER_EMAIL ?? repository.config.get('user.email')
  if (name === undefined || name === '' || email === undefined || email === '') {
    throw fatal('unable to auto-detect committer identity; set user.name and user.email or GIT_COMMITTER_NAME/GIT_COMMITTER_EMAIL')
  }
  const date = parseGitDate(context.env.GIT_COMMITTER_DATE, Math.floor(Date.now() / 1000))
  return `${name} <${email}> ${date.timestamp} ${date.timezone}`
}

/** `git tag`. */
export async function tag(context: CommandContext): Promise<number> {
  let listMode = false
  let deleteMode = false
  let annotate = false
  let force = false
  let messageGiven = false
  let lines: number | undefined
  const messages: string[] = []
  const positional: string[] = []
  const args = context.args
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index] as string
    if (arg === '--') {
      positional.push(...args.slice(index + 1))
      break
    }
    if (arg === '--list') {
      if (deleteMode) throw incompatible('option', 'list', 'delete')
      listMode = true
      continue
    }
    if (arg === '--delete') {
      if (listMode) throw incompatible('option', 'delete', 'list')
      deleteMode = true
      continue
    }
    if (arg === '--annotate') { annotate = true; continue }
    if (arg === '--force') { force = true; continue }
    if (arg === '--message') {
      const value = args[index + 1]
      if (value === undefined) throw usage("error: switch `m' requires a value")
      messages.push(value)
      messageGiven = true
      index += 1
      continue
    }
    if (arg.startsWith('--message=')) {
      messages.push(arg.slice('--message='.length))
      messageGiven = true
      continue
    }
    if (arg.startsWith('--')) throw fatal(`unsupported tag option '${arg}'. Nothing was run.`, 129)
    if (arg.startsWith('-') && arg.length > 1) {
      // Short options can be clustered, and an option that takes a value
      // consumes the rest of the cluster (`-am msg`, `-ammsg`, `-n2`).
      const cluster = arg.slice(1)
      for (let position = 0; position < cluster.length; position += 1) {
        const option = cluster[position] as string
        if (option === 'l') {
          if (deleteMode) throw incompatible('switch', 'l', 'delete')
          listMode = true
          continue
        }
        if (option === 'd') {
          if (listMode) throw incompatible('switch', 'd', 'list')
          deleteMode = true
          continue
        }
        if (option === 'a') { annotate = true; continue }
        if (option === 'f') { force = true; continue }
        if (option === 'n') {
          const value = cluster.slice(position + 1)
          if (value === '') {
            lines = 1
          } else {
            if (!/^\d+$/.test(value)) throw usage("error: switch `n' expects a numerical value")
            lines = Number(value)
          }
          position = cluster.length
          continue
        }
        if (option === 'm') {
          const attached = cluster.slice(position + 1)
          const value = attached === '' ? args[index + 1] : attached
          if (value === undefined) throw usage("error: switch `m' requires a value")
          messages.push(value)
          messageGiven = true
          if (attached === '') index += 1
          position = cluster.length
          continue
        }
        throw fatal(`unsupported tag option '-${option}'. Nothing was run.`, 129)
      }
      continue
    }
    positional.push(arg)
  }

  const createOptions = annotate || messageGiven || force
  if ((listMode || deleteMode) && createOptions) {
    throw usage('usage: git tag [-a] [-f] [-m <message>] <tagname> [<commit>]')
  }
  if (deleteMode && lines !== undefined) throw fatal("the '-n' option is only allowed in list mode")
  if (!listMode && !deleteMode && lines !== undefined) listMode = true
  if (!listMode && !deleteMode) {
    if (positional.length === 0 && !createOptions) listMode = true
    if (positional.length === 0 && createOptions) {
      throw usage('usage: git tag [-a] [-f] [-m <message>] <tagname> [<commit>]')
    }
  }

  const repository = await context.repository()
  if (deleteMode) {
    if (positional.length === 0) throw usage('usage: git tag -d <tagname>...')
    const found: { name: string; oid: string }[] = []
    let failed = false
    for (const name of positional) {
      // A name that cannot be a ref is just "not found" to `tag -d`; never let
      // a `..` or absolute-path spelling reach the filesystem as a ref path.
      if (!isValidTagName(name)) {
        context.output.stderr(`error: tag '${name}' not found.\n`)
        failed = true
        continue
      }
      const oid = await resolveRef(repository, `refs/tags/${name}`)
      if (oid === undefined) {
        context.output.stderr(`error: tag '${name}' not found.\n`)
        failed = true
        continue
      }
      found.push({ name, oid })
    }
    for (const entry of found) {
      await deleteRef(repository, `refs/tags/${entry.name}`)
      context.output.stdout(`Deleted tag '${entry.name}' (was ${shortOid(entry.oid)})\n`)
    }
    return failed ? 1 : 0
  }

  if (listMode) {
    const refs = await listRefs(repository, 'refs/tags/')
    const names = [...refs.keys()]
      .map(ref => ref.slice('refs/tags/'.length))
      .sort(compareStrings)
    for (const name of names) {
      if (positional.length > 0 && !positional.some(pattern => matchesTagPattern(pattern, name))) continue
      if (lines === undefined || lines === 0) {
        context.output.stdout(`${name}\n`)
        continue
      }
      const oid = refs.get(`refs/tags/${name}`) as string
      const rendered = renderMessageLines(await tagMessage(repository, oid), lines)
      context.output.stdout(`${name.padEnd(15)} ${rendered}\n`)
    }
    return 0
  }

  if (positional.length > 2) throw fatal('too many arguments')
  const name = positional[0] as string
  const revision = positional[1] ?? 'HEAD'
  let target: string
  try {
    target = await resolveRevision(repository, revision)
  } catch {
    throw fatal(`Failed to resolve '${revision}' as a valid ref.`)
  }
  checkTagName(name)
  const ref = `refs/tags/${name}`
  const previous = await resolveRef(repository, ref)
  if (previous !== undefined && !force) throw fatal(`tag '${name}' already exists`)
  const annotated = annotate || messageGiven
  let oid = target
  if (annotated) {
    if (!messageGiven) {
      throw fatal('no tag message? The Worker git has no editor; supply -m <message>.', 129)
    }
    const type = await repository.odb.type(target)
    const header = `object ${target}\ntype ${type}\ntag ${name}\ntagger ${taggerIdentity(context, repository)}\n\n`
    oid = await repository.odb.write('tag', encodeText(`${header}${cleanupTagMessage(messages.join('\n\n'))}`))
  }
  await writeRef(repository, ref, oid)
  if (force && previous !== undefined && previous !== oid) {
    context.output.stdout(`Updated tag '${name}' (was ${shortOid(previous)})\n`)
  }
  return 0
}
