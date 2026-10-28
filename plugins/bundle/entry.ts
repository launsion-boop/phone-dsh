// SPDX-License-Identifier: MIT
/**
 * Phone-style DSH entry, bundled by build.mjs into one ESM file.
 *
 * Differences from the `dsh` CLI launcher:
 * - plugins resolve from a static table compiled into the bundle (no package
 *   tree on disk, no `node-addon-require-builtin` resolution interception);
 * - the profile is the build-time composition (dsh-base + surface + phone
 *   patch) plus optional runtime overlays, written under `$DSH_HOME/profiles/phone`;
 * - the launch environment is the process environment only (no `.env` layers:
 *   the host app owns secrets);
 * - the node:http fetch is installed before the tree boots when WebAssembly is
 *   unavailable (`--jitless`).
 *
 *   node --jitless dsh-phone.mjs [--xl-patch overlay.yml]... [--] <surface arguments>
 */

import { mkdirSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { format } from 'node:util'
import { boot, installFailLoud, loadOverlayPatches } from '@deepseek-ai/dsh-app-boot'
import { provideCmdline } from '@deepseek-ai/dsh-cmdline'
import { createLaunchEnvironmentSnapshot, DSH_LAUNCH_ENVIRONMENT_KEY } from '@deepseek-ai/dsh-launch-environment'
import type { Context } from '@deepseek-ai/cordis'
import { installNodeFetch } from '@phone-dsh/dsh-llm-bridge/install'
// @ts-expect-error -- generated at build time by build.mjs
import { BUILD, LAYERS, MODULES, TYPERT } from 'xl:modules'

const modules = MODULES as Record<string, () => Promise<unknown>>
const layers = LAYERS as Record<string, string>
const build = BUILD as { dshVersion: string; surface: string; layers: string[] }
const typertManifests = TYPERT as { package: string }[]

const startedAt = performance.now()
const timing = process.env.PDSH_DSH_TIMING === '1'
const mark = (label: string): void => {
  if (!timing) return
  const { rss, heapUsed } = process.memoryUsage()
  process.stderr.write(`pdsh-dsh: ${label} t=${(performance.now()).toFixed(0)}ms rss=${(rss / 1048576).toFixed(1)}MiB heap=${(heapUsed / 1048576).toFixed(1)}MiB\n`)
}

function parseArgs(argv: readonly string[]): { overlays: string[]; args: string[] } {
  const overlays: string[] = []
  const args: string[] = []
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i] as string
    if (arg === '--') { args.push(...argv.slice(i + 1)); break }
    if (arg === '--xl-patch') {
      const file = argv[++i]
      if (file === undefined) throw new Error('--xl-patch needs a file')
      overlays.push(resolve(file))
      continue
    }
    args.push(arg)
  }
  for (const file of (process.env.PDSH_DSH_PATCH ?? '').split(':').filter(Boolean)) overlays.push(resolve(file))
  return { overlays, args }
}

/** Loader replacement: resolve configured plugin names from the bundled table. */
const staticLoader = {
  async import(specifier: string): Promise<unknown> {
    const load = modules[specifier]
    if (load !== undefined) return await load()
    if (specifier.startsWith('file:')) return await import(specifier)
    throw new Error(`plugin ${JSON.stringify(specifier)} is not compiled into the phone bundle; add its row to the profile and rebuild`)
  },
}

async function main(): Promise<void> {
  // The resident surface's fatal boot configuration: fail before mounting any
  // server rather than leaving a listening process with no readiness line.
  if (build.surface === 'phone') {
    if ((process.env.PDSH_DSH_LAUNCH_TOKEN ?? '') === '') {
      process.stderr.write('dsh-phone: PDSH_DSH_LAUNCH_TOKEN is required for the resident phone surface\n')
      process.exit(1)
    }
    const port = process.env.PDSH_DSH_PORT ?? '0'
    if (!/^\d+$/.test(port) || Number(port) > 65535) {
      process.stderr.write(`dsh-phone: PDSH_DSH_PORT must be a port number from 0 through 65535, got ${JSON.stringify(port)}\n`)
      process.exit(1)
    }
  }
  installNodeFetch({ mode: 'auto' })
  process.env.PDSH_DSH_VERSION ??= build.dshVersion
  const home = resolve(process.env.DSH_HOME ?? join(process.cwd(), '.dsh-phone'))
  process.env.DSH_HOME = home
  const { overlays, args } = parseArgs(process.argv.slice(2))

  const profileDir = join(home, 'profiles', 'phone')
  mkdirSync(join(profileDir, 'layers'), { recursive: true, mode: 0o700 })
  const rootConfig = join(profileDir, 'cordis.yml')
  writeFileSync(rootConfig, '# phone profile root: composed from patch layers\n[]\n')
  const patches = []
  for (const label of build.layers) {
    const file = join(profileDir, 'layers', `${label}.yml`)
    writeFileSync(file, layers[label] as string)
    patches.push(...loadOverlayPatches('dsh', file))
  }
  for (const file of overlays) patches.push(...loadOverlayPatches('dsh', file))
  mark('compose')

  const app: { current?: Context } = {}
  let exiting = false
  const shutdown = async (code: number): Promise<void> => {
    if (exiting) return
    exiting = true
    mark('exit')
    if (timing) process.stderr.write(`pdsh-dsh: maxRSS=${(process.resourceUsage().maxRSS / 1024).toFixed(1)}MiB\n`)
    try { await app.current?.fiber.dispose() } finally { process.exit(code) }
  }
  process.on('SIGTERM', () => { void shutdown(0) })
  process.on('SIGINT', () => { void shutdown(130) })
  installFailLoud('dsh', process, async () => { await app.current?.fiber.dispose() })

  const values = Object.fromEntries(Object.entries(process.env).filter((entry): entry is [string, string] => entry[1] !== undefined))
  const environment = createLaunchEnvironmentSnapshot([{ source: 'process', values }])
  const ready = new Set<() => void>()
  let isReady = false
  const ctx = await boot('dsh', rootConfig, patches, (hostCtx: Context) => {
    app.current = hostCtx
    hostCtx.provide(DSH_LAUNCH_ENVIRONMENT_KEY, environment)
    ;(hostCtx.loader as unknown as { internal: unknown }).internal = staticLoader
    // Strict Typert descriptors shipped in the bundle (see build.mjs): the
    // Loader-entry discovery path cannot resolve a package tree at runtime.
    if (typertManifests.length > 0) {
      hostCtx.inject(['typert'], (typertCtx: Context) => {
        const registry = (typertCtx as unknown as {
          typert: { register(manifest: unknown): () => void }
        }).typert
        for (const manifest of typertManifests) {
          typertCtx.effect(() => registry.register(manifest), `bundled typert: ${manifest.package}`)
        }
      })
    }
    // PDSH_DSH_LOG=error|info|warn|debug mirrors the tree's logger to stderr (Cordis levels: error 0, info 1, warn 2, debug 3).
    const level = ({ error: 0, info: 1, warn: 2, debug: 3 } as Record<string, number>)[process.env.PDSH_DSH_LOG ?? '']
    if (level !== undefined) {
      hostCtx.logger.exporter({
        colors: false,
        levels: { default: level },
        export: (message) => { process.stderr.write(`[${message.type}] ${message.name}: ${format(...message.args)}\n`) },
      })
    }
    provideCmdline(hostCtx, {
      args,
      exit: (code: number) => { void shutdown(code) },
      ready: {
        onReady(listener: () => void) {
          if (isReady) { listener(); return () => {} }
          ready.add(listener)
          return () => { ready.delete(listener) }
        },
      },
    })
  })
  app.current = ctx
  isReady = true
  for (const listener of ready) listener()
  mark(`booted in ${(performance.now() - startedAt).toFixed(0)}ms (bundle eval included in t)`)
}

main().catch((error: unknown) => {
  process.stderr.write(`dsh-phone: ${error instanceof Error ? (error.stack ?? error.message) : String(error)}\n`)
  process.exit(1)
})
