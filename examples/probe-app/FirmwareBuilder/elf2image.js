// SPDX-License-Identifier: MIT
// ESP32-S3 application image writer: the subset of `esptool elf2image` the IDF build uses
// (--flash-mode dio --flash-freq 80m --flash-size 8MB --elf-sha256-offset 0xb0
//  --flash-mmu-page-size 64KB --min-rev-full 0 --max-rev-full 99). Pure JS; sha256 is injected.
const IROM_ALIGN = 0x10000, SEG_HDR = 8, CHIP_ID_ESP32S3 = 9
const MEMORY_MAP = [[0x00000000, 0x00010000, "PADDING"], [0x3C000000, 0x3D000000, "DROM"], [0x3D000000, 0x3E000000, "EXTRAM_DATA"], [0x600FE000, 0x60100000, "RTC_DRAM"], [0x3FC88000, 0x3FD00000, "BYTE_ACCESSIBLE"], [0x3FC88000, 0x403E2000, "MEM_INTERNAL"], [0x3FC88000, 0x3FD00000, "DRAM"], [0x40000000, 0x4001A100, "IROM_MASK"], [0x40370000, 0x403E0000, "IRAM"], [0x600FE000, 0x60100000, "RTC_IRAM"], [0x42000000, 0x42800000, "IROM"], [0x50000000, 0x50002000, "RTC_DATA"]]
const memType = a => MEMORY_MAP.filter(r => r[0] <= a && a < r[1]).map(r => r[2]).join(",")
const isFlash = a => (a >= 0x42000000 && a < 0x44000000) || (a >= 0x3C000000 && a < 0x3E000000)
const pad4 = d => { const n = (4 - d.length % 4) % 4; if (!n) return d; const o = new Uint8Array(d.length + n); o.set(d); return o }
const cat = (a, b) => { const o = new Uint8Array(a.length + b.length); o.set(a); o.set(b, a.length); return o }
export function elf2image(elf, sha256, opt = {}) {
  const o = { flashMode: 2, flashSizeFreq: 0x3f, elfSha256Offset: 0xb0, minRevFull: 0, maxRevFull: 99, ...opt }
  const v = new DataView(elf.buffer, elf.byteOffset, elf.byteLength)
  if (v.getUint32(0, false) !== 0x7f454c46 || elf[4] !== 1 || elf[5] !== 1) throw new Error("not a 32-bit little-endian ELF")
  const entry = v.getUint32(24, true), shoff = v.getUint32(32, true), shentsize = v.getUint16(46, true), shnum = v.getUint16(48, true), shstrndx = v.getUint16(50, true)
  if (shentsize !== 40) throw new Error("unexpected section header size")
  const sh = i => { const p = shoff + i * 40; return { name: v.getUint32(p, true), type: v.getUint32(p + 4, true), addr: v.getUint32(p + 12, true), offs: v.getUint32(p + 16, true), size: v.getUint32(p + 20, true) } }
  const str = sh(shstrndx); const nameOf = n => { let e = str.offs + n; while (elf[e]) e++; return new TextDecoder().decode(elf.subarray(str.offs + n, e)) }
  let segs = []
  for (let i = 0; i < shnum; i++) { const s = sh(i); if (s.addr === 0 || s.size === 0) continue
    if (![1, 0x0e, 0x0f, 0x10].includes(s.type)) continue
    segs.push({ name: nameOf(s.name), addr: s.addr, data: pad4(elf.slice(s.offs, s.offs + s.size)) }) }
  if (!segs.length) throw new Error("ELF has no loadable sections")
  // merge_adjacent_segments (walks backward, like esptool)
  const merged = []
  for (let i = segs.length - 1; i > 0; i--) { const a = segs[i - 1], b = segs[i]
    if (memType(a.addr) === memType(b.addr) && b.addr === a.addr + a.data.length) a.data = cat(a.data, b.data); else merged.unshift(b) }
  merged.unshift(segs[0]); segs = merged
  const out = []; let pos = 0, checksum = 0xef, total = 0
  const write = b => { out.push(b); pos += b.length }
  const head = new Uint8Array(24), hv = new DataView(head.buffer)
  head[0] = 0xe9; head[2] = o.flashMode; head[3] = o.flashSizeFreq; hv.setUint32(4, entry, true)
  head[8] = 0xee; hv.setUint16(12, CHIP_ID_ESP32S3, true); head[14] = 0; hv.setUint16(15, o.minRevFull, true); hv.setUint16(17, o.maxRevFull, true); head[23] = 1
  write(head)
  const saveSegment = s => { let d = pad4(s.data)
    if (o.elfSha256Offset >= pos && o.elfSha256Offset < pos + d.length) { const p = o.elfSha256Offset - pos
      if (p < SEG_HDR || p + 32 > d.length) throw new Error("ELF SHA-256 offset does not fall inside one segment")
      d = d.slice(); for (let k = 0; k < 32; k++) if (d[p - SEG_HDR + k] !== 0) throw new Error("ELF SHA-256 slot is not zero"); d.set(sha256, p - SEG_HDR) }
    const h = new Uint8Array(8), x = new DataView(h.buffer); x.setUint32(0, s.addr, true); x.setUint32(4, d.length, true); write(h); write(d)
    for (let k = 0; k < d.length; k++) checksum ^= d[k]; total++ }
  const sorted = segs.slice().sort((a, b) => a.addr - b.addr)
  const flash = sorted.filter(s => isFlash(s.addr)).map(s => ({ ...s })), ram = sorted.filter(s => !isFlash(s.addr)).map(s => ({ ...s }))
  const ad = flash.findIndex(s => s.name === ".flash.appdesc"); if (ad > 0) flash.unshift(flash.splice(ad, 1)[0])
  for (let i = 1; i < flash.length; i++) if (Math.floor(flash[i].addr / IROM_ALIGN) === Math.floor(flash[i - 1].addr / IROM_ALIGN)) throw new Error("two flash segments share one MMU page")
  const need = s => { const past = (s.addr % IROM_ALIGN) - SEG_HDR; let p = (IROM_ALIGN - (pos % IROM_ALIGN)) + past; if (p === 0 || p === IROM_ALIGN) return 0; p -= SEG_HDR; if (p < 0) p += IROM_ALIGN; return p }
  while (flash.length) { const s = flash[0], p = need(s)
    if (p > 0) { let padSeg
      if (ram.length && p > SEG_HDR) { const r = ram[0]; padSeg = { addr: r.addr, data: r.data.slice(0, p) }; r.data = r.data.slice(p); r.addr += p; if (!r.data.length) ram.shift() }
      else padSeg = { addr: 0, data: new Uint8Array(p) }
      saveSegment(padSeg) }
    else { if ((pos + 8) % IROM_ALIGN !== s.addr % IROM_ALIGN) throw new Error("flash segment alignment failed")
      const rem = (pos + s.data.length + SEG_HDR) % IROM_ALIGN; if (rem < 0x24) s.data = cat(s.data, new Uint8Array(0x24 - rem))
      saveSegment(s); flash.shift() } }
  for (const s of ram) saveSegment(s)
  const tail = new Uint8Array(16 - (pos % 16)); tail[tail.length - 1] = checksum; write(tail)
  const img = new Uint8Array(pos + 32); let q = 0; for (const b of out) { img.set(b, q); q += b.length }
  img[1] = total; return { image: img, bodyLength: pos, segments: total }   // caller appends sha256(image[0..bodyLength)) at bodyLength
}
