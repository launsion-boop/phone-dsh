// SPDX-License-Identifier: MIT
/**
 * G2-FIX-60 regression: `read_image` inside the phone Worker.
 *
 * The pinned runtime replaces `sharp` with a `notImplementedFail` stub, and
 * DSH's attachment-local folds any sharp failure into `INVALID_IMAGE`
 * ("Unsupported or malformed image data."). This test drives the real packed
 * image, the real Worker module loader, and attachment-local's own admission
 * path for two tables:
 *
 *  - the runtime table (`createNodeBuiltins()`): the pre-fix behaviour. Every
 *    valid golden vector must come back as `INVALID_IMAGE`, proving the
 *    regression is observable and the assertion is not tautological.
 *  - the phone table (`composePhoneStaticModules()`, the composition
 *    `runtime-binding.ts` installs): the shim must decode the vectors, report
 *    the container facts, and let admission pass.
 *
 * The decode path is the esbuild-bundled Worker entry graph (no native sharp):
 * the harness bundle imports the same runtime sources through the same
 * checkout prefix, installs Worker-shaped `createImageBitmap`/`OffscreenCanvas`
 * stand-ins, and never imports the sharp package. WebKit execution remains
 * NOT_VERIFIED; this test runs the Worker runtime under Node.
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { after, test } from 'node:test'

import { build } from 'esbuild'

import { createSharpModule } from '../worker-entry/src/sharp-shim.ts'
import { parseImageMetadata, readTiffOrientation } from '../worker-entry/src/sharp-metadata.ts'
import { installFakeImagePlatform } from './fixtures/fake-image-platform.ts'
import { GOLDEN_GIF_2FRAME, GOLDEN_JPEG_3X2, GOLDEN_PNG_1X1 } from './fixtures/golden-images.ts'

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')
const checkout = process.env.PDSH_DSH_CHECKOUT
const skip = checkout === undefined || checkout === ''
  ? 'PDSH_DSH_CHECKOUT is unset; the Worker runtime, loader, and image come from the pinned checkout'
  : false

const RUNTIME_PREFIX = '@deepseek-ai/dsh-experimental-webworker-runtime/src/'

/** Temp directories created by this file. */
const scratch: string[] = []
after(() => {
  for (const directory of scratch) rmSync(directory, { recursive: true, force: true })
})

interface DecodeReport {
  metadata?: Record<string, unknown>
  rawLength?: number
  error?: { name: string; code: string | undefined; message: string }
}

interface CapturedResult {
  runtime: {
    proxy: string
    sharpType: string
    sharpKeys: string[]
    defaultCallError: { name: string; code: string | undefined; message: string }
  }
  contract: {
    phoneSharpType: string
    phoneSharpMarker: boolean
    png: DecodeReport
    gif: DecodeReport
    jpeg: DecodeReport
    corrupt: {
      metadata: { name: string; code: string | undefined; message: string }
      raw: { name: string; code: string | undefined; message: string }
    }
    unsupported: Record<string, { name: string; code: string | undefined; message: string }>
    encodeJpeg: { info?: { width: number; height: number }; bytes?: number; error?: { name: string; message: string } }
  }
  integration: {
    runtime: Record<'png' | 'gif' | 'jpeg' | 'corrupt', { ref?: unknown; error?: { name: string; code: string | undefined; message: string } }>
    phone: Record<'png' | 'gif' | 'jpeg' | 'corrupt', { ref?: unknown; error?: { name: string; code: string | undefined; message: string } }>
  }
}

/**
 * Bundle the child harness against the pinned checkout's runtime sources.
 * @param options - bundle inputs.
 * @param options.outfile - bundled harness path.
 * @param options.checkout - verified pinned checkout.
 */
async function bundleHarness(options: { outfile: string; checkout: string }): Promise<void> {
  const runtimeSrc = join(options.checkout, 'packages/experimental/webworker-runtime/src')
  await build({
    entryPoints: [join(root, 'tests', 'fixtures', 'sharp-worker-harness.ts')],
    outfile: options.outfile,
    bundle: true,
    format: 'esm',
    platform: 'node',
    target: 'node22',
    external: ['node:*'],
    banner: {
      js: "import { createRequire as __xlCreateRequire } from 'node:module'; const require = __xlCreateRequire(import.meta.url);",
    },
    absWorkingDir: options.checkout,
    logLevel: 'silent',
    plugins: [{
      name: 'pdsh-runtime-source',
      setup(builder) {
        builder.onResolve({ filter: /^@deepseek-ai\/dsh-experimental-webworker-runtime\/src\// }, args => ({
          path: join(runtimeSrc, args.path.slice(RUNTIME_PREFIX.length)),
        }))
      },
    }],
  })
}

/**
 * Read one metadata field by name without widening the JSON result.
 * @param result - metadata facts reported by the harness.
 * @param key - field name.
 * @returns the field value.
 */
function field(result: Record<string, unknown>, key: string): unknown {
  return result[key]
}

/** Restore the two Worker imaging globals after a test replaces them. */
function snapshotImagingGlobals(): () => void {
  const scope = globalThis as unknown as Record<string, unknown>
  const names = ['createImageBitmap', 'OffscreenCanvas'] as const
  const saved = names.map(name => ({
    name,
    present: Object.hasOwn(scope, name),
    value: scope[name],
  }))
  return () => {
    for (const { name, present, value } of saved) {
      if (present) scope[name] = value
      else delete scope[name]
    }
  }
}

test('the Node imaging stand-in enforces the WorkerGlobalScope receiver on every path', async () => {
  const restore = snapshotImagingGlobals()
  installFakeImagePlatform()
  try {
    const shim = createSharpModule()
    const vectors = [
      { name: 'PNG', bytes: new Uint8Array(Buffer.from(GOLDEN_PNG_1X1, 'base64')), width: 1, height: 1 },
      { name: 'GIF', bytes: new Uint8Array(Buffer.from(GOLDEN_GIF_2FRAME, 'base64')), width: 2, height: 2 },
      { name: 'JPEG', bytes: new Uint8Array(Buffer.from(GOLDEN_JPEG_3X2, 'base64')), width: 3, height: 2 },
    ] as const

    for (const vector of vectors) {
      const metadata = await shim(vector.bytes).metadata()
      assert.deepEqual(
        { width: metadata.width, height: metadata.height },
        { width: vector.width, height: vector.height },
        `${vector.name} metadata`,
      )
      const raw = await shim(vector.bytes).raw().toBuffer({ resolveWithObject: true })
      assert.equal(raw instanceof Uint8Array, false, `${vector.name} raw output carries its info`)
      const output = raw as { data: Uint8Array; info: { width: number; height: number; channels: number } }
      assert.equal(output.data.byteLength, vector.width * vector.height * 4, `${vector.name} raw RGBA length`)
      assert.deepEqual(
        { width: output.info.width, height: output.info.height, channels: output.info.channels },
        { width: vector.width, height: vector.height, channels: 4 },
        `${vector.name} raw info`,
      )
    }

    const resized = await shim(vectors[2].bytes)
      .resize({ width: 2, height: 2, fit: 'inside' })
      .jpeg({ quality: 70 })
      .toBuffer({ resolveWithObject: true })
    assert.equal(resized instanceof Uint8Array, false)
    const resizedOutput = resized as { data: Uint8Array; info: { width: number; height: number; channels: number } }
    assert.deepEqual(
      { width: resizedOutput.info.width, height: resizedOutput.info.height, channels: resizedOutput.info.channels },
      { width: 2, height: 1, channels: 3 },
      'JPEG resize stays inside the 2x2 box',
    )
    assert.equal(resizedOutput.data[0], 0xff, 'JPEG encoder output starts with SOI')
    assert.equal(resizedOutput.data[1], 0xd8, 'JPEG encoder output starts with SOI')

    const encodedPng = await shim(vectors[0].bytes).png().toBuffer()
    assert.equal(
      Buffer.from(encodedPng as Uint8Array).subarray(0, 8).toString('hex'),
      '89504e470d0a1a0a',
      'PNG encoder output keeps the PNG signature',
    )

    const normalizedGif = await shim(vectors[1].bytes).jpeg({ quality: 80 }).toBuffer({ resolveWithObject: true })
    assert.equal(normalizedGif instanceof Uint8Array, false)
    const normalizedGifOutput = normalizedGif as { data: Uint8Array; info: { width: number; height: number } }
    assert.deepEqual(
      { width: normalizedGifOutput.info.width, height: normalizedGifOutput.info.height },
      { width: 2, height: 2 },
      'GIF normalization encodes the stored frame at its dimensions',
    )
    assert.ok(normalizedGifOutput.data.byteLength > 0)

    // Some WebKit builds reject the options bag. The retry without options must
    // still reach the same Worker scope after the first call is refused.
    const scope = globalThis as unknown as Record<string, unknown>
    const installed = scope.createImageBitmap as (
      this: unknown,
      source: unknown,
      options?: unknown,
    ) => Promise<unknown>
    scope.createImageBitmap = async function createImageBitmapRejectsOptions(
      this: unknown,
      source: unknown,
      options?: unknown,
    ) {
      if (this !== scope) {
        throw new TypeError(
          'Can only call WorkerGlobalScope.createImageBitmap on instances of WorkerGlobalScope',
        )
      }
      if (options !== undefined) throw new TypeError('this WebKit build rejected the options bag')
      return installed.call(this, source)
    }
    const retried = await shim(vectors[2].bytes).raw().toBuffer()
    assert.equal((retried as Uint8Array).byteLength, 3 * 2 * 4, 'the no-options retry decodes the raster')
  } finally {
    restore()
  }
})

test('metadata needs no imaging backend and a missing primitive stays unsupported', async () => {
  const restore = snapshotImagingGlobals()
  const scope = globalThis as unknown as Record<string, unknown>
  delete scope.createImageBitmap
  delete scope.OffscreenCanvas
  try {
    const shim = createSharpModule()
    const png = new Uint8Array(Buffer.from(GOLDEN_PNG_1X1, 'base64'))
    const metadata = await shim(png).metadata()
    assert.deepEqual({ format: metadata.format, width: metadata.width, height: metadata.height }, {
      format: 'png',
      width: 1,
      height: 1,
    }, 'container metadata is read without createImageBitmap/OffscreenCanvas')

    for (const run of [
      () => shim(png).raw().toBuffer(),
      () => shim(png).jpeg().toBuffer(),
    ]) {
      await assert.rejects(run, (error: unknown) => {
        const facts = error as { code?: string; message?: string }
        return facts.code === 'SHARP_UNSUPPORTED_OPERATION'
          && /createImageBitmap\/OffscreenCanvas/.test(facts.message ?? '')
      }, 'a runtime without the imaging primitives must not report malformed bytes')
    }
  } finally {
    restore()
  }
})

test('container inspection reports PNG/GIF/JPEG/WebP facts without a pixel decoder', async () => {
  const png = new Uint8Array(Buffer.from(GOLDEN_PNG_1X1, 'base64'))
  const pngFacts = parseImageMetadata(png)
  assert.equal(pngFacts.format, 'png')
  assert.deepEqual({ width: pngFacts.width, height: pngFacts.height }, { width: 1, height: 1 })
  assert.equal(pngFacts.hasAlpha, true)
  assert.equal(pngFacts.depth, 'uchar')
  assert.equal(pngFacts.space, 'srgb')

  const gifFacts = parseImageMetadata(new Uint8Array(Buffer.from(GOLDEN_GIF_2FRAME, 'base64')))
  assert.equal(gifFacts.format, 'gif')
  assert.equal(gifFacts.pages, 2)

  const jpegFacts = parseImageMetadata(new Uint8Array(Buffer.from(GOLDEN_JPEG_3X2, 'base64')))
  assert.equal(jpegFacts.format, 'jpeg')
  assert.deepEqual({ width: jpegFacts.width, height: jpegFacts.height }, { width: 3, height: 2 })
  assert.equal(jpegFacts.isProgressive, false)

  // A minimal VP8X chunk: 4x3 canvas with the alpha feature bit set.
  const vp8x = Uint8Array.from([
    0x52, 0x49, 0x46, 0x46, 22, 0, 0, 0, 0x57, 0x45, 0x42, 0x50,
    0x56, 0x50, 0x38, 0x58, 10, 0, 0, 0,
    0x10, 0, 0, 0, 3, 0, 0, 2, 0, 0,
  ])
  const webpFacts = parseImageMetadata(vp8x)
  assert.equal(webpFacts.format, 'webp')
  assert.deepEqual({ width: webpFacts.width, height: webpFacts.height }, { width: 4, height: 3 })
  assert.equal(webpFacts.hasAlpha, true)

  // Corrupt bytes refuse here, before any decode attempt.
  assert.throws(() => parseImageMetadata(png.subarray(0, 20)), /xl sharp shim: input is not a decodable image/)

  // EXIF orientation 6 (TIFF little-endian, one IFD0 entry).
  const exif = Uint8Array.from([
    0x49, 0x49, 0x2a, 0x00, 8, 0, 0, 0,
    1, 0,
    0x12, 0x01, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0,
    0, 0, 0, 0,
  ])
  assert.equal(readTiffOrientation(exif, 0), 6)

  // The unsupported-operation error is distinct from malformed input and names
  // the operation; no platform primitives are needed to reach it.
  const shim = createSharpModule()
  await assert.rejects(shim(png.subarray(0, 20)).metadata(), (error: unknown) => {
    return (error as { code?: string }).code === 'SHARP_INVALID_IMAGE'
  })
  assert.throws(() => shim(png).rotate(90), (error: unknown) => {
    const facts = error as { code?: string; message?: string }
    return facts.code === 'SHARP_UNSUPPORTED_OPERATION' && /sharp\.rotate\(angle\)/.test(facts.message ?? '')
  })
})

test('the Worker sharp shim makes read_image decode real rasters (G2-FIX-60)', { skip }, async () => {
  assert.notEqual(checkout, undefined)
  const directory = mkdtempSync(join(tmpdir(), 'pdsh-sharp-shim-'))
  scratch.push(directory)

  const pngPath = join(directory, 'one.png')
  const gifPath = join(directory, 'two-frame.gif')
  const jpegPath = join(directory, 'clean.jpg')
  const corruptPath = join(directory, 'corrupt.bin')
  const png = Buffer.from(GOLDEN_PNG_1X1, 'base64')
  const gif = Buffer.from(GOLDEN_GIF_2FRAME, 'base64')
  const jpeg = Buffer.from(GOLDEN_JPEG_3X2, 'base64')
  assert.equal(png.byteLength, 68, 'the canonical vector stays the 68-byte 1x1 PNG')
  assert.equal(gif.subarray(0, 6).toString('latin1'), 'GIF89a')
  assert.equal(jpeg.subarray(0, 2).toString('hex'), 'ffd8')
  writeFileSync(pngPath, png)
  writeFileSync(gifPath, gif)
  writeFileSync(jpegPath, jpeg)
  // Truncated inside IHDR: a header probe has to refuse it, not guess a size.
  writeFileSync(corruptPath, png.subarray(0, 20))

  const imageDirectory = join(directory, 'image')
  // Drive the gate script itself: this also exercises its Worker-bundle shim
  // assertion, not just the library call path.
  const packed = spawnSync(
    process.execPath,
    [join(root, 'scripts', 'pack-image.mjs'), '--out', imageDirectory],
    { encoding: 'utf8', timeout: 600_000, env: { ...process.env, PDSH_DSH_CHECKOUT: checkout } },
  )
  const packedOutput = `${packed.stdout ?? ''}${packed.stderr ?? ''}`
  assert.equal(packed.status, 0, `pack-image failed:\n${packedOutput}`)
  assert.match(packedOutput, /pack-image: OK/)
  assert.match(packedOutput, /sharp:\s+shim/)

  const harness = join(directory, 'harness.mjs')
  await bundleHarness({ outfile: harness, checkout: checkout as string })
  const harnessText = readFileSync(harness, 'utf8')
  // The decode path is bundled from our layer; native sharp and libvips are
  // not part of it. The marker is also the bundle-level presence assertion.
  assert.match(harnessText, /pdsh-sharp-shim\/1/, 'the Worker sharp shim is bundled into the harness')
  assert.doesNotMatch(harnessText, /node_modules\/sharp/, 'the harness must not bundle the native sharp package')

  const child = spawnSync(
    process.execPath,
    [harness, join(imageDirectory, 'image.tar.gz'), pngPath, gifPath, jpegPath, corruptPath],
    { encoding: 'utf8', timeout: 180_000, env: { ...process.env, PDSH_DSH_CHECKOUT: checkout } },
  )
  const output = `${child.stdout ?? ''}${child.stderr ?? ''}`
  assert.equal(child.status, 0, `harness exited ${String(child.status)}:\n${output}`)
  const line = (child.stdout ?? '').split('\n').find(entry => entry.startsWith('__PDSH_SHARP_RESULT__ '))
  assert.notEqual(line, undefined, `harness printed no result line:\n${output}`)
  const result = JSON.parse((line as string).slice('__PDSH_SHARP_RESULT__ '.length)) as CapturedResult
  const unsupported = (name: string): { name: string; code: string | undefined; message: string } => {
    const facts = result.contract.unsupported[name]
    assert.notEqual(facts, undefined, `the harness did not report the unsupported operation ${name}`)
    return facts as { name: string; code: string | undefined; message: string }
  }

  // ---- The phone table removes the defect: PNG/JPEG pass through unchanged,
  //      the multi-frame GIF is normalized to a single-frame JPEG, corrupt
  //      bytes still refuse.
  assert.equal(
    result.integration.phone.png.error,
    undefined,
    `phone PNG admission failed: ${JSON.stringify(result.integration.phone.png.error)}`,
  )
  assert.deepEqual(result.integration.phone.png.ref, {
    mediaType: 'image/png',
    width: 1,
    height: 1,
    bytes: 68,
  })
  assert.equal(
    result.integration.phone.jpeg.error,
    undefined,
    `phone JPEG admission failed: ${JSON.stringify(result.integration.phone.jpeg.error)}`,
  )
  assert.deepEqual(result.integration.phone.jpeg.ref, {
    mediaType: 'image/jpeg',
    width: 3,
    height: 2,
    bytes: jpeg.byteLength,
  })
  assert.equal(
    result.integration.phone.gif.error,
    undefined,
    `phone GIF admission failed: ${JSON.stringify(result.integration.phone.gif.error)}`,
  )
  const normalizedGif = result.integration.phone.gif.ref as { mediaType: string; width: number; height: number; bytes: number }
  assert.equal(normalizedGif.mediaType, 'image/jpeg')
  assert.equal(normalizedGif.width, 2)
  assert.equal(normalizedGif.height, 2)
  assert.ok(normalizedGif.bytes > 0)
  assert.equal(result.integration.phone.corrupt.error?.code, 'INVALID_IMAGE')
  assert.equal(result.integration.phone.corrupt.error?.message, 'Unsupported or malformed image data.')

  // ---- The runtime's own entry is still the refusing stub.
  assert.equal(result.runtime.proxy, './node/external_packages/sharp.ts')
  assert.equal(result.runtime.sharpType, 'object')
  assert.deepEqual([...result.runtime.sharpKeys].sort(), ['__esModule', 'default'])
  assert.equal(result.runtime.defaultCallError.code, 'ERR_FEATURE_UNAVAILABLE_ON_PLATFORM')
  assert.match(result.runtime.defaultCallError.message, /sharp\.default is not available in the worker host/)

  // ---- The composed table wins over that entry: a callable, marked shim.
  assert.equal(result.contract.phoneSharpType, 'function')
  assert.equal(result.contract.phoneSharpMarker, true)

  // ---- Golden header facts and decoded RGBA length.
  assert.equal(result.contract.png.error, undefined, `shim PNG decode failed: ${JSON.stringify(result.contract.png.error)}`)
  assert.equal(result.contract.gif.error, undefined, `shim GIF decode failed: ${JSON.stringify(result.contract.gif.error)}`)
  assert.equal(result.contract.jpeg.error, undefined, `shim JPEG decode failed: ${JSON.stringify(result.contract.jpeg.error)}`)
  const pngMetadata = result.contract.png.metadata as Record<string, unknown>
  assert.equal(field(pngMetadata, 'format'), 'png')
  assert.equal(field(pngMetadata, 'width'), 1)
  assert.equal(field(pngMetadata, 'height'), 1)
  assert.equal(field(pngMetadata, 'pages'), 1)
  assert.equal(field(pngMetadata, 'hasAlpha'), true)
  assert.equal(field(pngMetadata, 'depth'), 'uchar')
  assert.equal(field(pngMetadata, 'space'), 'srgb')
  assert.equal(result.contract.png.rawLength, 1 * 1 * 4)

  const gifMetadata = result.contract.gif.metadata as Record<string, unknown>
  assert.equal(field(gifMetadata, 'format'), 'gif')
  assert.equal(field(gifMetadata, 'width'), 2)
  assert.equal(field(gifMetadata, 'height'), 2)
  assert.equal(field(gifMetadata, 'pages'), 2)
  assert.equal((field(gifMetadata, 'pages') as number) > 1, true, 'multi-frame GIF reports animated metadata')
  assert.equal(field(gifMetadata, 'hasAlpha'), false)
  assert.equal(field(gifMetadata, 'depth'), 'uchar')
  assert.equal(field(gifMetadata, 'space'), 'srgb')
  assert.equal(result.contract.gif.rawLength, 2 * 2 * 4)

  const jpegMetadata = result.contract.jpeg.metadata as Record<string, unknown>
  assert.equal(field(jpegMetadata, 'format'), 'jpeg')
  assert.equal(field(jpegMetadata, 'width'), 3)
  assert.equal(field(jpegMetadata, 'height'), 2)
  assert.equal(field(jpegMetadata, 'pages'), 1)
  assert.equal(field(jpegMetadata, 'hasAlpha'), false)
  assert.equal(field(jpegMetadata, 'depth'), 'uchar')
  assert.equal(field(jpegMetadata, 'space'), 'srgb')
  assert.equal(result.contract.jpeg.rawLength, 3 * 2 * 4)

  // ---- Corrupt bytes still error; unsupported operations stay distinct.
  assert.equal(result.contract.corrupt.metadata.code, 'SHARP_INVALID_IMAGE')
  assert.equal(result.contract.corrupt.raw.code, 'SHARP_INVALID_IMAGE')
  assert.equal(unsupported('rotateAngle').code, 'SHARP_UNSUPPORTED_OPERATION')
  assert.match(unsupported('rotateAngle').message, /sharp\.rotate\(angle\)/)
  assert.equal(unsupported('resizeFit').code, 'SHARP_UNSUPPORTED_OPERATION')
  assert.match(unsupported('resizeFit').message, /sharp\.resize\(fit\)/)
  assert.equal(unsupported('noOutput').code, 'SHARP_UNSUPPORTED_OPERATION')
  assert.match(unsupported('noOutput').message, /sharp\.toBuffer/)
  assert.equal(unsupported('webpFallback').code, 'SHARP_UNSUPPORTED_OPERATION')
  assert.match(unsupported('webpFallback').message, /sharp\.webp/)
  assert.match(unsupported('webpFallback').message, /image\/webp/)
  assert.equal(result.contract.encodeJpeg.error, undefined)
  assert.equal(result.contract.encodeJpeg.info?.width, 1)
  assert.equal(result.contract.encodeJpeg.info?.height, 1)
  assert.ok((result.contract.encodeJpeg.bytes ?? 0) > 0)

  // ---- The runtime table reproduces the reported defect: every valid image
  //      is folded into INVALID_IMAGE by attachment-local's admission.
  for (const name of ['png', 'gif', 'jpeg', 'corrupt'] as const) {
    const runtime = result.integration.runtime[name]
    assert.equal(runtime.error?.name, 'AttachmentError', `runtime ${name} should fail`)
    assert.equal(runtime.error?.code, 'INVALID_IMAGE', `runtime ${name} should report INVALID_IMAGE`)
    assert.equal(runtime.error?.message, 'Unsupported or malformed image data.')
  }

  // The packed image must not carry the native package the shim replaces.
  const imageEntries = spawnSync('tar', ['tzf', join(imageDirectory, 'image.tar.gz')], { encoding: 'utf8' })
  assert.equal(imageEntries.status, 0)
  assert.doesNotMatch(imageEntries.stdout, /node_modules\/sharp\//)
})
