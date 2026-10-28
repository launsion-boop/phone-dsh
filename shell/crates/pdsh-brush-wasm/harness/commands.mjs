// SPDX-License-Identifier: MIT
/**
 * Host command table for the brush wasm spike.
 *
 * The Worker equivalent would live in `plugins/shell-ext`: brush calls an
 * imported host function for every external command, and this module is the
 * host side of that hook. It implements a small, deterministic coreutils
 * subset over the three preopened directories, and reports every other name as
 * `command not found` (demo mode) or succeeds without output (stub mode, used
 * to measure shell-language acceptance rather than program availability).
 *
 * @module pdsh-brush-wasm/harness/commands
 */

import fs from 'node:fs'
import path from 'node:path'

/** Guest mount points and the host subdirectory each maps to. */
export const MOUNTS = [
  ['/dsh/workspace', 'workspace'],
  ['/dsh/home', 'home'],
  ['/dsh/tmp', 'tmp'],
]

/** Shell builtins that are never part of the host table. */
export const SHELL_BUILTINS = new Set([
  '.', ':', '[', 'alias', 'bg', 'bind', 'break', 'builtin', 'caller', 'cd',
  'command', 'compgen', 'complete', 'compopt', 'continue', 'declare', 'dirs',
  'disown', 'echo', 'enable', 'eval', 'exec', 'exit', 'export', 'false', 'fc',
  'fg', 'getopts', 'hash', 'help', 'history', 'jobs', 'kill', 'let', 'local',
  'logout', 'mapfile', 'popd', 'printf', 'pushd', 'pwd', 'read', 'readarray',
  'return', 'set', 'shift', 'shopt', 'source', 'suspend', 'test', 'times',
  'trap', 'true', 'type', 'typeset', 'ulimit', 'umask', 'unalias', 'unset',
  'wait',
])

/** A command failed in the way a POSIX utility would report it. */
class CommandError extends Error {
  /**
   * @param {string} message - diagnostic without the program prefix.
   * @param {number} [exitCode] - exit status.
   */
  constructor(message, exitCode = 1) {
    super(message)
    this.exitCode = exitCode
  }
}

/**
 * Resolve a shell path against the cwd and keep it inside the guest mounts.
 *
 * @param {string} cwd - guest working directory.
 * @param {string} target - path as typed by the user.
 * @returns {string} normalized guest path.
 */
export function guestPath(cwd, target) {
  const joined = target.startsWith('/') ? target : `${cwd}/${target}`
  const normalized = path.posix.normalize(joined)
  if (MOUNTS.some(([guest]) => normalized === guest || normalized.startsWith(`${guest}/`))) {
    return normalized
  }
  throw new CommandError(`'${target}': outside the /dsh mounts`)
}

/**
 * Map a guest path to the host directory.
 *
 * @param {string} root - host root.
 * @param {string} guest - normalized guest path.
 * @returns {string} host path.
 */
export function hostPath(root, guest) {
  for (const [mount, directory] of MOUNTS) {
    if (guest === mount || guest.startsWith(`${mount}/`)) {
      return path.join(root, directory, guest.slice(mount.length))
    }
  }
  throw new CommandError(`'${guest}': outside the /dsh mounts`)
}

function readFile(root, guest) {
  try {
    return fs.readFileSync(hostPath(root, guest))
  } catch (error) {
    if (error.code === 'ENOENT') throw new CommandError(`${guest}: No such file or directory`)
    if (error.code === 'EISDIR') throw new CommandError(`${guest}: Is a directory`)
    throw error
  }
}

function statOf(root, guest) {
  try {
    return fs.statSync(hostPath(root, guest))
  } catch (error) {
    if (error.code === 'ENOENT') throw new CommandError(`${guest}: No such file or directory`)
    throw error
  }
}

function concatInputs(root, cwd, files, stdin) {
  if (files.length === 0) return Buffer.from(stdin)
  return Buffer.concat(files.map((file) => readFile(root, guestPath(cwd, file))))
}

function linesOf(buffer) {
  const text = buffer.toString('utf8')
  if (text === '') return []
  const lines = text.split('\n')
  if (lines.at(-1) === '') lines.pop()
  return lines
}

/** @type {Record<string, (context: object) => {exitCode: number, stdout: string, stderr: string}>} */
const HANDLERS = {
  cat(context) {
    const { argv, cwd, root, stdin } = context
    let number = false
    const files = []
    for (const argument of argv) {
      if (argument === '-n') number = true
      else if (argument.startsWith('-') && argument !== '-') throw new CommandError('unsupported option')
      else files.push(argument)
    }
    let data = concatInputs(root, cwd, files, stdin).toString('utf8')
    if (number) {
      data = linesOf(Buffer.from(data))
        .map((line, index) => `${String(index + 1).padStart(6)}  ${line}`)
        .join('\n')
      if (data !== '') data += '\n'
    }
    return { exitCode: 0, stdout: data, stderr: '' }
  },

  ls(context) {
    const { argv, cwd, root } = context
    let all = false
    let long = false
    let one = false
    let recursive = false
    const targets = []
    for (const argument of argv) {
      if (argument === '-a' || argument === '-A') all = true
      else if (argument === '-l') long = true
      else if (argument === '-1') one = true
      else if (argument === '-R') recursive = true
      else if (argument === '-la' || argument === '-al') { all = true; long = true }
      else if (argument.startsWith('-') && argument !== '-') throw new CommandError('unsupported option')
      else targets.push(argument)
    }
    const paths = targets.length > 0 ? targets : ['.']
    const out = []
    const visit = (guest) => {
      const stat = statOf(root, guest)
      if (!stat.isDirectory()) return [path.posix.basename(guest)]
      const host = hostPath(root, guest)
      const entries = fs.readdirSync(host, { withFileTypes: true })
        .filter((entry) => all || !entry.name.startsWith('.'))
        .sort((left, right) => left.name.localeCompare(right.name))
      if (long) {
        return entries.map((entry) => {
          const entryGuest = path.posix.join(guest, entry.name)
          const entryStat = statOf(root, entryGuest)
          const mode = entry.isDirectory() ? 'drwxr-xr-x' : '-rw-r--r--'
          return `${mode}  1 user group ${String(entryStat.size).padStart(6)} ${entry.name}`
        })
      }
      return entries.map((entry) => entry.name)
    }
    for (const target of paths) {
      const guest = guestPath(cwd, target)
      if (paths.length > 1 || recursive) out.push(`${target}:`)
      const stat = statOf(root, guest)
      out.push(...visit(guest))
      if (recursive && stat.isDirectory()) {
        const host = hostPath(root, guest)
        for (const entry of fs.readdirSync(host, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
          if (entry.isDirectory() && (all || !entry.name.startsWith('.'))) {
            out.push('', `${path.posix.join(target, entry.name)}:`)
            out.push(...visit(path.posix.join(guest, entry.name)))
          }
        }
      }
    }
    void one
    return { exitCode: 0, stdout: out.length > 0 ? `${out.join('\n')}\n` : '', stderr: '' }
  },

  pwd(context) {
    return { exitCode: 0, stdout: `${context.cwd}\n`, stderr: '' }
  },

  mkdir(context) {
    let parents = false
    const paths = []
    for (const argument of context.argv) {
      if (argument === '-p') parents = true
      else if (argument.startsWith('-')) throw new CommandError('unsupported option')
      else paths.push(argument)
    }
    for (const target of paths) {
      const guest = guestPath(context.cwd, target)
      if (parents) fs.mkdirSync(hostPath(context.root, guest), { recursive: true })
      else fs.mkdirSync(hostPath(context.root, guest))
    }
    return { exitCode: 0, stdout: '', stderr: '' }
  },

  rmdir(context) {
    for (const target of context.argv) {
      fs.rmdirSync(hostPath(context.root, guestPath(context.cwd, target)))
    }
    return { exitCode: 0, stdout: '', stderr: '' }
  },

  rm(context) {
    let recursive = false
    let force = false
    const paths = []
    for (const argument of context.argv) {
      if (/^-[rRf]+$/.test(argument)) {
        recursive = recursive || /[rR]/.test(argument)
        force = force || argument.includes('f')
      } else if (argument.startsWith('-') && argument !== '-') throw new CommandError('unsupported option')
      else paths.push(argument)
    }
    for (const target of paths) {
      const guest = guestPath(context.cwd, target)
      if (guest === '/dsh/workspace' || guest === '/dsh/home' || guest === '/dsh/tmp') {
        throw new CommandError(`${target}: refusing to remove a mount point`)
      }
      const host = hostPath(context.root, guest)
      fs.rmSync(host, { recursive, force, maxRetries: 0 })
    }
    return { exitCode: 0, stdout: '', stderr: '' }
  },

  touch(context) {
    for (const target of context.argv) {
      const host = hostPath(context.root, guestPath(context.cwd, target))
      if (fs.existsSync(host)) {
        const now = new Date()
        fs.utimesSync(host, now, now)
      } else {
        fs.writeFileSync(host, '')
      }
    }
    return { exitCode: 0, stdout: '', stderr: '' }
  },

  cp(context) {
    const args = context.argv.filter((argument) => argument !== '-r' && argument !== '-R')
    if (args.length < 2) throw new CommandError('missing file operand')
    const target = guestPath(context.cwd, args.at(-1))
    for (const source of args.slice(0, -1)) {
      const sourceGuest = guestPath(context.cwd, source)
      const sourceHost = hostPath(context.root, sourceGuest)
      const targetHost = hostPath(context.root, target)
      const destination = fs.existsSync(targetHost) && fs.statSync(targetHost).isDirectory()
        ? path.join(targetHost, path.basename(sourceHost))
        : targetHost
      fs.cpSync(sourceHost, destination, { recursive: true })
    }
    return { exitCode: 0, stdout: '', stderr: '' }
  },

  mv(context) {
    const args = context.argv
    if (args.length < 2) throw new CommandError('missing file operand')
    const target = guestPath(context.cwd, args.at(-1))
    for (const source of args.slice(0, -1)) {
      const sourceGuest = guestPath(context.cwd, source)
      const sourceHost = hostPath(context.root, sourceGuest)
      const targetHost = hostPath(context.root, target)
      const destination = fs.existsSync(targetHost) && fs.statSync(targetHost).isDirectory()
        ? path.join(targetHost, path.basename(sourceHost))
        : targetHost
      fs.renameSync(sourceHost, destination)
    }
    return { exitCode: 0, stdout: '', stderr: '' }
  },

  head(context) {
    let count = 10
    const files = []
    const argv = context.argv.slice()
    for (let index = 0; index < argv.length; index += 1) {
      const argument = argv[index]
      if (argument === '-n') { count = Number(argv[index + 1]); index += 1 }
      else if (/^-\d+$/.test(argument)) count = Number(argument.slice(1))
      else if (argument.startsWith('-')) throw new CommandError('unsupported option')
      else files.push(argument)
    }
    const lines = linesOf(concatInputs(context.root, context.cwd, files, context.stdin))
    return { exitCode: 0, stdout: lines.slice(0, count).map((line) => `${line}\n`).join(''), stderr: '' }
  },

  tail(context) {
    let count = 10
    const files = []
    const argv = context.argv.slice()
    for (let index = 0; index < argv.length; index += 1) {
      const argument = argv[index]
      if (argument === '-n') { count = Number(argv[index + 1]); index += 1 }
      else if (/^-\d+$/.test(argument)) count = Number(argument.slice(1))
      else if (argument.startsWith('-')) throw new CommandError('unsupported option')
      else files.push(argument)
    }
    const lines = linesOf(concatInputs(context.root, context.cwd, files, context.stdin))
    return { exitCode: 0, stdout: lines.slice(-count).map((line) => `${line}\n`).join(''), stderr: '' }
  },

  wc(context) {
    let countLines = false
    let countWords = false
    let countBytes = false
    const files = []
    for (const argument of context.argv) {
      if (argument === '-l') countLines = true
      else if (argument === '-w') countWords = true
      else if (argument === '-c') countBytes = true
      else if (argument.startsWith('-')) throw new CommandError('unsupported option')
      else files.push(argument)
    }
    if (!countLines && !countWords && !countBytes) { countLines = true; countWords = true; countBytes = true }
    const measure = (buffer) => {
      const text = buffer.toString('utf8')
      const values = []
      if (countLines) values.push(String(text === '' ? 0 : text.split('\n').length - (text.endsWith('\n') ? 1 : 0)))
      if (countWords) values.push(String(text.split(/\s+/).filter((word) => word !== '').length))
      if (countBytes) values.push(String(buffer.length))
      return values.join(' ')
    }
    if (files.length === 0) {
      return { exitCode: 0, stdout: `${measure(Buffer.from(context.stdin))}\n`, stderr: '' }
    }
    const out = files.map((file) => `${measure(readFile(context.root, guestPath(context.cwd, file)))} ${file}\n`)
    return { exitCode: 0, stdout: out.join(''), stderr: '' }
  },

  grep(context) {
    const argv = context.argv.slice()
    let number = false
    let ignoreCase = false
    let invert = false
    let filesOnly = false
    let quiet = false
    let recursive = false
    let extended = false
    let countOnly = false
    const operands = []
    for (let index = 0; index < argv.length; index += 1) {
      const argument = argv[index]
      if (argument === '--') { operands.push(...argv.slice(index + 1)); break }
      if (/^-[nivlqrREcF]+$/.test(argument)) {
        number = number || argument.includes('n')
        ignoreCase = ignoreCase || argument.includes('i')
        invert = invert || argument.includes('v')
        filesOnly = filesOnly || argument.includes('l')
        quiet = quiet || argument.includes('q')
        recursive = recursive || /[rR]/.test(argument)
        extended = argument.includes('E') ? true : argument.includes('F') ? false : extended
        countOnly = countOnly || argument.includes('c')
      } else if (argument.startsWith('-') && argument.length > 1) throw new CommandError('unsupported option')
      else operands.push(argument)
    }
    const pattern = operands.shift()
    if (pattern === undefined) throw new CommandError('missing pattern')
    const matcher = extended ? new RegExp(pattern, ignoreCase ? 'i' : '') : new RegExp(
      pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'),
      ignoreCase ? 'i' : '',
    )
    const targets = operands.length > 0 ? operands : []
    const search = (guest) => {
      const stat = statOf(context.root, guest)
      if (stat.isDirectory()) {
        if (!recursive) throw new CommandError(`${guest}: Is a directory`)
        const results = []
        for (const entry of fs.readdirSync(hostPath(context.root, guest), { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
          results.push(...search(path.posix.join(guest, entry.name)))
        }
        return results
      }
      const lines = linesOf(readFile(context.root, guest))
      const matching = []
      lines.forEach((line, index) => {
        if (matcher.test(line) !== invert) {
          matching.push(`${filesOnly ? '' : number ? `${index + 1}:` : ''}${line}`)
        }
      })
      return matching
    }
    let results = []
    if (targets.length === 0) {
      const lines = linesOf(Buffer.from(context.stdin))
      lines.forEach((line, index) => {
        if (matcher.test(line) !== invert) results.push(`${number ? `${index + 1}:` : ''}${line}`)
      })
    } else {
      for (const target of targets) {
        const guest = guestPath(context.cwd, target)
        const found = search(guest)
        if (filesOnly && found.length > 0) results.push(target)
        else if (!filesOnly) results.push(...found.map((line) => (targets.length > 1 ? `${target}:${line}` : line)))
      }
    }
    if (quiet) return { exitCode: results.length > 0 ? 0 : 1, stdout: '', stderr: '' }
    return {
      exitCode: results.length > 0 ? 0 : 1,
      stdout: countOnly ? `${results.length}\n` : results.length > 0 ? `${results.join('\n')}\n` : '',
      stderr: '',
    }
  },

  sort(context) {
    let numeric = false
    let reverse = false
    let unique = false
    const files = []
    for (const argument of context.argv) {
      if (argument === '-n') numeric = true
      else if (argument === '-r') reverse = true
      else if (argument === '-u') unique = true
      else if (argument.startsWith('-')) throw new CommandError('unsupported option')
      else files.push(argument)
    }
    let lines = linesOf(concatInputs(context.root, context.cwd, files, context.stdin))
    lines.sort((left, right) => (numeric ? Number(left) - Number(right) : left.localeCompare(right)))
    if (reverse) lines.reverse()
    if (unique) lines = [...new Set(lines)]
    return { exitCode: 0, stdout: lines.map((line) => `${line}\n`).join(''), stderr: '' }
  },

  uniq(context) {
    let withCounts = false
    let duplicatesOnly = false
    const files = []
    for (const argument of context.argv) {
      if (/^-[cd]+$/.test(argument)) {
        withCounts = withCounts || argument.includes('c')
        duplicatesOnly = duplicatesOnly || argument.includes('d')
      } else if (argument.startsWith('-')) throw new CommandError('unsupported option')
      else files.push(argument)
    }
    const lines = linesOf(concatInputs(context.root, context.cwd, files, context.stdin))
    const groups = []
    for (const line of lines) {
      const last = groups.at(-1)
      if (last !== undefined && last.line === line) last.count += 1
      else groups.push({ line, count: 1 })
    }
    const filtered = duplicatesOnly ? groups.filter(({ count }) => count > 1) : groups
    const out = filtered.map(({ line, count }) => (withCounts ? `${String(count).padStart(7)} ${line}` : line))
    return { exitCode: 0, stdout: out.map((line) => `${line}\n`).join(''), stderr: '' }
  },

  cut(context) {
    let delimiter = '\t'
    let fields = [1]
    let characters
    const files = []
    const argv = context.argv.slice()
    for (let index = 0; index < argv.length; index += 1) {
      const argument = argv[index]
      if (argument === '-d') { delimiter = argv[index + 1]; index += 1 }
      else if (argument.startsWith('-d') && argument.length > 2) delimiter = argument.slice(2)
      else if (argument === '-f') { fields = argv[index + 1].split(',').map(Number); index += 1 }
      else if (argument.startsWith('-f') && argument.length > 2) fields = argument.slice(2).split(',').map(Number)
      else if (argument === '-c') { characters = argv[index + 1]; index += 1 }
      else if (argument.startsWith('-c') && argument.length > 2) characters = argument.slice(2)
      else if (argument.startsWith('-')) throw new CommandError('unsupported option')
      else files.push(argument)
    }
    const lines = linesOf(concatInputs(context.root, context.cwd, files, context.stdin))
    const out = lines.map((line) => {
      if (characters !== undefined) {
        const [start, end] = characters.split('-').map((value) => (value === '' ? undefined : Number(value)))
        return line.slice((start ?? 1) - 1, end ?? line.length)
      }
      const parts = line.split(delimiter)
      return fields.map((field) => parts[field - 1] ?? '').join(delimiter)
    })
    return { exitCode: 0, stdout: out.map((line) => `${line}\n`).join(''), stderr: '' }
  },

  tr(context) {
    const argv = context.argv.slice()
    let deleteMode = false
    if (argv[0] === '-d') { deleteMode = true; argv.shift() }
    if (deleteMode) {
      if (argv.length < 1) throw new CommandError('missing operand')
      const deleted = new Set([...argv[0].replace(/\\n/g, '\n').replace(/\\t/g, '\t')])
      const text = Buffer.from(context.stdin).toString('utf8')
      return { exitCode: 0, stdout: [...text].filter((character) => !deleted.has(character)).join(''), stderr: '' }
    }
    if (argv.length < 2) throw new CommandError('missing operand')
    const expand = (set) => set
      .replace(/\\n/g, '\n')
      .replace(/\\t/g, '\t')
      .replace(/([A-Za-z0-9])-([A-Za-z0-9])/g, (_, start, end) => {
        const from = start.charCodeAt(0)
        const to = end.charCodeAt(0)
        let value = ''
        for (let code = from; code <= to; code += 1) value += String.fromCharCode(code)
        return value
      })
    const from = expand(argv[0])
    const to = expand(argv[1])
    const map = new Map()
    for (let index = 0; index < from.length; index += 1) map.set(from[index], to[index] ?? to.at(-1) ?? '')
    const text = Buffer.from(context.stdin).toString('utf8')
    let output = ''
    for (const character of text) output += map.get(character) ?? character
    return { exitCode: 0, stdout: output, stderr: '' }
  },

  sed(context) {
    const argv = context.argv.slice()
    let quiet = false
    if (argv[0] === '-n') { quiet = true; argv.shift() }
    const script = argv.shift()
    if (script === undefined) throw new CommandError('missing script')
    const expression = /^s(.)(.*?)\1(.*?)\1([gi]*)$/.exec(script)
    if (expression === null) throw new CommandError('only s/pattern/replacement/ is supported')
    const [, , pattern, replacement, flags] = expression
    const matcher = new RegExp(pattern, flags.includes('g') ? 'g' : '')
    const lines = linesOf(concatInputs(context.root, context.cwd, argv, context.stdin))
    const out = []
    for (const line of lines) {
      const replaced = line.replace(matcher, replacement.replace(/\\\//g, '/'))
      if (!quiet || replaced !== line) out.push(replaced)
    }
    return { exitCode: 0, stdout: out.map((line) => `${line}\n`).join(''), stderr: '' }
  },

  find(context) {
    let namePattern
    let type
    let maxDepth = Number.POSITIVE_INFINITY
    const roots = []
    const argv = context.argv.slice()
    for (let index = 0; index < argv.length; index += 1) {
      const argument = argv[index]
      if (argument === '-name') { namePattern = argv[index + 1]; index += 1 }
      else if (argument === '-type') { type = argv[index + 1]; index += 1 }
      else if (argument === '-maxdepth') { maxDepth = Number(argv[index + 1]); index += 1 }
      else if (argument.startsWith('-')) throw new CommandError('unsupported option')
      else roots.push(argument)
    }
    if (roots.length === 0) roots.push('.')
    const matcher = namePattern === undefined ? null : new RegExp(
      `^${namePattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/\\\*/g, '.*').replace(/\\\?/g, '.')}$`,
    )
    const results = []
    const walk = (guest, depth) => {
      const stat = statOf(context.root, guest)
      if (matcher === null || matcher.test(path.posix.basename(guest))) {
        if (type === undefined || (type === 'f' && stat.isFile()) || (type === 'd' && stat.isDirectory())) {
          results.push(guest)
        }
      }
      if (stat.isDirectory() && depth < maxDepth) {
        for (const entry of fs.readdirSync(hostPath(context.root, guest), { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
          walk(path.posix.join(guest, entry.name), depth + 1)
        }
      }
    }
    for (const root of roots) walk(guestPath(context.cwd, root), 0)
    return { exitCode: 0, stdout: results.map((line) => `${line}\n`).join(''), stderr: '' }
  },

  stat(context) {
    const argv = context.argv.slice()
    let format
    if (argv[0] === '-c') { format = argv[1]; argv.splice(0, 2) }
    const target = argv[0]
    if (target === undefined) throw new CommandError('missing operand')
    const guest = guestPath(context.cwd, target)
    const stat = statOf(context.root, guest)
    if (format !== undefined) {
      const output = format
        .replace(/%s/g, String(stat.size))
        .replace(/%n/g, target)
        .replace(/%F/g, stat.isDirectory() ? 'directory' : 'regular file')
        .replace(/%Y/g, String(Math.floor(stat.mtimeMs / 1000)))
      return { exitCode: 0, stdout: `${output}\n`, stderr: '' }
    }
    return {
      exitCode: 0,
      stdout: `  File: ${target}\n  Size: ${stat.size}\tType: ${stat.isDirectory() ? 'directory' : 'regular file'}\n`,
      stderr: '',
    }
  },

  seq(context) {
    const numbers = context.argv.filter((argument) => !argument.startsWith('-')).map(Number)
    let first = 1
    let step = 1
    let last
    if (numbers.length === 1) [last] = numbers
    else if (numbers.length === 2) [first, last] = numbers
    else if (numbers.length === 3) [first, step, last] = numbers
    else throw new CommandError('missing operand')
    const out = []
    if (step > 0) for (let value = first; value <= last; value += step) out.push(String(value))
    else for (let value = first; value >= last; value += step) out.push(String(value))
    return { exitCode: 0, stdout: out.map((line) => `${line}\n`).join(''), stderr: '' }
  },

  tee(context) {
    const append = context.argv.includes('-a')
    const files = context.argv.filter((argument) => !argument.startsWith('-'))
    const data = Buffer.from(context.stdin)
    for (const file of files) {
      const host = hostPath(context.root, guestPath(context.cwd, file))
      if (append) fs.appendFileSync(host, data)
      else fs.writeFileSync(host, data)
    }
    return { exitCode: 0, stdout: data.toString('utf8'), stderr: '' }
  },

  printenv(context) {
    if (context.argv.length === 0) {
      return { exitCode: 0, stdout: context.env.map(([name, value]) => `${name}=${value}`).join('\n') + '\n', stderr: '' }
    }
    const value = context.env.find(([name]) => name === context.argv[0])?.[1]
    return value === undefined
      ? { exitCode: 1, stdout: '', stderr: '' }
      : { exitCode: 0, stdout: `${value}\n`, stderr: '' }
  },

  basename(context) {
    const target = context.argv[0]
    if (target === undefined) throw new CommandError('missing operand')
    return { exitCode: 0, stdout: `${path.posix.basename(target.replace(/\/+$/, ''))}\n`, stderr: '' }
  },

  dirname(context) {
    const target = context.argv[0]
    if (target === undefined) throw new CommandError('missing operand')
    return { exitCode: 0, stdout: `${path.posix.dirname(target)}\n`, stderr: '' }
  },

  env(context) {
    const out = context.env.map(([name, value]) => `${name}=${value}`)
    return { exitCode: 0, stdout: out.length > 0 ? `${out.join('\n')}\n` : '', stderr: '' }
  },

  date() {
    return { exitCode: 0, stdout: 'Thu Jan  1 00:00:00 UTC 2026\n', stderr: '' }
  },

  uname() {
    return { exitCode: 0, stdout: 'Linux\n', stderr: '' }
  },

  sleep() {
    return { exitCode: 0, stdout: '', stderr: '' }
  },

  which(context) {
    const target = context.argv[0]
    if (target === undefined) return { exitCode: 1, stdout: '', stderr: '' }
    const host = context.hostNames.includes(target)
    return host
      ? { exitCode: 0, stdout: `/usr/bin/${target}\n`, stderr: '' }
      : { exitCode: 1, stdout: '', stderr: '' }
  },

  printf(context) {
    const argv = context.argv.slice()
    const format = argv.shift()
    if (format === undefined) throw new CommandError('missing format')
    let output = ''
    let argument = 0
    const specifiers = format.match(/%[sdifxX%]/g) ?? []
    for (const specifier of specifiers) {
      if (specifier === '%%') { output += '%'; continue }
      const value = argv[argument]
      argument += 1
      if (specifier === '%s') output += value ?? ''
      else if (specifier === '%d' || specifier === '%i') output += String(Number(value ?? 0) | 0)
      else if (specifier === '%x') output += (Number(value ?? 0) | 0).toString(16)
      else if (specifier === '%X') output += (Number(value ?? 0) | 0).toString(16).toUpperCase()
      else output += value ?? ''
    }
    output = output.replace(/\\n/g, '\n').replace(/\\t/g, '\t').replace(/\\\\/g, '\\')
    return { exitCode: 0, stdout: output, stderr: '' }
  },
}

/** Every command name the harness implements for real. */
export const IMPLEMENTED = Object.freeze(Object.keys(HANDLERS).sort())

/**
 * Create a command table from the requested mode.
 *
 * @param {object} options - options.
 * @param {string} options.root - host root directory.
 * @param {'demo'|'stub'} [options.mode] - demo runs the real subset; stub succeeds for every advertised name.
 * @param {string[]} [options.extraNames] - additional names to advertise in stub mode (the corpus programs).
 * @param {() => boolean} [options.isCancelled] - cancellation flag.
 * @returns {{names: string[], exec: Function, isCancelled: Function}} table.
 */
export function createCommandTable(options) {
  const { root, mode = 'demo', extraNames = [], isCancelled = () => false } = options
  const names = mode === 'stub'
    ? [...new Set([...IMPLEMENTED, ...extraNames])].sort()
    : IMPLEMENTED.slice()

  const exec = (request) => {
    if (mode === 'stub') return { exitCode: 0, stdout: '', stderr: '' }
    const handler = HANDLERS[request.command]
    if (handler === undefined) {
      return { exitCode: 127, stdout: '', stderr: `command not found: ${request.command}\n` }
    }
    try {
      return handler({ ...request, argv: request.args, root, hostNames: names })
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      return { exitCode: error.exitCode ?? 1, stdout: '', stderr: `${request.command}: ${message}\n` }
    }
  }

  return { names, exec, isCancelled }
}

/** Shell keywords that must never be registered as host commands. */
const KEYWORDS = new Set([
  'if', 'then', 'else', 'elif', 'fi', 'for', 'select', 'while', 'until', 'do',
  'done', 'case', 'esac', 'in', 'function', 'time', 'coproc', '!', '[[', ']]',
  '{', '}', '(', ')',
])

/**
 * Extract the plausible program names from a corpus of shell commands.
 *
 * This is deliberately a recogniser, not a parser: it only runs in stub mode,
 * where over-advertising a name as a no-op builtin is harmless.
 *
 * @param {Iterable<string>} commands - command lines.
 * @returns {string[]} sorted program names.
 */
export function collectProgramNames(commands) {
  const names = new Set()
  for (const command of commands) {
    const masked = command.replace(/'[^']*'/g, "''").replace(/"[^"]*"/g, '""')
    for (const segment of masked.split(/[\n;|&(){}]+/)) {
      const words = segment.trim().split(/\s+/)
      let index = 0
      while (index < words.length && /^[A-Za-z_]\w*=/.test(words[index])) index += 1
      const candidate = words[index]
      if (candidate === undefined) continue
      if (KEYWORDS.has(candidate) || candidate.startsWith('#') || candidate.includes('/')) continue
      if (!/^[A-Za-z0-9_.+-]+$/.test(candidate)) continue
      if (SHELL_BUILTINS.has(candidate)) continue
      names.add(candidate)
    }
  }
  return [...names].sort()
}
