#!/usr/bin/env node
/** `npx pclink` entry point. */
import { createInterface } from 'node:readline/promises'
import process from 'node:process'
import { join } from 'node:path'
import {
  createCliAdminClient,
  printStatus,
  runPair,
  runRotateIdentity,
  runUnpair,
} from './commands.mjs'
import { runInstall } from './install.mjs'
import { PclinkError } from '../core/errors.mjs'

function dshHome(env = process.env) {
  return env.DSH_HOME ?? join(env.HOME ?? process.cwd(), '.dsh')
}

function parseArgs(argv) {
  const options = { command: argv[0], flags: new Map(), positional: [] }
  for (let index = 1; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--manual' || argument === '--all' || argument === '--no-restart' || argument === '--no-pair' || argument === '--help' || argument === '-h') {
      options.flags.set(argument, true)
      continue
    }
    if (argument === '--spec') {
      const value = argv[++index]
      if (value === undefined) throw new PclinkError('bad_frame', '--spec requires a value')
      options.flags.set('--spec', value)
      continue
    }
    if (argument.startsWith('--')) throw new PclinkError('bad_frame', `unknown option ${argument}`)
    options.positional.push(argument)
  }
  return options
}

function usage() {
  process.stdout.write(`usage: pclink <command> [options]

commands:
  install [--spec <pkg>] [--no-restart] [--no-pair]
      Find dsh, check the version range and native module, run
      'dsh plugin --profile web add <spec>', ask about restarting dsh web,
      wait for the plugin, print the package SHA-256 and start pairing.
  pair [--manual]
      Open one QR (default) or manual-code pairing and poll it. The PC
      operator must type the 12-character fingerprint shown on the phone;
      a TTY is mandatory and there is no --yes path.
  status
      Print PC identity, relay state, pairings and the pending pairing.
  unpair [<name|machineId|fingerprint>] [--all]
      Revoke one pairing, or all with no argument/--all. Requires a TTY.
  rotate-identity
      Generate a new PC identity after typing the confirmation phrase.

Environment:
  DSH_HOME          DSH home (default ~/.dsh); PCLink state is $DSH_HOME/pclink
  PCLINK_RELAY_URL  Relay origin or ws(s) URL (default https://pclink.tonoai.cn)
  PCLINK_PC_NAME    PC display name
`)
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  if (args.command === undefined || args.command === 'help' || args.command === '--help' || args.command === '-h'
    || args.flags.has('--help') || args.flags.has('-h')) {
    usage()
    return 0
  }
  const home = dshHome()
  const output = process.stdout
  const stdinIsTTY = process.stdin.isTTY === true
  const readline = createInterface({ input: process.stdin, output: process.stdout })
  const ask = prompt => readline.question(prompt)
  try {
    switch (args.command) {
      case 'status': {
        const status = await createCliAdminClient(home).status()
        printStatus(status, output)
        return 0
      }
      case 'pair': {
        const client = createCliAdminClient(home)
        await runPair({
          client,
          mode: args.flags.has('--manual') ? 'manual' : 'qr',
          output,
          stdinIsTTY,
          ask,
        })
        return 0
      }
      case 'unpair': {
        if (args.positional.length > 1) throw new PclinkError('bad_frame', 'unpair accepts at most one target')
        const client = createCliAdminClient(home)
        const status = await client.status()
        const result = await runUnpair({
          client,
          status,
          ...(args.positional[0] === undefined ? {} : { target: args.positional[0] }),
          all: args.flags.has('--all') || args.positional.length === 0,
          output,
          stdinIsTTY,
          confirm: ask,
        })
        output.write(`已解除配对：${result.removed.join(', ') || '(none)'}\n`)
        return 0
      }
      case 'rotate-identity': {
        const client = createCliAdminClient(home)
        const result = await runRotateIdentity({ client, output, stdinIsTTY, ask })
        output.write(`身份已旋转：${result.oldMachineId} -> ${result.newMachineId}\n`)
        return 0
      }
      case 'install': {
        if (!stdinIsTTY) throw new PclinkError('unavailable', 'install requires a TTY for the restart question')
        const spec = args.flags.get('--spec')
        await runInstall({
          dshHome: home,
          output,
          ask,
          ...(spec === undefined ? {} : { spec }),
          noRestart: args.flags.has('--no-restart'),
          noPair: args.flags.has('--no-pair'),
          pair: options => {
            const client = createCliAdminClient(home)
            return runPair({ client, output, stdinIsTTY, ask, ...options })
          },
        })
        return 0
      }
      default:
        usage()
        throw new PclinkError('bad_frame', `unknown command ${args.command}`)
    }
  } finally {
    readline.close()
  }
}

main()
  .then(code => process.exit(code))
  .catch(error => {
    if (error instanceof PclinkError) console.error(`错误 [${error.code}]: ${error.message}`)
    else console.error(`错误 [unavailable]: ${error?.message ?? String(error)}`)
    process.exit(1)
  })
