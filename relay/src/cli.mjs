// SPDX-License-Identifier: MIT
// CLI wiring for `node relay.mjs`.  Configuration comes from
// PCLINK_PUBLIC_ORIGIN plus the documented environment variables and a small
// --host/--port/--quiet surface; the relay never guesses its origin from Host.

import process from 'node:process'
import { loadConfigFromEnvironment, usage } from './config.mjs'
import { createRelayServer } from './server.mjs'

export async function run(argv = process.argv.slice(2), env = process.env) {
  if (argv.includes('--help') || argv.includes('-h')) {
    process.stdout.write(`${usage()}\n`)
    return 0
  }
  let config
  try {
    config = loadConfigFromEnvironment(argv, env)
  } catch (error) {
    process.stderr.write(`relay: ${error.message}\n`)
    return 2
  }
  let relay
  try {
    relay = createRelayServer(config)
    await relay.listen()
  } catch (error) {
    process.stderr.write(`relay: failed to start: ${error.message}\n`)
    if (relay !== undefined) await relay.close()
    return 1
  }

  let shuttingDown = false
  const shutdown = async signal => {
    if (shuttingDown) return
    shuttingDown = true
    config.logger.info('relay.shutdown', { signal })
    await relay.close()
    process.exit(0)
  }
  process.once('SIGINT', () => { shutdown('SIGINT').catch(() => process.exit(1)) })
  process.once('SIGTERM', () => { shutdown('SIGTERM').catch(() => process.exit(1)) })
  return 0
}
