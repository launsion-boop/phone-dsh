// SPDX-License-Identifier: MIT
/**
 * Minimal `createImageBitmap` / `OffscreenCanvas` stand-ins for the Node test.
 *
 * The Worker shim decodes pixels exclusively through the Worker platform's
 * imaging primitives. Node has neither, so the regression harness installs
 * these deterministic stand-ins: container headers are parsed with the same
 * pure-TypeScript inspector the shim uses (so golden-vector dimensions are
 * real), canvas pixel contents are zeroed RGBA, and `convertToBlob` emits
 * structurally valid containers at the canvas dimensions. WebP encoding falls
 * back to PNG exactly as a browser without a WebP encoder does, which is how
 * the test reaches the shim's loud unsupported-operation error.
 *
 * This fixture is a test double for the platform, not for the shim.
 * @module @phone-dsh/dsh-plugins/tests/fixtures/fake-image-platform
 */
import { parseImageMetadata } from '../../worker-entry/src/sharp-metadata.ts'

interface FakeContext {
  drawImage: (...args: unknown[]) => void
  getImageData: (x: number, y: number, width: number, height: number) => { data: Uint8ClampedArray; width: number; height: number }
  transform: (...args: number[]) => void
  save: () => void
  restore: () => void
}

interface FakeBlob {
  type: string
  arrayBuffer(): Promise<ArrayBuffer>
}

function pngBytes(width: number, height: number): Uint8Array {
  const chunk = new Uint8Array(8 + 13 + 4)
  const chunkView = new DataView(chunk.buffer)
  chunkView.setUint32(0, 13)
  chunk.set([0x49, 0x48, 0x44, 0x52], 4)
  chunkView.setUint32(8, width)
  chunkView.setUint32(12, height)
  chunk[16] = 8
  chunk[17] = 6
  const iend = Uint8Array.from([0, 0, 0, 0, 0x49, 0x45, 0x4e, 0x44, 0, 0, 0, 0])
  const out = new Uint8Array(8 + chunk.length + iend.length)
  out.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 0)
  out.set(chunk, 8)
  out.set(iend, 8 + chunk.length)
  return out
}

function jpegBytes(width: number, height: number): Uint8Array {
  const components = 3
  const length = 8 + components * 3
  const out: number[] = [0xff, 0xd8, 0xff, 0xc0, (length >> 8) & 0xff, length & 0xff, 8, (height >> 8) & 0xff, height & 0xff, (width >> 8) & 0xff, width & 0xff, components]
  for (let index = 0; index < components; index += 1) out.push(index + 1, 0x11, 0)
  out.push(0xff, 0xd9)
  return Uint8Array.from(out)
}

function blobOf(type: string, bytes: Uint8Array): FakeBlob {
  const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer
  return { type, arrayBuffer: async () => buffer }
}

class FakeOffscreenCanvas {
  readonly width: number
  readonly height: number

  constructor(width: number, height: number) {
    this.width = width
    this.height = height
  }

  getContext(kind: string): FakeContext | null {
    if (kind !== '2d') return null
    return {
      drawImage: () => {},
      transform: () => {},
      save: () => {},
      restore: () => {},
      getImageData: (_x, _y, requestedWidth, requestedHeight) => ({
        data: new Uint8ClampedArray(requestedWidth * requestedHeight * 4),
        width: requestedWidth,
        height: requestedHeight,
      }),
    }
  }

  async convertToBlob(options: { type?: string } = {}): Promise<FakeBlob> {
    const requested = options.type ?? 'image/png'
    if (requested === 'image/jpeg') return blobOf('image/jpeg', jpegBytes(this.width, this.height))
    if (requested === 'image/webp') {
      // Browsers without a WebP encoder fall back to the PNG serializer; the
      // returned blob keeps the actual type, which the shim must not paper
      // over as WebP.
      return blobOf('image/png', pngBytes(this.width, this.height))
    }
    return blobOf('image/png', pngBytes(this.width, this.height))
  }
}

/**
 * Install the fake Worker imaging primitives on the global scope.
 * @returns the canvas class installed, for callers that want to restore.
 */
export function installFakeImagePlatform(): void {
  const scope = globalThis as unknown as {
    createImageBitmap: (source: FakeBlob) => Promise<{ width: number; height: number; close: () => void }>
    OffscreenCanvas: typeof FakeOffscreenCanvas
  }
  // A real function, not an arrow: WebKit rejects an extracted method because
  // `this` is no longer the WorkerGlobalScope. Keeping the receiver check here
  // makes the Node regression fail the same way the real Worker does.
  scope.createImageBitmap = async function createImageBitmap(this: unknown, source: FakeBlob) {
    if (this !== scope) {
      throw new TypeError(
        'Can only call WorkerGlobalScope.createImageBitmap on instances of WorkerGlobalScope',
      )
    }
    const bytes = new Uint8Array(await source.arrayBuffer())
    const metadata = parseImageMetadata(bytes, { limitInputPixels: false })
    return {
      width: metadata.width,
      height: metadata.height,
      close: () => {},
    }
  }
  scope.OffscreenCanvas = FakeOffscreenCanvas
}
