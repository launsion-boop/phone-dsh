// SPDX-License-Identifier: MIT
/**
 * Minimal profile stub for the packed Worker image.
 *
 * `scripts/pack-image.mjs` records the shipped DSH profile template `web`,
 * whose bundle list is `["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"]`.
 * The image deliberately does not materialize the `dsh-web-app` application
 * bundle or its `web-runtime` host row, so app-boot initializes
 * `/dsh/home/profiles/web/package.json` from that template and then reports the
 * unreadable `@deepseek-ai/dsh-web-app` bundle as skipped on every boot. The
 * phone surface is `phone-surface`, mounted by the image's home patch. The
 * browser client roster is mounted as ordinary home-patch rows and contributes
 * its bundles to `window.__DSH_BOOT__`; it does not add a second host surface.
 *
 * This module supplies the smallest data overlay that keeps the boot clean:
 * a profile manifest whose bundle list names only the bundle the image does
 * carry. It is an overlay under `home/` — no `dsh-web-app` application package
 * is materialized, and no DSH source is patched or copied. Later overlays win, so
 * a deployment-supplied profile manifest still takes precedence when one is
 * applied after this one.
 *
 * The overlay is a gzip member holding one ustar file, the same envelope the
 * pinned runtime accepts for images and data overlays (`storage/image-gzip.ts`).
 * @module @phone-dsh/dsh-worker-entry/profile-overlay
 */

/** Shipped profile template the image records (`IMAGE_PROFILE` in pack-image). */
export const PHONE_IMAGE_PROFILE = 'web'

/**
 * Bundles the stub profile enables: the one bundle the image materializes.
 * The `web` template's second entry, `@deepseek-ai/dsh-web-app`, is the browser
 * application this deployment deliberately omits.
 */
export const PHONE_PROFILE_BUNDLES = ['@deepseek-ai/dsh-base'] as const

/** Image path of the profile manifest the stub supplies. */
export const PHONE_PROFILE_MANIFEST_PATH = `home/profiles/${PHONE_IMAGE_PROFILE}/package.json`

const encoder = new TextEncoder()
const TAR_BLOCK = 512

/**
 * The profile manifest body, matching the shape app-boot's `initProfile`
 * writes (only the bundle list differs).
 * @returns UTF-8 JSON.
 */
export function phoneProfileManifest(): string {
  return `${JSON.stringify({
    name: `dsh-profile-${PHONE_IMAGE_PROFILE}`,
    private: true,
    dependencies: {},
    dsh: { profile: { bundles: [...PHONE_PROFILE_BUNDLES] } },
  }, null, 2)}\n`
}

/** Write one zero-padded octal field into a ustar header. */
function writeOctal(header: Uint8Array, offset: number, length: number, value: number): void {
  header.set(encoder.encode(value.toString(8).padStart(length - 1, '0')), offset)
}

/**
 * Pack the stub as one uncompressed ustar archive, following the pinned
 * runtime's own writer (`storage/tar.ts`): ustar magic, mode 0644, mtime 0,
 * one name field (the stub path always fits it), two zero blocks of terminator.
 * @param path - Archive entry path (must fit the ustar name field).
 * @param bytes - Entry content.
 * @returns The archive bytes.
 */
export function packPhoneProfileTar(path: string, bytes: Uint8Array): Uint8Array {
  if (encoder.encode(path).length > 100) {
    throw new Error(`worker entry: profile stub path does not fit the ustar name field: ${path}`)
  }
  const header = new Uint8Array(TAR_BLOCK)
  header.set(encoder.encode(path), 0)
  writeOctal(header, 100, 8, 0o644)
  writeOctal(header, 108, 8, 0)
  writeOctal(header, 116, 8, 0)
  writeOctal(header, 124, 12, bytes.byteLength)
  writeOctal(header, 136, 12, 0)
  header.fill(0x20, 148, 156)
  header[156] = 0x30
  header.set(encoder.encode('ustar'), 257)
  header.set(encoder.encode('00'), 263)
  let checksum = 0
  for (const byte of header) checksum += byte
  header.set(encoder.encode(checksum.toString(8).padStart(6, '0')), 148)
  header[154] = 0
  header[155] = 0x20

  const padding = bytes.byteLength % TAR_BLOCK
  const body = padding === 0 ? new Uint8Array(0) : new Uint8Array(TAR_BLOCK - padding)
  const archive = new Uint8Array(TAR_BLOCK + bytes.byteLength + body.byteLength + TAR_BLOCK * 2)
  archive.set(header, 0)
  archive.set(bytes, TAR_BLOCK)
  archive.set(body, TAR_BLOCK + bytes.byteLength)
  return archive
}

/**
 * Build the uncompressed overlay the Worker host applies before boot.
 * @returns The ustar archive holding only the profile manifest.
 */
export function packPhoneProfileOverlay(): Uint8Array {
  return packPhoneProfileTar(PHONE_PROFILE_MANIFEST_PATH, encoder.encode(phoneProfileManifest()))
}

/**
 * Wrap the overlay in the gzip member the runtime's `readImage` requires.
 *
 * `CompressionStream` is part of the same platform family as the
 * `DecompressionStream` the runtime already uses unconditionally to inflate the
 * image, so an engine that can boot the image can build this overlay.
 * @returns The gzip-compressed overlay bytes.
 */
export async function createPhoneProfileOverlay(): Promise<Uint8Array> {
  const body = new Response(packPhoneProfileOverlay() as unknown as BodyInit).body
  if (body === null) throw new Error('worker entry: profile stub overlay produced no readable body')
  const compressed = body.pipeThrough(
    new CompressionStream('gzip') as unknown as TransformStream<Uint8Array, Uint8Array>,
  )
  return new Uint8Array(await new Response(compressed).arrayBuffer())
}
