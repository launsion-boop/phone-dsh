// SPDX-License-Identifier: MIT
/**
 * Bundle the probe module against a DeepSeek Harness checkout.
 *
 * The probe re-exports the checkout's own runtime, shell, HTTP and app-boot
 * sources. They are TypeScript sources (some use parameter properties the Node
 * type stripper does not accept), so esbuild bundles the probe to one ESM file
 * in a temporary directory. The checkout itself is only read.
 * @module @phone-dsh/dsh-contract-tests/bundle
 */
import { build } from 'esbuild'
import { join } from 'node:path'

/** Runtime source prefix the probe imports, mapped onto the checkout. */
const RUNTIME_PREFIX = '@deepseek-ai/dsh-experimental-webworker-runtime/src/'

/** App-boot source prefix the probe imports, mapped onto the checkout. */
const APP_BOOT_PREFIX = '@deepseek-ai/dsh-app-boot/src/'

/** Bundle inputs. */
export interface BundleProbeOptions {
  /** DeepSeek Harness checkout directory. */
  readonly checkout: string
  /** Absolute probe entry point inside this package. */
  readonly entry: string
  /** Absolute output file. */
  readonly outfile: string
}

/**
 * Bundle the probe against the checkout's sources.
 * @param options - checkout, entry point and output file.
 * @returns resolves when esbuild wrote the bundle.
 * @throws when esbuild cannot resolve a source or a dependency of it.
 */
export async function bundleProbe(options: BundleProbeOptions): Promise<void> {
  const runtimeSource = join(options.checkout, 'packages', 'experimental', 'webworker-runtime', 'src')
  const appBootSource = join(options.checkout, 'packages', 'boot', 'app-boot', 'src')
  await build({
    entryPoints: [options.entry],
    outfile: options.outfile,
    bundle: true,
    format: 'esm',
    platform: 'node',
    target: 'node22',
    // Node builtins stay external; every other dependency is bundled so the
    // probe imports no package from this repository.
    external: ['node:*'],
    absWorkingDir: options.checkout,
    logLevel: 'silent',
    banner: {
      // Bundled CommonJS dependencies still call `require(...)`; a Node ES
      // module has no ambient require.
      js: "import { createRequire as __xlContractCreateRequire } from 'node:module'; "
        + 'const require = __xlContractCreateRequire(import.meta.url);',
    },
    plugins: [{
      name: 'pdsh-contract-sources',
      setup(builder) {
        builder.onResolve({ filter: /^@deepseek-ai\/dsh-experimental-webworker-runtime\/src\// }, args => ({
          path: join(runtimeSource, args.path.slice(RUNTIME_PREFIX.length)),
        }))
        builder.onResolve({ filter: /^@deepseek-ai\/dsh-app-boot\/src\// }, args => ({
          path: join(appBootSource, args.path.slice(APP_BOOT_PREFIX.length)),
        }))
      },
    }],
  })
}
