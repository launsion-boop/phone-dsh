// SPDX-License-Identifier: MIT
/**
 * Child-process harness for `tests/sharp-shim.test.ts`.
 *
 * It mounts two module tables over the same inputs:
 *
 *  - `runtime`: the pinned webworker runtime's own `createNodeBuiltins()`
 *    table, whose `sharp` entry is the `notImplementedFail` stub. This is the
 *    pre-fix phone behaviour and must surface as DSH's `INVALID_IMAGE` for
 *    every valid image.
 *  - `phone`: the same table after `composePhoneStaticModules()`, i.e. the
 *    exact composition `runtime-binding.ts` hands to `createWorkerHost`.
 *
 * The `contract` half resolves `sharp` through the real Worker module loader
 * (no image needed); the `integration` half loads
 * `@deepseek-ai/dsh-attachment-local` out of the actual packed image and runs
 * its admission path, so the observed error is DSH's own, not a reimplementation.
 *
 * Browser imaging primitives are installed by `fake-image-platform.ts`; Node
 * has none and WebKit is NOT_VERIFIED here.
 * @module @phone-dsh/dsh-plugins/tests/fixtures/sharp-worker-harness
 */
import { readFileSync } from 'node:fs'

import { createNodeBuiltins } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/node/builtins.ts'
import { MODULE_PROXIES } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/module-proxies.ts'
import { WorkerModuleLoader, setActiveModuleLoader } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/module-system/module-loader.ts'
import { inflateImage } from '@deepseek-ai/dsh-experimental-webworker-runtime/src/storage/image-gzip.ts'
// Imported as a namespace: the structural runtime declarations deliberately do
// not redefine the runtime's own class/function names (zero-patch checker), so
// the two entry points are bound through one local cast.
import * as runtimeMemory from '@deepseek-ai/dsh-experimental-webworker-runtime/src/storage/memory.ts'

import { SHARP_MODULE_SPECIFIER, SHARP_SHIM_MARKER } from '../../worker-entry/src/sharp-marker.ts'
import { composePhoneStaticModules, type StaticModuleFactory } from '../../worker-entry/src/static-modules.ts'
import { installFakeImagePlatform } from './fake-image-platform.ts'

/** Structural face of the runtime's in-memory VFS that this harness uses. */
interface MemoryVfsLike {}

/** The two image-mount entry points the runtime's memory module exports. */
interface RuntimeMemoryModule {
  MemoryVfs: new () => MemoryVfsLike
  loadVfsImage: (image: Uint8Array, root?: string, vfs?: MemoryVfsLike) => MemoryVfsLike
}

const memoryModule = runtimeMemory as unknown as RuntimeMemoryModule

interface SharpMetadataLike {
  format?: string
  width?: number
  height?: number
  pages?: number
  hasAlpha?: boolean
  depth?: string
  space?: string
  orientation?: number
  hasProfile?: boolean
  exif?: unknown
}

interface SharpImageLike {
  metadata(): Promise<SharpMetadataLike>
  raw(): { toBuffer(): Promise<Uint8Array> }
  rotate(angle?: number): SharpImageLike
  resize(options: Record<string, unknown>): SharpImageLike
  clone(): SharpImageLike
  jpeg(options?: Record<string, unknown>): SharpImageLike
  webp(options?: Record<string, unknown>): SharpImageLike
  toBuffer(options?: { resolveWithObject?: boolean }): Promise<Uint8Array | { data: Uint8Array; info: { width: number; height: number } }>
}

type SharpLike = ((bytes: Uint8Array) => SharpImageLike) & Record<string, unknown>

interface AttachmentLocalLike {
  prepareImageFile(
    input: { data: Uint8Array; mediaType: string },
    limits: Record<string, unknown>,
    policy: Record<string, unknown>,
  ): Promise<{ ref: { mediaType: string; width: number; height: number; bytes: number } }>
}

interface ErrorFacts {
  name: string
  code: string | undefined
  message: string
}

interface MetadataFacts {
  format: string | undefined
  width: number | undefined
  height: number | undefined
  pages: number | undefined
  hasAlpha: boolean | undefined
  depth: string | undefined
  space: string | undefined
  orientation: number | undefined
  hasProfile: boolean | undefined
  hasExif: boolean
}

function errorFacts(error: unknown): ErrorFacts {
  const record = error as { name?: unknown; code?: unknown; message?: unknown } | null
  return {
    name: typeof record?.name === 'string' ? record.name : 'Error',
    code: typeof record?.code === 'string' ? record.code : undefined,
    message: typeof record?.message === 'string' ? record.message : String(error),
  }
}

function metadataFacts(metadata: SharpMetadataLike): MetadataFacts {
  return {
    format: metadata.format,
    width: metadata.width,
    height: metadata.height,
    pages: metadata.pages,
    hasAlpha: metadata.hasAlpha,
    depth: metadata.depth,
    space: metadata.space,
    orientation: metadata.orientation,
    hasProfile: metadata.hasProfile,
    hasExif: metadata.exif !== undefined,
  }
}

async function metadataOf(sharp: SharpLike, bytes: Uint8Array): Promise<MetadataFacts> {
  return metadataFacts(await sharp(bytes).metadata())
}

async function rawLengthOf(sharp: SharpLike, bytes: Uint8Array): Promise<number> {
  const buffer = await sharp(bytes).raw().toBuffer()
  return buffer.byteLength
}

interface DecodeReport {
  metadata?: MetadataFacts
  rawLength?: number
  error?: ErrorFacts
}

/**
 * Decode one vector without aborting the report: the pre-fix table is not a
 * callable, and the harness must still reach the admission half.
 */
async function decodeReport(sharp: SharpLike, bytes: Uint8Array): Promise<DecodeReport> {
  try {
    return { metadata: await metadataOf(sharp, bytes), rawLength: await rawLengthOf(sharp, bytes) }
  } catch (error) {
    return { error: errorFacts(error) }
  }
}

async function errorOf(run: () => Promise<unknown>): Promise<ErrorFacts> {
  try {
    await run()
    return { name: 'None', code: undefined, message: 'resolved without an error' }
  } catch (error) {
    return errorFacts(error)
  }
}

function syncErrorOf(run: () => unknown): ErrorFacts {
  try {
    run()
    return { name: 'None', code: undefined, message: 'returned without an error' }
  } catch (error) {
    return errorFacts(error)
  }
}

/** The limits attachment-local's admission receives in the phone profile. */
const IMAGE_LIMITS = {
  maxImageBytes: 20 * 1024 * 1024,
  maxImagesPerMessage: 20,
  maxMessageImageBytes: 200 * 1024 * 1024,
  maxImagePixels: 64_000_000,
  maxImageDimension: 8192,
  mediaTypes: ['image/png', 'image/jpeg', 'image/webp', 'image/gif'],
}

/** The normalization policy the phone profile resolves. */
const NORMALIZATION_POLICY = {
  maxPixels: 2048 * 2048,
  maxDimension: 8192,
  maxBytes: 4 * 1024 * 1024,
}

interface Vector {
  mediaType: string
  data: Uint8Array
}

async function integrationOf(
  staticModules: Record<string, StaticModuleFactory>,
  vfs: MemoryVfsLike,
  vector: Vector,
): Promise<{ ref?: { mediaType: string; width: number; height: number; bytes: number }; error?: ErrorFacts }> {
  const loader = new WorkerModuleLoader({ vfs, root: '/dsh', staticModules })
  setActiveModuleLoader(loader)
  try {
    const require = loader.requireFrom('/dsh')
    const attachment = require('@deepseek-ai/dsh-attachment-local') as AttachmentLocalLike
    const prepared = await attachment.prepareImageFile({ data: vector.data, mediaType: vector.mediaType }, IMAGE_LIMITS, NORMALIZATION_POLICY)
    return {
      ref: {
        mediaType: prepared.ref.mediaType,
        width: prepared.ref.width,
        height: prepared.ref.height,
        bytes: prepared.ref.bytes,
      },
    }
  } catch (error) {
    return { error: errorFacts(error) }
  }
}

function loadVector(path: string, mediaType: string): Vector {
  return { mediaType, data: new Uint8Array(readFileSync(path)) }
}

async function main(): Promise<void> {
  installFakeImagePlatform()
  const [, , imagePath, pngPath, gifPath, jpegPath, corruptPath] = process.argv
  if (imagePath === undefined || pngPath === undefined || gifPath === undefined || jpegPath === undefined || corruptPath === undefined) {
    throw new Error('usage: sharp-worker-harness <image.tar.gz> <one.png> <multi.gif> <clean.jpg> <corrupt.bin>')
  }

  // ---- contract half: the real loader resolves the exact `sharp` specifier.
  const empty = new memoryModule.MemoryVfs()
  const runtimeLoader = new WorkerModuleLoader({ vfs: empty, root: '/dsh', staticModules: createNodeBuiltins() })
  const runtimeSharp = runtimeLoader.requireFrom('/dsh')(SHARP_MODULE_SPECIFIER) as SharpLike
  const phoneLoader = new WorkerModuleLoader({
    vfs: empty,
    root: '/dsh',
    staticModules: composePhoneStaticModules(createNodeBuiltins()),
  })
  const phoneSharp = phoneLoader.requireFrom('/dsh')(SHARP_MODULE_SPECIFIER) as SharpLike

  const png = loadVector(pngPath, 'image/png')
  const gif = loadVector(gifPath, 'image/gif')
  const jpeg = loadVector(jpegPath, 'image/jpeg')
  const corrupt = loadVector(corruptPath, 'image/png')

  const report: Record<string, unknown> = {
    runtime: {
      proxy: MODULE_PROXIES[SHARP_MODULE_SPECIFIER],
      sharpType: typeof runtimeSharp,
      sharpKeys: typeof runtimeSharp === 'object' && runtimeSharp !== null ? Object.keys(runtimeSharp) : [],
      defaultCallError: syncErrorOf(() => (runtimeSharp as unknown as { default: () => unknown }).default()),
    },
    contract: {
      phoneSharpType: typeof phoneSharp,
      phoneSharpMarker: phoneSharp[SHARP_SHIM_MARKER] === true,
      png: await decodeReport(phoneSharp, png.data),
      gif: await decodeReport(phoneSharp, gif.data),
      jpeg: await decodeReport(phoneSharp, jpeg.data),
      corrupt: {
        metadata: await errorOf(async () => phoneSharp(corrupt.data).metadata()),
        raw: await errorOf(async () => phoneSharp(corrupt.data).raw().toBuffer()),
      },
      unsupported: {
        rotateAngle: syncErrorOf(() => phoneSharp(png.data).rotate(90)),
        resizeFit: syncErrorOf(() => phoneSharp(png.data).resize({ fit: 'cover' })),
        noOutput: await errorOf(async () => phoneSharp(png.data).toBuffer()),
        webpFallback: await errorOf(async () => phoneSharp(png.data).webp({ quality: 70 }).toBuffer()),
      },
      encodeJpeg: await (async () => {
        try {
          const encoded = await phoneSharp(png.data).clone().jpeg({ quality: 70 }).toBuffer({ resolveWithObject: true })
          if (encoded instanceof Uint8Array) {
            return { error: { name: 'Uint8Array', message: 'expected an object result from resolveWithObject' } }
          }
          return { info: encoded.info, bytes: encoded.data.byteLength }
        } catch (error) {
          return { error: errorFacts(error) }
        }
      })(),
    },
  }

  // ---- integration half: attachment-local's own admission over the image.
  const mounted = memoryModule.loadVfsImage(
    await inflateImage(new Uint8Array(readFileSync(imagePath)), 'sharp-shim regression'),
    '/dsh',
  )
  const runtimeTable = createNodeBuiltins()
  const phoneTable = composePhoneStaticModules(createNodeBuiltins())
  report.integration = {
    runtime: {
      png: await integrationOf(runtimeTable, mounted, png),
      gif: await integrationOf(runtimeTable, mounted, gif),
      jpeg: await integrationOf(runtimeTable, mounted, jpeg),
      corrupt: await integrationOf(runtimeTable, mounted, corrupt),
    },
    phone: {
      png: await integrationOf(phoneTable, mounted, png),
      gif: await integrationOf(phoneTable, mounted, gif),
      jpeg: await integrationOf(phoneTable, mounted, jpeg),
      corrupt: await integrationOf(phoneTable, mounted, corrupt),
    },
  }

  console.log(`__PDSH_SHARP_RESULT__ ${JSON.stringify(report)}`)
}

await main()
