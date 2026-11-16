// SPDX-License-Identifier: MIT
// One worker script, three roles: compile one source (cc1 + as), or rebuild the
// project archives, link (ar + ld) and write the flashable image (elf2image).
import { loadBundle, runJob, loadLink, linkFirmware } from "./core.js"
import { MemFS } from "./wasi-mem.js"
import { elf2image } from "./elf2image.js"
import { sha256, hex } from "./sha256.js"
const bytes = u => fetch(u).then(r => { if (!r.ok) throw new Error(`${u}: HTTP ${r.status}`); return r.arrayBuffer() })
const say = (type, data, transfer) => self.postMessage({ type, ...data }, transfer || [])
let st
self.onmessage = async ({ data }) => {
  try {
    if (data.cmd === "init") {
      const [project, cc1Bytes, asBytes] = await Promise.all([data.project, "artifacts/cc1.wasm", "artifacts/as.wasm"].map(bytes))
      const t = performance.now(); const cc1 = await WebAssembly.compile(cc1Bytes), as = await WebAssembly.compile(asBytes)
      const { fs, jobs } = loadBundle(project); st = { fs, jobs: new Map(jobs.map(j => [j.n, j])), cc1, as }
      say("ready", { jobs: jobs.map(j => j.n), compileMs: Math.round(performance.now() - t) })
    } else if (data.cmd === "job") {
      const { r, obj } = runJob(st.fs, st.jobs.get(data.n), st.cc1, st.as); const buf = obj ? obj.buffer : null
      say("job", { r, obj: buf }, buf ? [buf] : [])
    } else if (data.cmd === "link") {
      const [sdk, arBytes, ldBytes] = await Promise.all(["artifacts/sdk.bin", "artifacts/ar.wasm", "artifacts/ld.wasm"].map(bytes))
      const ar = await WebAssembly.compile(arBytes), ld = await WebAssembly.compile(ldBytes)
      const fs = new MemFS(); const plan = loadLink(sdk, fs); const objs = new Map(data.objs.map(([n, b]) => [n, new Uint8Array(b)]))
      const { out, elf } = linkFirmware(fs, plan, objs, ar, ld, m => say("log", { msg: m }))
      if (!elf) { say("linked", { out }); return }
      const t = performance.now(); const elfSha = sha256(elf); const r = elf2image(elf, elfSha)
      r.image.set(sha256(r.image.subarray(0, r.bodyLength)), r.bodyLength)
      out.imageMs = Math.round(performance.now() - t); out.elfBytes = elf.length; out.elfSha256 = hex(elfSha); out.imageBytes = r.image.length; out.imageSha256 = hex(sha256(r.image))
      say("linked", { out, image: r.image.buffer }, [r.image.buffer])
    }
  } catch (e) { say("fatal", { msg: String(e && e.stack || e) }) }
}
