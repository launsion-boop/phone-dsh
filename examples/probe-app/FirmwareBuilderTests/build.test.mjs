// SPDX-License-Identifier: MIT
// End-to-end check of the builder runtime against the staged artifact pack:
// compile every project source, rebuild the archives, link, write the image and
// compare both digests with the reference build recorded in manifest.json.
// SKIPs when the (untracked) pack is not staged in ../Bundle/firmware-builder.
import test from "node:test"
import assert from "node:assert/strict"
import { createHash } from "node:crypto"
import { existsSync, readFileSync } from "node:fs"
import { loadBundle, runJob, loadLink, linkFirmware } from "../FirmwareBuilder/core.js"
import { MemFS } from "../FirmwareBuilder/wasi-mem.js"
import { elf2image } from "../FirmwareBuilder/elf2image.js"
import { sha256, hex } from "../FirmwareBuilder/sha256.js"

const pack = new URL("../Bundle/firmware-builder/", import.meta.url)
const have = existsSync(new URL("manifest.json", pack))
const ab = n => { const b = readFileSync(new URL(n, pack)); return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) }
const nodeSha = b => createHash("sha256").update(b).digest("hex")

test("sha256 matches node:crypto on block-boundary lengths", () => {
  for (const n of [0, 1, 55, 56, 63, 64, 65, 119, 120, 1000, 65537]) {
    const d = new Uint8Array(n).map((_, i) => (i * 31 + n) & 255)
    assert.equal(hex(sha256(d)), nodeSha(d), `length ${n}`)
  }
})

test("elf2image rejects input that is not a 32-bit little-endian ELF", () => {
  assert.throws(() => elf2image(new Uint8Array(64), new Uint8Array(32)), /not a 32-bit little-endian ELF/)
})

test("pack builds the reference firmware byte for byte", { skip: have ? false : "artifact pack not staged", timeout: 600_000 }, async () => {
  const manifest = JSON.parse(readFileSync(new URL("manifest.json", pack), "utf8"))
  for (const [name, f] of Object.entries(manifest.files)) assert.equal(nodeSha(readFileSync(new URL(name, pack))), f.sha256, `${name} sha256`)
  const [cc1, as, ar, ld] = await Promise.all(["cc1.wasm", "as.wasm", "ar.wasm", "ld.wasm"].map(n => WebAssembly.compile(ab(n))))
  const { fs, jobs } = loadBundle(ab("project.bin")); const objs = new Map()
  for (const j of jobs) { const { r, obj } = runJob(fs, j, cc1, as); assert.ok(obj, `compile ${r.src}: ${r.err || r.trap}`); objs.set(j.n, obj) }
  const linkFs = new MemFS(); const { out, elf } = linkFirmware(linkFs, loadLink(ab("sdk.bin"), linkFs), objs, ar, ld)
  assert.equal(out.ldExit, 0, out.ldErr)
  const elfSha = sha256(elf); assert.equal(hex(elfSha), manifest.reference.elf_sha256)
  const r = elf2image(elf, elfSha); r.image.set(sha256(r.image.subarray(0, r.bodyLength)), r.bodyLength)
  assert.equal(hex(sha256(r.image)), manifest.reference.image_sha256)
})
