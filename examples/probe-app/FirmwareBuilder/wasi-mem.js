// SPDX-License-Identifier: MIT
// Minimal in-memory WASI preview1 host: one preopen "/", lexical path resolution.
// Enough for GCC cc1/cc1plus and GNU as/ar/ld (their full import list is implemented or ENOSYS).
export class MemFS {
  constructor() { this.files = new Map(); this.dirs = new Set(["/"]); this.ino = new Map(); this.nextIno = 2 }
  norm(p) { const o = []; for (const s of p.split("/")) { if (s === "" || s === ".") continue; if (s === "..") o.pop(); else o.push(s) } return "/" + o.join("/") }
  mkdirp(p) { p = this.norm(p); while (p !== "/") { this.dirs.add(p); p = p.slice(0, p.lastIndexOf("/")) || "/" } }
  put(p, data) { p = this.norm(p); this.mkdirp(p.slice(0, p.lastIndexOf("/")) || "/"); this.files.set(p, { buf: data, len: data.length }) }
  get(p) { const f = this.files.get(this.norm(p)); return f ? f.buf.subarray(0, f.len) : undefined }
  inode(p) { let i = this.ino.get(p); if (!i) { i = this.nextIno++; this.ino.set(p, i) } return i }
}
const E = { BADF: 8, EXIST: 20, INVAL: 28, ISDIR: 31, NOENT: 44, NOSYS: 52, NOTDIR: 54, SPIPE: 70 }
class Exit extends Error { constructor(code) { super("exit " + code); this.code = code } }
export function runWasi(module, fs, argv, env) {
  const enc = new TextEncoder(), dec = new TextDecoder()
  let mem; const dv = () => new DataView(mem.buffer), u8 = () => new Uint8Array(mem.buffer)
  const fds = new Map([[0, { kind: "in" }], [1, { kind: "out", chunks: [] }], [2, { kind: "out", chunks: [] }], [3, { kind: "dir", path: "/" }]])
  let nextFd = 4, peak = 0
  const str = (p, l) => dec.decode(u8().subarray(p, p + l))
  const resolve = (fd, p, l) => { const d = fds.get(fd); if (!d || d.kind !== "dir") return null; const s = str(p, l); return fs.norm(s.startsWith("/") ? s : d.path + "/" + s) }
  const statTo = (buf, path, kind, size) => { const v = dv(); for (let i = 0; i < 64; i += 8) v.setBigUint64(buf + i, 0n, true)
    v.setBigUint64(buf, 1n, true); v.setBigUint64(buf + 8, BigInt(path ? fs.inode(path) : 1), true); v.setUint8(buf + 16, kind); v.setBigUint64(buf + 24, 1n, true); v.setBigUint64(buf + 32, BigInt(size), true)
    const t = 1700000000000000000n; v.setBigUint64(buf + 40, t, true); v.setBigUint64(buf + 48, t, true); v.setBigUint64(buf + 56, t, true) }
  const strs = (list, ptrs, buf) => { const v = dv(); for (const s of list) { v.setUint32(ptrs, buf, true); ptrs += 4; const b = enc.encode(s + "\0"); u8().set(b, buf); buf += b.length } return 0 }
  const sizes = (list, n, sz) => { const v = dv(); v.setUint32(n, list.length, true); v.setUint32(sz, list.reduce((a, s) => a + enc.encode(s).length + 1, 0), true); return 0 }
  const envl = Object.entries(env).map(([k, x]) => k + "=" + x)
  const w = {
    args_get: (a, b) => strs(argv, a, b), args_sizes_get: (a, b) => sizes(argv, a, b),
    environ_get: (a, b) => strs(envl, a, b), environ_sizes_get: (a, b) => sizes(envl, a, b),
    clock_time_get: (id, _p, out) => { dv().setBigUint64(out, id === 0 ? BigInt(Date.now()) * 1000000n : BigInt(Math.round(performance.now() * 1e6)), true); return 0 },
    fd_close: fd => fd > 3 && fds.delete(fd) ? 0 : (fds.has(fd) ? 0 : E.BADF),
    fd_fdstat_get: (fd, buf) => { const f = fds.get(fd); if (!f) return E.BADF; const v = dv(); v.setUint8(buf, f.kind === "dir" ? 3 : f.kind === "file" ? 4 : 2); v.setUint16(buf + 2, f.append ? 1 : 0, true); v.setBigUint64(buf + 8, 0xffffffffffffffffn, true); v.setBigUint64(buf + 16, 0xffffffffffffffffn, true); return 0 },
    fd_fdstat_set_flags: () => 0,
    fd_filestat_get: (fd, buf) => { const f = fds.get(fd); if (!f) return E.BADF; if (f.kind === "dir") statTo(buf, f.path, 3, 0); else if (f.kind === "file") statTo(buf, f.path, 4, f.node.len); else statTo(buf, null, 2, 0); return 0 },
    fd_prestat_get: (fd, buf) => { if (fd !== 3) return E.BADF; const v = dv(); v.setUint8(buf, 0); v.setUint32(buf + 4, 1, true); return 0 },
    fd_prestat_dir_name: (fd, p) => { if (fd !== 3) return E.BADF; u8()[p] = 47; return 0 },
    fd_read: (fd, iovs, n, out) => { const f = fds.get(fd); if (!f) return E.BADF; if (f.kind === "dir") return E.ISDIR; let total = 0; const v = dv()
      if (f.kind === "file") for (let i = 0; i < n; i++) { const p = v.getUint32(iovs + i * 8, true), l = v.getUint32(iovs + i * 8 + 4, true); const k = Math.min(l, f.node.len - f.pos); if (k <= 0) break; u8().set(f.node.buf.subarray(f.pos, f.pos + k), p); f.pos += k; total += k; if (k < l) break }
      v.setUint32(out, total, true); return 0 },
    fd_readdir: () => E.NOSYS,
    fd_seek: (fd, off, whence, out) => { const f = fds.get(fd); if (!f) return E.BADF; if (f.kind !== "file") return E.SPIPE; const base = whence === 0 ? 0 : whence === 1 ? f.pos : f.node.len; const np = base + Number(off); if (np < 0) return E.INVAL; f.pos = np; dv().setBigUint64(out, BigInt(np), true); return 0 },
    fd_tell: (fd, out) => { const f = fds.get(fd); if (!f) return E.BADF; if (f.kind !== "file") return E.SPIPE; dv().setBigUint64(out, BigInt(f.pos), true); return 0 },
    fd_write: (fd, iovs, n, out) => { const f = fds.get(fd); if (!f) return E.BADF; let total = 0; const v = dv()
      for (let i = 0; i < n; i++) { const p = v.getUint32(iovs + i * 8, true), l = v.getUint32(iovs + i * 8 + 4, true); if (!l) continue; const src = u8().subarray(p, p + l)
        if (f.kind === "out") f.chunks.push(src.slice())
        else if (f.kind === "file") { const node = f.node; if (f.append) f.pos = node.len; const end = f.pos + l
          if (end > node.buf.length) { const nb = new Uint8Array(Math.max(end, node.buf.length * 2, 65536)); nb.set(node.buf.subarray(0, node.len)); node.buf = nb }
          node.buf.set(src, f.pos); f.pos = end; if (end > node.len) node.len = end }
        else return E.BADF
        total += l }
      v.setUint32(out, total, true); return 0 },
    path_filestat_get: (fd, _fl, p, l, buf) => { const path = resolve(fd, p, l); if (path === null) return E.BADF; const node = fs.files.get(path); if (node) { statTo(buf, path, 4, node.len); return 0 } if (fs.dirs.has(path)) { statTo(buf, path, 3, 0); return 0 } return E.NOENT },
    path_open: (fd, _df, p, l, oflags, _rb, _ri, fdflags, out) => { const path = resolve(fd, p, l); if (path === null) return E.BADF
      let node = fs.files.get(path); const isDir = fs.dirs.has(path)
      if (oflags & 2) { if (!isDir) return node ? E.NOTDIR : E.NOENT; fds.set(nextFd, { kind: "dir", path }); dv().setUint32(out, nextFd++, true); return 0 }
      if (isDir) { fds.set(nextFd, { kind: "dir", path }); dv().setUint32(out, nextFd++, true); return 0 }
      if (!node) { if (!(oflags & 1)) return E.NOENT; const parent = path.slice(0, path.lastIndexOf("/")) || "/"; if (!fs.dirs.has(parent)) return E.NOENT; node = { buf: new Uint8Array(0), len: 0 }; fs.files.set(path, node) }
      else if ((oflags & 5) === 5) return E.EXIST
      if (oflags & 8) node.len = 0
      fds.set(nextFd, { kind: "file", path, node, pos: 0, append: !!(fdflags & 1) }); dv().setUint32(out, nextFd++, true); return 0 },
    fd_pread: (fd, iovs, n, off, out) => { const f = fds.get(fd); if (!f) return E.BADF; if (f.kind !== "file") return E.SPIPE; let pos = Number(off), total = 0; const v = dv()
      for (let i = 0; i < n; i++) { const p = v.getUint32(iovs + i * 8, true), l = v.getUint32(iovs + i * 8 + 4, true); const k = Math.min(l, f.node.len - pos); if (k <= 0) break; u8().set(f.node.buf.subarray(pos, pos + k), p); pos += k; total += k; if (k < l) break }
      v.setUint32(out, total, true); return 0 },
    path_filestat_set_times: () => 0,
    path_create_directory: (fd, p, l) => { const path = resolve(fd, p, l); if (path === null) return E.BADF; if (fs.dirs.has(path) || fs.files.has(path)) return E.EXIST
      const parent = path.slice(0, path.lastIndexOf("/")) || "/"; if (!fs.dirs.has(parent)) return E.NOENT; fs.dirs.add(path); return 0 },
    path_remove_directory: () => E.NOENT,
    path_rename: (fd, p, l, fd2, p2, l2) => { const a = resolve(fd, p, l), b = resolve(fd2, p2, l2); if (a === null || b === null) return E.BADF; const node = fs.files.get(a); if (!node) return E.NOENT; fs.files.set(b, node); fs.files.delete(a); return 0 },
    poll_oneoff: () => E.NOSYS,
    path_unlink_file: (fd, p, l) => { const path = resolve(fd, p, l); if (path === null) return E.BADF; return fs.files.delete(path) ? 0 : E.NOENT },
    proc_exit: code => { throw new Exit(code) },
  }
  const inst = new WebAssembly.Instance(module, { wasi_snapshot_preview1: w }); mem = inst.exports.memory
  let code = 0, trap
  try { inst.exports._start() } catch (e) { if (e instanceof Exit) code = e.code; else { code = -1; trap = String(e && e.message || e) } }
  peak = mem.buffer.byteLength
  const text = fd => { const c = fds.get(fd).chunks; let n = 0; for (const x of c) n += x.length; const b = new Uint8Array(n); n = 0; for (const x of c) { b.set(x, n); n += x.length } return dec.decode(b) }
  return { code, trap, peakBytes: peak, stdout: text(1), stderr: text(2) }
}
