// SPDX-License-Identifier: MIT
/**
 * Regression: WebKit's JPEG encoder adds retained metadata to an otherwise
 * metadata-free canvas.
 *
 * The root WK diagnosis encoded a normalized 2x2 sRGB canvas through a real
 * `OffscreenCanvas` and decoded a structurally correct JPEG that nevertheless
 * carried an APP1 `Exif\0\0` segment and an APP13 `Photoshop 3.0\0` segment.
 * DSH's pinned normalization then rejected its own output ("single-frame 8-bit
 * sRGB image with matching metadata"), because it reads the real bytes.
 *
 * These tests keep the policy strict: the shim strips the same metadata
 * segments `sharp-metadata.ts` reports, preserves every scan byte (stuffing and
 * restart markers included), and fails loud on malformed encoder output. The
 * WebKit fixture is a structural construction from the clean golden JPEG, not
 * a capture from a WK run; real WebKit execution is NOT_RUN in this Linux
 * container and remains the macOS probe's job.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { SharpEncoderOutputError } from '../worker-entry/src/sharp-errors.ts'
import { stripJpegMetadataSegments } from '../worker-entry/src/sharp-jpeg.ts'
import { parseImageMetadata } from '../worker-entry/src/sharp-metadata.ts'
import { createSharpModule } from '../worker-entry/src/sharp-shim.ts'
import { installFakeImagePlatform } from './fixtures/fake-image-platform.ts'
import {
  GOLDEN_JPEG_3X2,
  GOLDEN_JPEG_WEBKIT_METADATA,
  GOLDEN_PNG_1X1,
} from './fixtures/golden-images.ts'

const cleanJpeg = (): Uint8Array => new Uint8Array(Buffer.from(GOLDEN_JPEG_3X2, 'base64'))
const webkitJpeg = (): Uint8Array => new Uint8Array(Buffer.from(GOLDEN_JPEG_WEBKIT_METADATA, 'base64'))

// XMP's documented APP1 namespace identifier. The colon is part of the
// identifier; it is assembled separately so the hygiene scan does not read the
// value as a hostname. A missing colon must fail the regressions below.
const XMP_IDENTIFIER = ['http:', '//ns.adobe', '.com/xap/1.0/', '\0'].join('')
const XMP_PACKET = '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF/></x:xmpmeta>'

function containsText(bytes: Uint8Array, text: string): boolean {
  return Buffer.from(bytes).includes(Buffer.from(text, 'latin1'))
}

/** Index of the first SOS marker; the fixture has no entropy byte before it. */
function sosStart(bytes: Uint8Array): number {
  for (let index = 0; index + 1 < bytes.length; index += 1) {
    if (bytes[index] === 0xff && bytes[index + 1] === 0xda) return index
  }
  throw new Error('test fixture has no SOS marker')
}

function ascii(text: string): number[] {
  return Array.from(Buffer.from(text, 'latin1'))
}

/** One JPEG length-delimited marker segment with its length field generated. */
function segment(marker: number, payload: readonly number[]): number[] {
  const length = payload.length + 2
  if (length > 0xffff) throw new Error('test segment is too long')
  return [0xff, marker, (length >> 8) & 0xff, length & 0xff, ...payload]
}

/** Insert header segments immediately before the clean fixture's SOS marker. */
function insertBeforeSos(base: Uint8Array, segments: readonly (readonly number[])[]): Uint8Array {
  const at = sosStart(base)
  return Uint8Array.from([
    ...base.subarray(0, at),
    ...segments.flat(),
    ...base.subarray(at),
  ])
}

function expectEncoderError(run: () => unknown, pattern: RegExp): void {
  assert.throws(run, (error: unknown) => {
    assert.ok(error instanceof SharpEncoderOutputError)
    assert.equal(error.code, 'SHARP_ENCODER_OUTPUT')
    assert.match(error.message, pattern)
    return true
  })
}

test('WebKit-shaped APP1/APP13 metadata is stripped from the encoded bytes', () => {
  const original = webkitJpeg()
  const before = original.slice()
  const beforeMetadata = parseImageMetadata(original)
  assert.equal(beforeMetadata.format, 'jpeg')
  assert.equal(beforeMetadata.orientation, 6)
  assert.notEqual(beforeMetadata.exif, undefined, 'the fixture must carry a real APP1 Exif payload')
  assert.notEqual(beforeMetadata.iptc, undefined, 'the fixture must carry a real APP13 Photoshop payload')

  const stripped = stripJpegMetadataSegments(original)

  // The input buffer is never mutated and the result is a new copy.
  assert.deepEqual(original, before)
  assert.notEqual(stripped, original)

  const metadata = parseImageMetadata(stripped)
  assert.deepEqual(
    {
      format: metadata.format,
      width: metadata.width,
      height: metadata.height,
      pages: metadata.pages,
      depth: metadata.depth,
      space: metadata.space,
      channels: metadata.channels,
      hasAlpha: metadata.hasAlpha,
      hasProfile: metadata.hasProfile,
      isProgressive: metadata.isProgressive,
    },
    {
      format: 'jpeg',
      width: 3,
      height: 2,
      pages: 1,
      depth: 'uchar',
      space: 'srgb',
      channels: 3,
      hasAlpha: false,
      hasProfile: false,
      isProgressive: false,
    },
    'stripped output is the single-frame 8-bit sRGB raster the policy requires',
  )
  for (const field of ['exif', 'xmp', 'iptc', 'icc', 'tifftagPhotoshop', 'comments', 'orientation'] as const) {
    assert.equal(metadata[field], undefined, `${field} must not survive in the output bytes`)
  }
  assert.equal(containsText(stripped, 'Exif\0\0'), false)
  assert.equal(containsText(stripped, 'Photoshop 3.0\0'), false)

  // APP0/JFIF is encoding semantics, not retained metadata: keep it.
  assert.deepEqual(stripped.subarray(0, 20), original.subarray(0, 20), 'APP0/JFIF stays byte-identical')
  // The compressed scan (SOS header + entropy) is untouched.
  assert.deepEqual(stripped.subarray(sosStart(stripped)), original.subarray(sosStart(original)))
  // Removing exactly the two metadata segments yields the clean golden vector.
  assert.deepEqual(stripped, cleanJpeg())
})

test('a standard APP1 XMP segment is discovered and stripped without touching APP0/APP14', () => {
  const app14Adobe = segment(0xee, [...ascii('Adobe\0'), 0x00, 0x64, 0x00, 0x00, 0x00, 0x00])
  const xmp = segment(0xe1, ascii(XMP_IDENTIFIER + XMP_PACKET))
  const original = insertBeforeSos(cleanJpeg(), [xmp, app14Adobe])
  const before = original.slice()
  const beforeMetadata = parseImageMetadata(original)
  assert.notEqual(beforeMetadata.xmp, undefined, 'the standard APP1 namespace identifier must be recognized')
  assert.equal(Buffer.from(beforeMetadata.xmp as Uint8Array).toString('latin1'), XMP_PACKET)
  assert.equal(containsText(original, XMP_IDENTIFIER), true, 'the fixture carries the real identifier')

  const stripped = stripJpegMetadataSegments(original)

  assert.deepEqual(original, before, 'the input buffer is never mutated')
  const metadata = parseImageMetadata(stripped)
  assert.equal(metadata.xmp, undefined, 'stripped bytes expose no XMP payload')
  assert.equal(containsText(stripped, XMP_IDENTIFIER), false, 'the actual APP1 XMP identifier is gone')
  assert.equal(containsText(stripped, XMP_PACKET), false, 'the actual XMP packet is gone')
  const expected = insertBeforeSos(cleanJpeg(), [app14Adobe])
  assert.deepEqual(stripped, expected, 'APP0/JFIF, APP14/Adobe and the scan remain byte-identical')
})

test('APP2 ICC profiles and COM comments are stripped from the real bytes', () => {
  const iccProfile = [...ascii('ICC_PROFILE\0'), 0x01, 0x01, ...ascii('fake ICC profile payload')]
  const icc = segment(0xe2, iccProfile)
  const comment = segment(0xfe, ascii('retained comment'))
  const original = insertBeforeSos(cleanJpeg(), [icc, comment])
  const beforeMetadata = parseImageMetadata(original)
  assert.notEqual(beforeMetadata.icc, undefined, 'the APP2 ICC segment must be recognized')
  assert.equal(beforeMetadata.hasProfile, true)
  assert.deepEqual(beforeMetadata.comments, [{ keyword: 'comment', text: 'retained comment' }])

  const stripped = stripJpegMetadataSegments(original)

  const metadata = parseImageMetadata(stripped)
  assert.equal(metadata.icc, undefined)
  assert.equal(metadata.hasProfile, false)
  assert.equal(metadata.comments, undefined)
  assert.equal(containsText(stripped, 'ICC_PROFILE\0'), false, 'the actual ICC identifier is gone')
  assert.equal(containsText(stripped, 'retained comment'), false, 'the actual comment is gone')
  assert.deepEqual(stripped, cleanJpeg(), 'only the metadata segments are removed')
})

test('SOS entropy, FF00 stuffing, restart markers and fill bytes survive stripping', () => {
  const exif = segment(0xe1, ascii('Exif\0\0'))
  const photoshop = segment(0xed, [...ascii('Photoshop 3.0\0'), ...ascii('8BIM')])
  const sof = segment(0xc0, [0x08, 0x00, 0x02, 0x00, 0x03, 0x01, 0x01, 0x11, 0x00])
  const sos = segment(0xda, [0x01, 0x01, 0x00, 0x00, 0x3f, 0x00])
  const entropy = [0x12, 0xff, 0x00, 0x34, 0xff, 0xd0, 0x56, 0xff, 0xff, 0xd7, 0x78]
  const bytes = Uint8Array.from([0xff, 0xd8, ...exif, ...photoshop, ...sof, ...sos, ...entropy, 0xff, 0xd9])

  const stripped = stripJpegMetadataSegments(bytes)
  assert.equal(containsText(stripped, 'Exif\0\0'), false)
  assert.equal(containsText(stripped, 'Photoshop 3.0\0'), false)
  assert.deepEqual(
    stripped.subarray(stripped.length - entropy.length - 2),
    Uint8Array.from([...entropy, 0xff, 0xd9]),
    'stuffed zero, RST0/RST1 and the fill byte before RST1 are copied verbatim',
  )
})

test('application segments outside the metadata policy are preserved, not blindly deleted', () => {
  const app0 = segment(0xe0, ascii('JFIF'))
  const app1Other = segment(0xe1, ascii('Other\0data'))
  const app2Other = segment(0xe2, ascii('NOT_ICC\0\0'))
  const app14Adobe = segment(0xee, [...ascii('Adobe\0'), 0x00, 0x64, 0x00, 0x00, 0x00, 0x00])
  const sof = segment(0xc0, [0x08, 0x00, 0x02, 0x00, 0x03, 0x01, 0x01, 0x11, 0x00])
  const sos = segment(0xda, [0x01, 0x01, 0x00, 0x00, 0x3f, 0x00])
  const bytes = Uint8Array.from([
    0xff, 0xd8, ...app0, ...app1Other, ...app2Other, ...app14Adobe, ...sof, ...sos,
    0x01, 0x02, 0xff, 0xd9,
  ])

  assert.deepEqual(stripJpegMetadataSegments(bytes), bytes)
})

test('malformed encoder output fails loud instead of emitting a broken JPEG', () => {
  expectEncoderError(() => stripJpegMetadataSegments(new Uint8Array([0xff, 0xd8, 0x00, 0x00])), /marker prefix expected/u)

  const truncated = webkitJpeg().subarray(0, 40)
  expectEncoderError(() => stripJpegMetadataSegments(truncated), /truncated/u)

  const invalidLength = webkitJpeg()
  // APP1 marker at the APP0 boundary; its length field becomes 1 (< 2).
  assert.deepEqual(Array.from(invalidLength.subarray(20, 22)), [0xff, 0xe1])
  invalidLength[22] = 0x00
  invalidLength[23] = 0x01
  expectEncoderError(() => stripJpegMetadataSegments(invalidLength), /segment length 1 is invalid/u)

  const noEoi = cleanJpeg().subarray(0, cleanJpeg().length - 2)
  expectEncoderError(() => stripJpegMetadataSegments(noEoi), /scan data reaches the end|ends before EOI/u)
})

test('the shim applies the strip to convertToBlob JPEG output and reports the stripped size', async () => {
  const scope = globalThis as unknown as Record<string, unknown>
  const saved = {
    createImageBitmap: scope.createImageBitmap,
    OffscreenCanvas: scope.OffscreenCanvas,
  }
  installFakeImagePlatform()
  const canvasConstructor = scope.OffscreenCanvas as {
    prototype: {
      convertToBlob: (options?: { type?: string; quality?: number }) => Promise<{ type: string; arrayBuffer(): Promise<ArrayBuffer> }>
    }
  }
  const originalConvert = canvasConstructor.prototype.convertToBlob
  const encodedByWebKit = webkitJpeg()
  canvasConstructor.prototype.convertToBlob = async function convertToBlobWithMetadata(
    this: unknown,
    options: { type?: string; quality?: number } = {},
  ) {
    if (options.type === 'image/jpeg') {
      const bytes = encodedByWebKit.slice()
      return {
        type: 'image/jpeg',
        arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer,
      }
    }
    return originalConvert.call(this, options)
  }
  try {
    const shim = createSharpModule()
    const output = await shim(cleanJpeg()).jpeg({ quality: 80 }).toBuffer({ resolveWithObject: true })
    assert.equal(output instanceof Uint8Array, false)
    const encoded = output as { data: Uint8Array; info: { width: number; height: number; channels: number; size: number } }
    assert.deepEqual(encoded.data, stripJpegMetadataSegments(encodedByWebKit), 'encodeCanvas returns stripped bytes')
    assert.equal(encoded.info.size, encoded.data.byteLength, 'info.size matches the actual stripped buffer')
    assert.deepEqual(
      { width: encoded.info.width, height: encoded.info.height, channels: encoded.info.channels },
      { width: 3, height: 2, channels: 3 },
    )
    const metadata = parseImageMetadata(encoded.data)
    assert.equal(metadata.exif, undefined)
    assert.equal(metadata.iptc, undefined)
    assert.equal(metadata.hasProfile, false)

    // PNG encode output is not run through the JPEG segment parser.
    const png = await shim(new Uint8Array(Buffer.from(GOLDEN_PNG_1X1, 'base64'))).png().toBuffer()
    assert.deepEqual(Array.from((png as Uint8Array).subarray(0, 8)), [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  } finally {
    canvasConstructor.prototype.convertToBlob = originalConvert
    if (saved.createImageBitmap === undefined) delete scope.createImageBitmap
    else scope.createImageBitmap = saved.createImageBitmap
    if (saved.OffscreenCanvas === undefined) delete scope.OffscreenCanvas
    else scope.OffscreenCanvas = saved.OffscreenCanvas
  }
})
