#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// Resolve the model provider the user's local `dsh` uses by default and print
// only shell `export` lines for `eval`:
//
//   eval "$(node scripts/ci/model-env.mjs)"
//
// Resolution goes through the pinned DSH checkout's own modules, never through
// a copy of their logic:
//
//   * `@deepseek-ai/dsh-credentials-local` (packages/credentials/credentials-local)
//     provides CREDENTIALS_FILENAME, resolveSpec() and parseCredentialsDocument().
//     The document lives at `$DSH_HOME/.credentials.yaml` (or $HOME/.dsh when
//     DSH_HOME is unset). Reference entries in its `refs:` map are keyed by the
//     environment-style reference name, for example `DEEPSEEK_API_KEY`.
//   * `@deepseek-ai/dsh-app-boot` (packages/boot/app-boot) composes the DSH
//     loader patch layers without booting: the checkout's base bundle, the
//     active profile's bundles and its `cordis.patch.yml`, then the harness
//     home patch. The composed rows carry the default model row
//     (`agent-default-model`: provider + model) and the DeepSeek adapter row
//     (`llm-deepseek`: base URL and API-key reference when the user overrode
//     them).
//   * The base URL falls back to `DEEPSEEK_BASE_URL` from the DSH launch
//     environment layers (inherited process environment, project `.env`,
//     `$DSH_HOME/.env`, read by the same app-boot loader) and finally to the
//     adapter's public default.
//
// Field path used (documented for the batch operator):
//   $DSH_HOME/.credentials.yaml -> refs.<apiKeyEnv>          (the API key)
//   composed config row `agent-default-model` -> config.model (the model id)
//   composed row `llm-deepseek` -> config.baseURL            (the base URL)
//   launch env DEEPSEEK_BASE_URL / adapter PUBLIC_BASE_URL   (fallbacks)
//
// Output (stdout only, exactly three lines):
//   export PDSH_MODEL_BASE_URL='...'
//   export PDSH_MODEL_NAME='...'
//   export PDSH_MODEL_API_KEY='...'
//
// No value is ever logged, and nothing is written to disk. On a missing or
// unreadable credentials document the script prints a clear message on stderr
// and exits 3; a missing/unusable checkout exits 2.

import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { pathToFileURL } from 'node:url'

/** Exit codes documented in scripts/ci/scenarios/README.md. */
const EXIT_CHECKOUT = 2
const EXIT_RESOLVE = 3

/** Print a one-line diagnostic to stderr and exit. */
function fail(message, code = EXIT_RESOLVE) {
  process.stderr.write(`model-env: ${message}\n`)
  process.exit(code)
}

/** Single-quote one value for POSIX sh. */
function shellQuote(value) {
  return `'${value.replaceAll("'", "'\\''")}'`
}

/** Resolve the pinned DSH checkout exactly as the other phone scripts do. */
function resolveCheckout() {
  const fromEnv = process.env.PDSH_DSH_CHECKOUT?.trim()
  if (fromEnv) return fromEnv
  const configPath = join(homedir(), '.config', 'xl', 'dsh-checkout')
  try {
    const line = readFileSync(configPath, 'utf8').split(/\r?\n/, 1)[0]?.trim()
    if (line) return line
  } catch {
    // Reported below with the generic message.
  }
  fail(
    'no pinned DSH checkout: set PDSH_DSH_CHECKOUT or write its path to $HOME/.config/phone-dsh/dsh-checkout',
    EXIT_CHECKOUT,
  )
}

/** The first `cordis.patch.yml` under the checkout that belongs to `bundleName`. */
function bundlePatchPath(checkout, bundleName) {
  const root = join(checkout, 'packages', 'bundle')
  let names = []
  try {
    names = readdirSync(root, { withFileTypes: true })
      .filter(entry => entry.isDirectory())
      .map(entry => entry.name)
  } catch {
    return undefined
  }
  for (const name of names) {
    const directory = join(root, name)
    try {
      const manifest = JSON.parse(readFileSync(join(directory, 'package.json'), 'utf8'))
      if (manifest.name !== bundleName) continue
      const patch = join(directory, 'cordis.patch.yml')
      return existsSync(patch) ? patch : undefined
    } catch {
      continue
    }
  }
  return undefined
}

/** Active profile name: DSH_PROFILE, else the profile the home last used. */
function activeProfile(profileRoot) {
  const fromEnv = process.env.DSH_PROFILE?.trim()
  if (fromEnv) return fromEnv
  try {
    const names = readdirSync(profileRoot, { withFileTypes: true })
      .filter(entry => entry.isDirectory())
      .map(entry => entry.name)
      .filter(name => existsSync(join(profileRoot, name, 'package.json')))
    return names.length === 1 ? names[0] : undefined
  } catch {
    return undefined
  }
}

async function main() {
  const checkout = resolveCheckout()
  if (!existsSync(join(checkout, 'packages', 'credentials', 'credentials-local', 'lib', 'index.js'))) {
    fail(`checkout has no built credentials-local module: ${checkout}`, EXIT_CHECKOUT)
  }
  if (!existsSync(join(checkout, 'packages', 'boot', 'app-boot', 'lib', 'index.js'))) {
    fail(`checkout has no built app-boot module: ${checkout}`, EXIT_CHECKOUT)
  }

  // `LocalCredentialProvider` is the runtime consumer of this document; this
  // script reads the same document through `resolveSpec` and
  // `parseCredentialsDocument` because it does not boot a Cordis context. It
  // reproduces the provider's precedence (managed `refs` first, then the launch
  // environment) and its 0600 permission requirement below.
  const credentials = await import(
    pathToFileURL(join(checkout, 'packages', 'credentials', 'credentials-local', 'lib', 'index.js')).href
  )
  const appBoot = await import(
    pathToFileURL(join(checkout, 'packages', 'boot', 'app-boot', 'lib', 'index.js')).href
  )

  const dshHome = process.env.DSH_HOME?.trim() || join(homedir(), '.dsh')
  const spec = credentials.resolveSpec({ dshHome })

  // Compose the loader layers without booting: each selected bundle's patch,
  // the profile's own patch, then the harness home patch.
  const layers = []
  const addPatch = (file) => {
    if (!file) return
    try {
      const parsed = appBoot.loadOptionalPatches('model-env', file)
      if (parsed && parsed.length > 0) layers.push(parsed)
    } catch (error) {
      fail(`cannot read config layer ${file}: ${error.message}`)
    }
  }
  const profileRoot = join(dshHome, 'profiles')
  const profile = activeProfile(profileRoot)
  let bundleNames = []
  if (profile) {
    try {
      const manifest = JSON.parse(
        readFileSync(join(profileRoot, profile, 'package.json'), 'utf8'),
      )
      bundleNames = manifest?.dsh?.profile?.bundles ?? []
    } catch {
      bundleNames = []
    }
    for (const name of bundleNames) addPatch(bundlePatchPath(checkout, name))
  }
  if (bundleNames.length === 0) {
    const base = join(checkout, 'packages', 'bundle', 'base', 'cordis.patch.yml')
    if (existsSync(base)) addPatch(base)
  }
  if (profile) {
    addPatch(join(profileRoot, profile, appBoot.PROFILE_PATCH_FILENAME ?? 'cordis.patch.yml'))
  }
  const homePatch = join(dshHome, appBoot.PROFILE_PATCH_FILENAME ?? 'cordis.patch.yml')
  if (existsSync(homePatch)) addPatch(homePatch)

  let entries = []
  try {
    entries = appBoot.composeEntries(layers, () => {})
  } catch (error) {
    fail(`cannot compose the DSH config layers: ${error.message}`)
  }
  const row = id => entries.find(entry => entry?.id === id)
  const configOf = id => {
    const value = row(id)?.config
    return value !== null && typeof value === 'object' ? value : {}
  }

  const modelRow = configOf('agent-default-model')
  const provider = typeof modelRow.provider === 'string' ? modelRow.provider : undefined
  const model = typeof modelRow.model === 'string' ? modelRow.model : undefined
  if (provider && provider !== 'deepseek-official') {
    fail(
      `the default DSH provider is "${provider}", which the phone model gateway does not serve; `
      + 'select the DeepSeek provider in DSH first',
    )
  }
  if (!model) fail('the composed DSH config has no agent-default-model config.model')

  // The launch environment layers resolve DEEPSEEK_BASE_URL the same way the
  // DSH adapter does. loadLayeredEnv also materializes accepted values, so it
  // runs before the fallbacks below.
  let launch
  try {
    launch = appBoot.loadLayeredEnv('model-env', process.cwd())
  } catch (error) {
    // A rejected .env file is a clear configuration error; there is nothing
    // to fall back to that DSH itself would accept.
    fail(`cannot read the DSH launch environment: ${error.message}`)
  }
  const llmRow = configOf('llm-deepseek')
  const adapterBaseURL = typeof llmRow.baseURL === 'string' && llmRow.baseURL ? llmRow.baseURL : undefined
  const envBaseURL = launch.get('DEEPSEEK_BASE_URL')?.value || undefined
  let publicBaseURL
  try {
    const adapter = await import(
      pathToFileURL(join(checkout, 'packages', 'llm', 'llm-deepseek', 'lib', 'index.js')).href
    )
    publicBaseURL = adapter.PUBLIC_BASE_URL
  } catch {
    publicBaseURL = undefined
  }
  if (!publicBaseURL) {
    fail(
      'cannot read the DSH adapter public base URL from the pinned checkout; '
      + 'set DEEPSEEK_BASE_URL in the DSH launch environment',
    )
  }
  const baseURL = adapterBaseURL ?? envBaseURL ?? publicBaseURL

  let parsedURL
  try {
    parsedURL = new URL(baseURL)
  } catch {
    fail('the resolved model base URL is not a valid URL')
  }
  if (!['http:', 'https:'].includes(parsedURL.protocol) || parsedURL.username || parsedURL.password) {
    fail('the resolved model base URL must be plain HTTP(S) without credentials')
  }

  const apiKeyRef = typeof llmRow.apiKeyEnv === 'string' && llmRow.apiKeyEnv
    ? llmRow.apiKeyEnv
    : 'DEEPSEEK_API_KEY'

  // The provider refuses a document other OS users can read before it reads a
  // value; the same rule applies here.
  try {
    const mode = statSync(spec.filename).mode & 0o777
    if ((mode & 0o077) !== 0) {
      fail(
        `credentials document ${spec.filename} is readable by group/other (mode `
        + `${mode.toString(8)}); run: chmod 600 ${spec.filename}`,
      )
    }
  } catch (error) {
    if (error?.code !== 'ENOENT') {
      fail(`cannot stat the credentials document at ${spec.filename}: ${error.code ?? 'error'}`)
    }
  }
  let documentText
  try {
    documentText = readFileSync(spec.filename, 'utf8')
  } catch (error) {
    if (error?.code === 'ENOENT') {
      fail(
        `credentials document not found at ${spec.filename}; store ${apiKeyRef} through DSH `
        + '(the Models page) or export it before running this script',
      )
    }
    fail(`cannot read the credentials document at ${spec.filename}: ${error.code ?? 'error'}`)
  }
  let document
  try {
    document = credentials.parseCredentialsDocument(documentText, spec.filename)
  } catch (error) {
    // The parser's message never quotes a value; it reports a code and a key.
    fail(`cannot parse the credentials document at ${spec.filename}: ${error.message}`)
  }
  let apiKey = document.refs.get(apiKeyRef)
  if (!apiKey) {
    // The provider's documented precedence: the managed store, then the
    // launch environment. An environment fallback never reaches this script's
    // stdout unless it is the effective key.
    apiKey = launch.get(apiKeyRef)?.value || undefined
  }
  if (!apiKey) {
    fail(
      `the credentials document at ${spec.filename} has no refs.${apiKeyRef} and the `
      + 'launch environment does not export it either',
    )
  }

  const lines = [
    `export PDSH_MODEL_BASE_URL=${shellQuote(baseURL)}`,
    `export PDSH_MODEL_NAME=${shellQuote(model)}`,
    `export PDSH_MODEL_API_KEY=${shellQuote(apiKey)}`,
  ]
  process.stdout.write(`${lines.join('\n')}\n`)
}

main().catch(error => {
  // Never echo an error object that could carry a credential value.
  fail(`unexpected failure: ${error?.code ?? error?.name ?? 'error'}`)
})
