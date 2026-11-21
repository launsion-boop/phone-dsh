// SPDX-License-Identifier: MIT
// One worker script, three roles: compile one source (cc1 or cc1plus, then as), or rebuild the
// project archives, link (ar + ld) and write the flashable image (elf2image).
import { loadBundle, runJob, loadLink, linkFirmware } from "./core.js"
import { MemFS } from "./wasi-mem.js"
import { elf2image } from "./elf2image.js"
import { sha256, hex } from "./sha256.js"
import { applyOverrides, decodeOverrides, OverrideError } from "./overrides.js"
const bytes = u => fetch(u).then(r => { if (!r.ok) throw new Error(`${u}: HTTP ${r.status}`); return r.arrayBuffer() })
const say = (type, data, transfer) => self.postMessage({ type, ...data }, transfer || [])
let st
self.onmessage = async ({ data }) => {
  try {
    if (data.cmd === "init") {
      const project = await bytes(data.project); const { fs, jobs, paths } = loadBundle(project)
      // spec xiaozhi-firmware.md §5: overrides land after loadBundle and before the first compile job.
      if (data.overrides && Object.keys(data.overrides).length) applyOverrides(fs, data.sourcesRoot, paths, decodeOverrides(data.overrides))
      const tools = new Set(jobs.map(j => j.tool || "cc1")); tools.add("as")
      const names = [...tools], bins = await Promise.all(names.map(n => bytes(`artifacts/${n}.wasm`)))
      const t = performance.now(); const mods = Object.fromEntries(await Promise.all(names.map(async (n, i) => [n, await WebAssembly.compile(bins[i])])))
      st = { fs, jobs: new Map(jobs.map(j => [j.n, j])), cc1: mods.cc1, cc1plus: mods.cc1plus, as: mods.as }
      say("ready", { jobs: jobs.map(j => j.n), compileMs: Math.round(performance.now() - t) })
    } else if (data.cmd === "job") {
      const { r, obj } = runJob(st.fs, st.jobs.get(data.n), st.cc1, st.as, st.cc1plus); const buf = obj ? obj.buffer : null
      say("job", { r, obj: buf }, buf ? [buf] : [])
    } else if (data.cmd === "link") {
      const [sdk, arBytes, ldBytes] = await Promise.all(["artifacts/sdk.bin", "artifacts/ar.wasm", "artifacts/ld.wasm"].map(bytes))
      const ar = await WebAssembly.compile(arBytes), ld = await WebAssembly.compile(ldBytes)
      const fs = new MemFS(); const plan = loadLink(sdk, fs); const objs = new Map(data.objs.map(([n, b]) => [n, new Uint8Array(b)]))
      const { out, elf } = linkFirmware(fs, plan, objs, ar, ld, m => say("log", { msg: m }))
      if (!elf) { say("linked", { out }); return }
      const t = performance.now(); const elfSha = sha256(elf); const r = elf2image(elf, elfSha, { chip: plan.chip || "esp32s3" })
      r.image.set(sha256(r.image.subarray(0, r.bodyLength)), r.bodyLength)
      out.imageMs = Math.round(performance.now() - t); out.elfBytes = elf.length; out.elfSha256 = hex(elfSha); out.imageBytes = r.image.length; out.imageSha256 = hex(sha256(r.image))
      say("linked", { out, image: r.image.buffer }, [r.image.buffer])
    }
  } catch (e) { say("fatal", e instanceof OverrideError ? { msg: e.message, code: e.code, path: e.path } : { msg: String(e && e.stack || e) }) }
}
