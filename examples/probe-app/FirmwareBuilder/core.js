// SPDX-License-Identifier: MIT
import { MemFS, runWasi } from "./wasi-mem.js"
export function loadBundle(buf) {
  const u = new Uint8Array(buf), n = new DataView(buf).getUint32(0, true), head = JSON.parse(new TextDecoder().decode(u.subarray(4, 4 + n))), base = 4 + n
  const fs = new MemFS(); for (const d of head.dirs) fs.mkdirp(d)
  for (const [p, off, len] of head.files) fs.put(p, u.subarray(base + off, base + off + len))
  return { fs, jobs: head.jobs }
}
export function runJob(fs, j, cc1, as) {
  const now = () => performance.now(); const t0 = now()
  const a = runWasi(cc1, fs, ["cc1", ...j.cc1], { PWD: j.cwd }); const t1 = now()
  const r = { n: j.n, src: j.src, cc1Exit: a.code, cc1Ms: Math.round(t1 - t0), cc1PeakMiB: +(a.peakBytes / 1048576).toFixed(1), trap: a.trap, err: a.stderr.slice(0, 400) }
  if (a.code !== 0) return { r }
  const b = runWasi(as, fs, ["as", ...j.as], { PWD: j.cwd }); r.asExit = b.code; r.asMs = Math.round(now() - t1); r.asPeakMiB = +(b.peakBytes / 1048576).toFixed(1)
  if (b.code !== 0) { r.err = b.stderr.slice(0, 400); r.trap = b.trap; return { r } }
  const obj = fs.get(j.o).slice(); fs.files.delete(j.s); fs.files.delete(j.o)
  return { r, obj }
}

// Link stage: rebuild the project archives from freshly compiled objects with wasm ar, then run wasm ld.
export function loadLink(buf, fs) {
  const u = new Uint8Array(buf), n = new DataView(buf).getUint32(0, true), head = JSON.parse(new TextDecoder().decode(u.subarray(4, 4 + n))), base = 4 + n
  for (const [p, off, len] of head.files) fs.put(p, u.subarray(base + off, base + off + len))
  return head
}
export function linkFirmware(fs, plan, objs, ar, ld, log) {
  const now = () => performance.now(); const out = { arMs: 0, archives: 0 }
  fs.mkdirp("/out"); fs.mkdirp(plan.cwd)
  for (const [path, n] of Object.entries(plan.direct)) fs.put(path, objs.get(n))
  plan.archives.forEach((a, k) => {
    const files = a.members.map((m, i) => { if (m.pre) return m.pre; const p = `/ar/${k}/${i}/${m.name}`; fs.put(p, objs.get(m.job)); return p })
    fs.mkdirp(a.path.slice(0, a.path.lastIndexOf("/"))); fs.files.delete(fs.norm(a.path))
    const t = now(); const r = runWasi(ar, fs, ["ar", "qcs", a.path, ...files], { PWD: plan.cwd }); out.arMs += now() - t
    if (r.code !== 0) throw new Error(`ar failed for ${a.path}: exit ${r.code} ${r.trap || ""} ${r.stderr.slice(0, 300)}`)
    out.archives++
  })
  out.arMs = Math.round(out.arMs); if (log) log(`rebuilt ${out.archives} archives in ${out.arMs} ms`)
  const t = now(); const r = runWasi(ld, fs, ["ld", ...plan.ldArgs], { PWD: plan.cwd })
  out.ldMs = Math.round(now() - t); out.ldExit = r.code; out.ldPeakMiB = +(r.peakBytes / 1048576).toFixed(1); out.ldErr = r.stderr.slice(0, 600); out.trap = r.trap
  const elf = r.code === 0 ? fs.get("/out/agent_s3.elf") : undefined
  return { out, elf }
}
