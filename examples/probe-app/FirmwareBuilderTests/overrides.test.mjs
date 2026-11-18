// SPDX-License-Identifier: MIT
// Source overrides (spec/device/v1/xiaozhi-firmware.md §5), driven through the real loadBundle and
// MemFS with a small synthetic project.bin: editable-path mapping, not_editable rejection, and that an
// override changes exactly the expected file while a no-override build leaves the file system untouched.
import test from "node:test"
import assert from "node:assert/strict"
import { loadBundle } from "../FirmwareBuilder/core.js"
import { editableFiles, mapOverrides, applyOverrides, decodeOverrides, validRelPath, normalizeRoot, OverrideError } from "../FirmwareBuilder/overrides.js"

const ROOT = "/root/xiaozhi-passport/xiaozhi-esp32/main"
const enc = s => new TextEncoder().encode(s)
const dec = b => new TextDecoder().decode(b)

// project.bin layout: u32le header length, JSON header {dirs, files:[[path, off, len]], jobs}, file bytes.
function projectBin(files) {
  const bodies = Object.entries(files).map(([p, s]) => [p, enc(s)]); let off = 0
  const head = { dirs: ["/root"], files: bodies.map(([p, b]) => { const e = [p, off, b.length]; off += b.length; return e }), jobs: [] }
  const h = enc(JSON.stringify(head)), out = new Uint8Array(4 + h.length + off)
  new DataView(out.buffer).setUint32(0, h.length, true); out.set(h, 4); let at = 4 + h.length
  for (const [, b] of bodies) { out.set(b, at); at += b.length }
  return out.buffer
}
const pack = {
  [`${ROOT}/application.cc`]: "int app;", [`${ROOT}/boards/c3/config.h`]: "#define X 1", [`${ROOT}/mainlike`]: "x",
  "/root/xiaozhi-passport/xiaozhi-esp32/components/lib.c": "int lib;", "/root/xiaozhi-passport/xiaozhi-esp32/main2/other.c": "int o;",
}
const snapshot = fs => JSON.stringify([...fs.files].map(([p, f]) => [p, dec(f.buf.subarray(0, f.len))]).sort())

test("editable files are exactly the project.bin files below sources_root + '/'", () => {
  const { paths } = loadBundle(projectBin(pack))
  const m = editableFiles(ROOT, paths)
  assert.deepEqual([...m.values()].sort(), ["application.cc", "boards/c3/config.h", "mainlike"])
  assert.equal(m.get(`${ROOT}/application.cc`), "application.cc")
  assert.equal(editableFiles(undefined, paths).size, 0, "a pack without sources_root has no editable files")
  assert.equal(editableFiles(ROOT + "/", paths).size, 3, "a trailing slash on the root is tolerated")
  assert.equal(editableFiles("main", paths).size, 0, "a relative root is not a root")
})

test("not_editable: unknown file, sibling directory, traversal, absolute, empty, and any override without sources_root", () => {
  const { paths } = loadBundle(projectBin(pack))
  const bad = ["nope.cc", "../components/lib.c", "/application.cc", "", "boards", "./application.cc", "a//b", "main2/other.c"]
  for (const rel of bad) {
    assert.throws(() => mapOverrides(ROOT, paths, { [rel]: enc("x") }), e => e instanceof OverrideError && e.code === "not_editable" && e.path === rel, JSON.stringify(rel))
  }
  assert.throws(() => mapOverrides(undefined, paths, { "application.cc": enc("x") }), e => e.code === "not_editable")
  // one bad path poisons the whole set: nothing is written
  const { fs } = loadBundle(projectBin(pack)), before = snapshot(fs)
  assert.throws(() => applyOverrides(fs, ROOT, paths, { "application.cc": enc("changed"), "nope.cc": enc("x") }), /not_editable: nope\.cc/)
  assert.equal(snapshot(fs), before)
})

test("an override changes exactly the expected file", () => {
  const { fs, paths } = loadBundle(projectBin(pack)), before = new Map([...fs.files].map(([p, f]) => [p, dec(f.buf.subarray(0, f.len))]))
  const mapped = applyOverrides(fs, ROOT, paths, { "boards/c3/config.h": enc("#define X 2") })
  assert.deepEqual(mapped.map(m => m.abs), [`${ROOT}/boards/c3/config.h`])
  const after = new Map([...fs.files].map(([p, f]) => [p, dec(f.buf.subarray(0, f.len))]))
  assert.deepEqual([...after.keys()].sort(), [...before.keys()].sort(), "no file added or removed")
  const changed = [...after].filter(([p, s]) => before.get(p) !== s).map(([p]) => p)
  assert.deepEqual(changed, [`${ROOT}/boards/c3/config.h`])
  assert.equal(after.get(`${ROOT}/boards/c3/config.h`), "#define X 2")
})

test("a build without overrides leaves the file system identical to loadBundle (the reference build)", () => {
  const a = loadBundle(projectBin(pack)), b = loadBundle(projectBin(pack))
  for (const none of [undefined, null, {}]) applyOverrides(b.fs, ROOT, b.paths, none)
  assert.equal(snapshot(b.fs), snapshot(a.fs))
  assert.deepEqual(b.jobs, a.jobs)
})

test("page overrides are base64 and decode to the same bytes; invalid relative paths are rejected", () => {
  const bytes = new Uint8Array([0, 1, 2, 250, 255, 128])
  const decoded = decodeOverrides({ "a.cc": Buffer.from(bytes).toString("base64"), "b.cc": "" })
  assert.deepEqual([...decoded["a.cc"]], [...bytes])
  assert.equal(decoded["b.cc"].length, 0)
  assert.equal(validRelPath("boards/c3/config.h"), true)
  for (const rel of ["", "/x", "../x", "a/../b", "a/./b", "a//b", "a\\b", "a/"]) assert.equal(validRelPath(rel), false, JSON.stringify(rel))
  assert.equal(normalizeRoot("/a/b/"), "/a/b")
  assert.equal(normalizeRoot("/"), null)
})
