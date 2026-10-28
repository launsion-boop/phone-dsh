// SPDX-License-Identifier: MIT
/**
 * Worker-side `sharp` subset for the phone image path.
 *
 * DSH's attachment-local decodes rasters through `createLazyRequire('sharp')`,
 * and the pinned webworker runtime replaces `sharp` with a
 * `notImplementedFail` stub because native libvips has no browser counterpart.
 * The stub makes every valid PNG/JPEG/GIF/WebP look malformed: attachment
 * admission folds the stub's refusal into `INVALID_IMAGE`. This module is the
 * replacement registered on the same module-replacement seam
 * (`static-modules.ts`), so `require('sharp')` resolves to a real, pure-Worker
 * implementation instead.
 *
 * Implemented (the subset DSH's bundled attachment code reaches):
 *   - `sharp(data, { failOn, limitInputPixels })`
 *   - `.metadata()` from container headers only (`sharp-metadata.ts`)
 *   - `.raw().toBuffer()` through `createImageBitmap` + `OffscreenCanvas`
 *   - `.rotate()`, `.toColourspace('srgb')`, `.resize({ fit: 'inside' })`,
 *     `.clone()` and `.jpeg()/.webp()/.png()` + `.toBuffer()` for the
 *     normalization/request-image ladder
 *
 * Everything else throws {@link SharpUnsupportedOperationError} naming the
 * operation. It is never converted into `INVALID_IMAGE` here: a backend gap is
 * a different fact from malformed bytes, and the error carries
 * `code: 'SHARP_UNSUPPORTED_OPERATION'`.
 *
 * Orientation: EXIF orientations 2-8 are applied with a canvas transform when
 * `.rotate()` runs. WebKit's `createImageBitmap` orientation-option behaviour
 * is NOT_VERIFIED on device; the code asks for `imageOrientation: 'none'` so
 * the manual transform is the only rotation applied.
 * @module @phone-dsh/dsh-worker-entry/sharp-shim
 */
import {
  SharpInputError,
  SharpUnsupportedOperationError,
} from './sharp-errors.ts'
import { parseImageMetadata, type SharpMetadata, type SharpMetadataOptions } from './sharp-metadata.ts'
import { stripJpegMetadataSegments } from './sharp-jpeg.ts'
import { SHARP_SHIM_MARKER } from './sharp-marker.ts'

/** Options DSH passes to the sharp constructor. */
export interface SharpInputOptions extends SharpMetadataOptions {
  /** libvips' decode strictness; accepted for call compatibility. */
  failOn?: 'none' | 'truncated' | 'error' | 'warning'
}

/** Resize options used by DSH's normalization and request-image pipelines. */
export interface SharpResizeOptions {
  width?: number
  height?: number
  fit?: 'inside' | 'cover' | 'contain' | 'fill' | 'outside'
  withoutEnlargement?: boolean
  withoutReduction?: boolean
}

/** Encoder options used by DSH's quality ladder. */
export interface SharpEncodeOptions {
  quality?: number
  effort?: number
  lossless?: boolean
  progressive?: boolean
}

/** `toBuffer({ resolveWithObject: true })` metadata. */
export interface SharpOutputInfo {
  width: number
  height: number
  channels: number
  size: number
}

/** Encoded bytes plus their facts. */
export interface SharpEncodedOutput {
  data: Uint8Array
  info: SharpOutputInfo
}

/** Options for `.toBuffer()`. */
export interface SharpToBufferOptions {
  resolveWithObject?: boolean
}

/** The sharp-shaped surface DSH's attachment code calls on one image. */
export interface SharpPipeline {
  metadata(): Promise<SharpMetadata>
  raw(): SharpPipeline
  rotate(angle?: number): SharpPipeline
  toColourspace(space: string): SharpPipeline
  resize(options: SharpResizeOptions): SharpPipeline
  clone(): SharpPipeline
  jpeg(options?: SharpEncodeOptions): SharpPipeline
  webp(options?: SharpEncodeOptions): SharpPipeline
  png(options?: SharpEncodeOptions): SharpPipeline
  toBuffer(options?: SharpToBufferOptions): Promise<Uint8Array | SharpEncodedOutput>
}

/** Callable sharp default export as the Worker's CommonJS `require` returns it. */
export interface SharpFactory {
  (input: Uint8Array | ArrayBuffer | ArrayBufferView, options?: SharpInputOptions): SharpPipeline
}

type OutputFormat = 'raw' | 'jpeg' | 'webp' | 'png'

interface PipelineState {
  readonly bytes: Uint8Array
  readonly options: SharpInputOptions
  readonly rotate: boolean
  readonly colourspace: string | undefined
  readonly resize: SharpResizeOptions | undefined
  readonly output: OutputFormat | undefined
  readonly encode: SharpEncodeOptions
}

/** Browser imaging primitives the shim needs, read at call time. */
interface ImagingPlatform {
  readonly createImageBitmap: (source: Blob, options?: { imageOrientation?: 'none' | 'from-image' | 'flipY' }) => Promise<ImageBitmap>
  readonly OffscreenCanvas: new (width: number, height: number) => OffscreenCanvas
}

function imagingPlatform(operation: string): ImagingPlatform {
  const scope = globalThis as unknown as Partial<ImagingPlatform>
  if (typeof scope.createImageBitmap !== 'function' || typeof scope.OffscreenCanvas !== 'function') {
    throw new SharpUnsupportedOperationError(
      operation,
      'this Worker runtime has no createImageBitmap/OffscreenCanvas imaging primitives',
    )
  }
  // WebKit's WorkerGlobalScope methods come from a WebIDL interface: calling
  // an extracted reference makes `this` the platform object and throws
  // "Can only call WorkerGlobalScope.createImageBitmap on instances of
  // WorkerGlobalScope". Bind before storing it, so every call site keeps the
  // Worker scope as the receiver.
  return {
    createImageBitmap: scope.createImageBitmap.bind(scope),
    OffscreenCanvas: scope.OffscreenCanvas,
  }
}

function inputBytes(input: unknown): Uint8Array {
  if (input instanceof Uint8Array) return input
  if (input instanceof ArrayBuffer) return new Uint8Array(input)
  if (ArrayBuffer.isView(input)) return new Uint8Array(input.buffer, input.byteOffset, input.byteLength)
  throw new SharpUnsupportedOperationError(
    'sharp(input)',
    'only encoded image bytes are supported; path and stream inputs need a filesystem the Worker shim does not own',
  )
}

function blobBytes(bytes: Uint8Array): Blob {
  return new Blob([bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer])
}

function closeBitmap(bitmap: ImageBitmap): void {
  const close = (bitmap as { close?: () => void }).close
  if (typeof close === 'function') close.call(bitmap)
}

function contextOf(canvas: OffscreenCanvas, operation: string): OffscreenCanvasRenderingContext2D {
  const context = canvas.getContext('2d')
  if (context === null) throw new SharpUnsupportedOperationError(operation, 'OffscreenCanvas did not provide a 2d context')
  return context
}

/** Decode the first frame of one encoded image into an ImageBitmap. */
async function decodeBitmap(bytes: Uint8Array, operation: string): Promise<ImageBitmap> {
  const platform = imagingPlatform(operation)
  try {
    return await platform.createImageBitmap(blobBytes(bytes), { imageOrientation: 'none' })
  } catch (first) {
    // Some WebKit builds reject the options bag; retry without it. The only
    // consumer that would notice an orientation difference is `.rotate()`,
    // which is exercised separately from raw probes.
    try {
      return await platform.createImageBitmap(blobBytes(bytes))
    } catch (second) {
      throw new SharpInputError(
        `raster decode failed: ${second instanceof Error ? second.message : String(second)}`,
        { cause: first },
      )
    }
  }
}

/** Draw the decoded raster with its EXIF orientation applied. */
function orientedCanvas(
  bitmap: ImageBitmap,
  orientation: number,
  platform: ImagingPlatform,
  operation: string,
): { canvas: OffscreenCanvas; width: number; height: number } {
  const sourceWidth = bitmap.width
  const sourceHeight = bitmap.height
  if (orientation < 2 || orientation > 8) return { canvas: drawScaled(bitmap, sourceWidth, sourceHeight, platform, operation), width: sourceWidth, height: sourceHeight }
  const swapped = orientation >= 5
  const width = swapped ? sourceHeight : sourceWidth
  const height = swapped ? sourceWidth : sourceHeight
  const canvas = new platform.OffscreenCanvas(width, height)
  const context = contextOf(canvas, operation)
  switch (orientation) {
    case 2: context.transform(-1, 0, 0, 1, sourceWidth, 0); break
    case 3: context.transform(-1, 0, 0, -1, sourceWidth, sourceHeight); break
    case 4: context.transform(1, 0, 0, -1, 0, sourceHeight); break
    case 5: context.transform(0, 1, 1, 0, 0, 0); break
    case 6: context.transform(0, 1, -1, 0, sourceHeight, 0); break
    case 7: context.transform(0, -1, -1, 0, sourceHeight, sourceWidth); break
    case 8: context.transform(0, -1, 1, 0, 0, sourceWidth); break
    default: break
  }
  context.drawImage(bitmap, 0, 0)
  return { canvas, width, height }
}

/** Draw one image source into a fresh canvas at an exact size. */
function drawScaled(
  source: CanvasImageSource,
  width: number,
  height: number,
  platform: ImagingPlatform,
  operation: string,
): OffscreenCanvas {
  const canvas = new platform.OffscreenCanvas(width, height)
  contextOf(canvas, operation).drawImage(source, 0, 0, width, height)
  return canvas
}

/** Target dimensions for the requested resize box, in perceived-orientation space. */
function targetDimensions(
  metadata: SharpMetadata,
  state: PipelineState,
): { width: number; height: number } {
  const transposed = state.rotate && metadata.orientation !== undefined && metadata.orientation >= 5
  const sourceWidth = transposed ? metadata.height : metadata.width
  const sourceHeight = transposed ? metadata.width : metadata.height
  const box = state.resize
  if (box === undefined) return { width: sourceWidth, height: sourceHeight }
  const maxWidth = box.width ?? Number.POSITIVE_INFINITY
  const maxHeight = box.height ?? Number.POSITIVE_INFINITY
  if (!Number.isFinite(maxWidth) && !Number.isFinite(maxHeight)) {
    throw new SharpUnsupportedOperationError('sharp.resize', 'resize needs a width, a height, or both')
  }
  let scale = Math.min(maxWidth / sourceWidth, maxHeight / sourceHeight)
  if (box.withoutEnlargement === true) scale = Math.min(scale, 1)
  if (box.withoutReduction === true) scale = Math.max(scale, 1)
  if (!Number.isFinite(scale) || scale <= 0) {
    throw new SharpUnsupportedOperationError('sharp.resize', 'the resize box does not describe a positive scale')
  }
  return {
    width: Math.max(1, Math.round(sourceWidth * scale)),
    height: Math.max(1, Math.round(sourceHeight * scale)),
  }
}

/** One immutable sharp-shaped pipeline over encoded bytes. */
class SharpPipelineImpl implements SharpPipeline {
  private readonly state: PipelineState

  constructor(state: PipelineState) {
    this.state = state
  }

  private with(patch: Partial<PipelineState>): SharpPipeline {
    return new SharpPipelineImpl({ ...this.state, ...patch })
  }

  async metadata(): Promise<SharpMetadata> {
    return parseImageMetadata(this.state.bytes, this.state.options)
  }

  raw(): SharpPipeline {
    return this.with({ output: 'raw' })
  }

  rotate(angle?: number): SharpPipeline {
    if (angle !== undefined && angle !== 0) {
      throw new SharpUnsupportedOperationError('sharp.rotate(angle)', 'only auto-orientation (no argument) is implemented')
    }
    return this.with({ rotate: true })
  }

  toColourspace(space: string): SharpPipeline {
    if (space !== 'srgb' && space !== 'rgb') {
      throw new SharpUnsupportedOperationError('sharp.toColourspace', `colour space "${space}" needs a libvips colour engine; only srgb/rgb are implemented`)
    }
    return this.with({ colourspace: space })
  }

  resize(options: SharpResizeOptions): SharpPipeline {
    if (options === null || typeof options !== 'object') {
      throw new SharpUnsupportedOperationError('sharp.resize', 'a resize options object is required')
    }
    if (options.fit !== undefined && options.fit !== 'inside') {
      throw new SharpUnsupportedOperationError('sharp.resize(fit)', `fit "${options.fit}" is not implemented; only inside is`)
    }
    for (const side of ['width', 'height'] as const) {
      const value = options[side]
      if (value !== undefined && (!Number.isFinite(value) || value <= 0)) {
        throw new SharpUnsupportedOperationError('sharp.resize', `resize ${side} must be a positive finite number`)
      }
    }
    return this.with({ resize: { ...options } })
  }

  clone(): SharpPipeline {
    return new SharpPipelineImpl({ ...this.state })
  }

  jpeg(options: SharpEncodeOptions = {}): SharpPipeline {
    return this.with({ output: 'jpeg', encode: { ...options } })
  }

  webp(options: SharpEncodeOptions = {}): SharpPipeline {
    return this.with({ output: 'webp', encode: { ...options } })
  }

  png(options: SharpEncodeOptions = {}): SharpPipeline {
    return this.with({ output: 'png', encode: { ...options } })
  }

  async toBuffer(options: SharpToBufferOptions = {}): Promise<Uint8Array | SharpEncodedOutput> {
    const output = this.state.output
    if (output === undefined) {
      throw new SharpUnsupportedOperationError(
        'sharp.toBuffer',
        'no output selected; the Worker shim implements .raw(), .jpeg(), .webp() and .png()',
      )
    }
    const metadata = parseImageMetadata(this.state.bytes, this.state.options)
    if (output === 'raw') {
      if (this.state.rotate || this.state.resize !== undefined) {
        throw new SharpUnsupportedOperationError(
          'sharp.raw().toBuffer()',
          'raw pixels after rotate/resize are not implemented; DSH only probes the unmodified raster',
        )
      }
      const data = await this.decodeRawPixels(metadata)
      if (options.resolveWithObject === true) {
        return {
          data,
          info: { width: metadata.width, height: metadata.height, channels: 4, size: data.byteLength },
        }
      }
      return data
    }
    const platform = imagingPlatform(`sharp.${output}`)
    const bitmap = await decodeBitmap(this.state.bytes, `sharp.${output}`)
    try {
      const oriented = this.state.rotate && metadata.orientation !== undefined
        ? orientedCanvas(bitmap, metadata.orientation, platform, `sharp.${output}`)
        : { canvas: drawScaled(bitmap, bitmap.width, bitmap.height, platform, `sharp.${output}`), width: bitmap.width, height: bitmap.height }
      const target = targetDimensions(metadata, this.state)
      const resized = oriented.width === target.width && oriented.height === target.height
        ? oriented.canvas
        : drawScaled(oriented.canvas, target.width, target.height, platform, `sharp.${output}`)
      const data = await encodeCanvas(resized, output, this.state.encode)
      if (options.resolveWithObject === true) {
        return {
          data,
          info: {
            width: target.width,
            height: target.height,
            channels: output === 'jpeg' ? 3 : 4,
            size: data.byteLength,
          },
        }
      }
      return data
    } finally {
      closeBitmap(bitmap)
    }
  }

  /** Decode the first frame at its stored dimensions. */
  private async decodeRawPixels(metadata: SharpMetadata): Promise<Uint8Array> {
    const platform = imagingPlatform('sharp.raw().toBuffer()')
    const bitmap = await decodeBitmap(this.state.bytes, 'sharp.raw().toBuffer()')
    try {
      const canvas = drawScaled(bitmap, metadata.width, metadata.height, platform, 'sharp.raw().toBuffer()')
      const context = contextOf(canvas, 'sharp.raw().toBuffer()')
      const image = context.getImageData(0, 0, metadata.width, metadata.height)
      // Copy out of the canvas so the returned buffer is independent of it.
      return new Uint8Array(image.data.buffer.slice(image.data.byteOffset, image.data.byteOffset + image.data.byteLength) as ArrayBuffer)
    } finally {
      closeBitmap(bitmap)
    }
  }
}

/** Encode one canvas through the platform's WebP/JPEG/PNG encoder. */
async function encodeCanvas(
  canvas: OffscreenCanvas,
  format: 'jpeg' | 'webp' | 'png',
  options: SharpEncodeOptions,
): Promise<Uint8Array> {
  const type = format === 'jpeg' ? 'image/jpeg' : format === 'webp' ? 'image/webp' : 'image/png'
  const quality = format === 'png' ? undefined : Math.min(1, Math.max(0.01, (options.quality ?? 80) / 100))
  const convertToBlob = (canvas as { convertToBlob?: (options: { type: string; quality?: number }) => Promise<Blob> }).convertToBlob
  if (typeof convertToBlob !== 'function') {
    throw new SharpUnsupportedOperationError(`sharp.${format}`, 'this Worker OffscreenCanvas has no convertToBlob() encoder')
  }
  const blob = await convertToBlob.call(canvas, {
    type,
    ...quality === undefined ? {} : { quality },
  })
  if (blob.type !== type) {
    throw new SharpUnsupportedOperationError(
      `sharp.${format}`,
      `this Worker's OffscreenCanvas cannot encode ${type} (it produced ${blob.type === '' ? 'an untyped blob' : blob.type})`,
    )
  }
  const encoded = new Uint8Array(await blob.arrayBuffer())
  // WebKit's JPEG encoder attaches APP1 Exif and APP13 Photoshop segments even
  // when the canvas has no metadata. DSH's normalization policy rejects those
  // bytes, so strip the policy-visible segments here; PNG/WebP containers are
  // passed through untouched.
  return format === 'jpeg' ? stripJpegMetadataSegments(encoded) : encoded
}

/**
 * Build the sharp-shaped callable the Worker module table serves for `sharp`.
 * @returns a memoizable factory whose parsed pipelines are immutable.
 */
export function createSharpModule(): SharpFactory {
  const sharp = (input: Uint8Array | ArrayBuffer | ArrayBufferView, options: SharpInputOptions = {}): SharpPipeline => (
    new SharpPipelineImpl({
      bytes: inputBytes(input),
      options: { ...options },
      rotate: false,
      colourspace: undefined,
      resize: undefined,
      output: undefined,
      encode: {},
    })
  )
  // Runtime identity marker: the bundle check and Worker diagnostics both read
  // it, and it keeps the marker string in the emitted bundle.
  Object.defineProperty(sharp, SHARP_SHIM_MARKER, { value: true, enumerable: false })
  return sharp
}

/**
 * The one default-export-compatible instance the Worker module table serves.
 *
 * `createLazyRequire('sharp')` calls the value returned by `require('sharp')`
 * directly (the runtime's stub instead returns `{ default }`), so this is a
 * plain function with no `__esModule` marker.
 */
export const sharpShim: SharpFactory = createSharpModule()
