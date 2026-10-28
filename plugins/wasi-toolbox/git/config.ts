// SPDX-License-Identifier: MIT
/**
 * `git config` over the repository's own `.git/config`.
 *
 * The Worker git reads the effective configuration (home `.gitconfig`, the
 * repository file and `git -c` overrides) for every command already. This
 * command adds the write side the agent needs before its first commit: a
 * `git config user.name …` / `git config user.email …` pair is an ordinary VFS
 * mutation of `.git/config`, so it stays in the Worker and reaches the WAL sink
 * at the next mseq (PLAN D12).
 *
 * Supported forms:
 *
 *   git config <name>                 read one value (exit 1 when unset)
 *   git config --get <name>           read one value
 *   git config --local <name>         read the repository file only
 *   git config [--local] <name> <value>   write one value
 *
 * Scopes the Worker cannot honour (`--global`, `--system`, `--file`) and
 * mutating actions other than a plain set (`--unset`, `--add`, …) fail loud
 * with the unsupported word in the message; they never pretend to have run.
 * @module @phone-dsh/dsh-wasi-toolbox/git/config
 */
import { GitFailure, fatal } from './errors.ts'
import { decodeText, isErrno } from './fs.ts'
import type { GitFs } from './fs.ts'
import { gitPath, parseConfig } from './repo.ts'
import type { GitConfig, Repository } from './repo.ts'
import type { CommandContext } from './cli.ts'

const CONFIG_USAGE = `usage: git config [--local] [--get] <name> [<value>]

    --local   read or write the repository's .git/config only
    --get     read one value (exit 1 when it is not set)

Scopes other than --local and mutating actions other than a plain set are not
implemented by the Worker git and fail loudly.
`

/** One parsed `section[.subsection].variable` configuration name. */
export interface ConfigName {
  readonly section: string
  readonly subsection?: string
  readonly variable: string
}

/**
 * Split a dotted configuration name into git's section, optional subsection
 * and variable parts. Invalid names fail with git's `error:` wording.
 */
export function splitConfigName(name: string): ConfigName {
  const parts = name.split('.')
  if (parts.length < 2) throw new GitFailure(2, `error: key does not contain a section: ${name}\n`)
  if (parts.some(part => part === '')) throw new GitFailure(2, `error: invalid key: ${name}\n`)
  const section = parts[0] as string
  const variable = parts[parts.length - 1] as string
  if (!/^[A-Za-z0-9-]+$/.test(section)) throw new GitFailure(2, `error: invalid key: ${name}\n`)
  if (!/^[A-Za-z0-9-]+$/.test(variable)) throw new GitFailure(2, `error: invalid key: ${name}\n`)
  const subsection = parts.length > 2 ? parts.slice(1, -1).join('.') : undefined
  return { section, ...subsection === undefined ? {} : { subsection }, variable }
}

interface ConfigSection {
  readonly section: string
  readonly subsection?: string
}

/** Parse one `[section "subsection"]` line. */
function parseSectionHeader(line: string): ConfigSection | undefined {
  const match = /^\s*\[([A-Za-z0-9.-]+)(?:\s+"((?:[^"\\]|\\.)*)")?\]\s*$/.exec(line)
  if (match === null) return undefined
  const subsection = match[2]?.replace(/\\(.)/g, '$1')
  return {
    section: (match[1] as string).toLowerCase(),
    ...subsection === undefined ? {} : { subsection },
  }
}

/** True when a section block is the one a `section[.subsection]` name selects. */
function isTargetSection(current: ConfigSection, target: ConfigName): boolean {
  if (current.section.toLowerCase() !== target.section.toLowerCase()) return false
  const currentSubsection = (current.subsection ?? '').toLowerCase()
  return currentSubsection === (target.subsection ?? '').toLowerCase()
}

/** Read the variable name from one `name = value` line, or undefined. */
function lineVariable(line: string): string | undefined {
  const trimmed = line.trim()
  if (trimmed === '' || trimmed.startsWith('#') || trimmed.startsWith(';')) return undefined
  if (trimmed.startsWith('[')) return undefined
  const equals = trimmed.indexOf('=')
  const variable = (equals < 0 ? trimmed : trimmed.slice(0, equals)).trim()
  return variable === '' ? undefined : variable
}

/**
 * Return `text` with `name` set to `value`, preserving every other line
 * (comments, sections the Worker git does not model, ordering) byte for byte.
 */
export function setConfigText(text: string, name: string, value: string): string {
  const target = splitConfigName(name)
  if (/[\r\n]/.test(value)) throw fatal(`config value for '${name}' must not contain a newline`, 129)
  const lines = text.split('\n')
  let current: ConfigSection | undefined
  let targetStart = -1
  for (let index = 0; index < lines.length; index += 1) {
    const header = parseSectionHeader(lines[index] as string)
    if (header !== undefined) {
      if (targetStart >= 0) {
        // The target section ended before it held the variable: insert there.
        lines.splice(index, 0, `\t${target.variable} = ${value}`)
        return lines.join('\n')
      }
      current = header
      if (isTargetSection(header, target)) targetStart = index
      continue
    }
    if (targetStart < 0 || current === undefined || !isTargetSection(current, target)) continue
    const variable = lineVariable(lines[index] as string)
    if (variable === undefined || variable.toLowerCase() !== target.variable.toLowerCase()) continue
    lines[index] = `\t${variable} = ${value}`
    return lines.join('\n')
  }
  if (targetStart >= 0) {
    // The section runs to end of file. Keep a single trailing newline.
    const insertAt = lines.length > 0 && lines[lines.length - 1] === '' ? lines.length - 1 : lines.length
    lines.splice(insertAt, 0, `\t${target.variable} = ${value}`)
    return lines.join('\n')
  }
  const header = target.subsection === undefined
    ? `[${target.section}]`
    : `[${target.section} "${target.subsection}"]`
  let prefix = text
  if (prefix !== '' && !prefix.endsWith('\n')) prefix += '\n'
  if (prefix !== '' && !prefix.endsWith('\n\n')) prefix += '\n'
  return `${prefix}${header}\n\t${target.variable} = ${value}\n`
}

/** Read one config file, or undefined when it does not exist. */
async function readConfigText(fs: GitFs, path: string): Promise<string | undefined> {
  try {
    return decodeText(await fs.readFile(path))
  } catch (error) {
    if (isErrno(error, 'ENOENT', 'ENOTDIR')) return undefined
    throw error
  }
}

/** The repository-local configuration (`git config --local`). */
export async function readLocalConfig(repository: Repository): Promise<GitConfig> {
  const text = await readConfigText(repository.fs, gitPath(repository, 'config'))
  return text === undefined ? parseConfig('') : parseConfig(text)
}

/** Translate a config scope failure into git's own wording. */
function localRepositoryFailure(error: unknown, local: boolean): never {
  if (error instanceof GitFailure && /not a git repository/.test(error.stderr)) {
    throw local
      ? fatal('--local can only be used inside a git repository')
      : fatal('not in a git directory')
  }
  throw error
}

/** Read the effective configuration, falling back to the home file outside a repository. */
async function effectiveConfig(context: CommandContext): Promise<GitConfig> {
  try {
    return (await context.repository()).config
  } catch (error) {
    if (!(error instanceof GitFailure) || !/not a git repository/.test(error.stderr)) throw error
  }
  // Outside a repository `git config --get` still reads user-wide config.
  const config = parseConfig('')
  const home = context.env.HOME
  if (home !== undefined && home !== '') {
    const text = await readConfigText(context.fs, `${home}/.gitconfig`)
    if (text !== undefined) {
      const homeConfig = parseConfig(text)
      for (const [key, value] of homeConfig.withPrefix('')) config.set(key, value)
    }
  }
  for (const override of context.configOverrides) {
    const equals = override.indexOf('=')
    if (equals > 0) config.set(override.slice(0, equals).trim(), override.slice(equals + 1).trim())
  }
  return config
}

/** `git config`. */
export async function config(context: CommandContext): Promise<number> {
  let local = false
  let get = false
  const positional: string[] = []
  for (const arg of context.args) {
    if (arg === '--local') local = true
    else if (arg === '--get') get = true
    else if (arg === '-h' || arg === '--help') {
      context.output.stdout(CONFIG_USAGE)
      return 129
    } else if (arg === '--global' || arg === '--system' || arg === '--file' || arg === '-f'
      || arg.startsWith('--file=') || arg.startsWith('--global=') || arg.startsWith('--system=')) {
      throw fatal(
        `unsupported config option '${arg}': the Worker git only reads and writes the repository-local `
        + '.git/config (plus the home .gitconfig on reads). Nothing was changed.',
        129,
      )
    } else if (arg === '--unset' || arg === '--unset-all' || arg === '--add' || arg === '--replace-all'
      || arg === '--rename-section' || arg === '--remove-section' || arg === '--list' || arg === '-l') {
      throw fatal(`unsupported config option '${arg}': the Worker git only implements get and set. Nothing was changed.`, 129)
    } else if (arg.startsWith('-')) {
      throw fatal(`unsupported config option '${arg}': the Worker git only implements get and set. Nothing was changed.`, 129)
    } else {
      positional.push(arg)
    }
  }
  if (positional.length === 0) throw fatal('config: missing name; the Worker git only implements get and set', 129)
  const name = positional[0] as string
  // `git config <name>` (one argument) is a get, exactly like `--get`.
  if (get || positional.length === 1) {
    if (positional.length !== 1) throw fatal('config: --get takes exactly one name', 129)
    const value = local
      ? (await readLocalConfig(await localRepository())).get(name)
      : (await effectiveConfig(context)).get(name)
    if (value === undefined) return 1
    context.output.stdout(`${value}\n`)
    return 0
  }
  if (positional.length !== 2) throw fatal('config: wrong number of arguments, should be 1 or 2', 129)
  splitConfigName(name)
  const repository = await localRepository()
  const path = gitPath(repository, 'config')
  const text = await readConfigText(context.fs, path) ?? ''
  const updated = setConfigText(text, name, positional[1] as string)
  const lock = `${path}.lock`
  await context.fs.writeFile(lock, updated)
  await context.fs.rename(lock, path)
  return 0

  /** The repository-local config handle, failing with git's scope wording. */
  async function localRepository(): Promise<Repository> {
    try {
      return await context.repository()
    } catch (error) {
      localRepositoryFailure(error, local)
    }
  }
}
