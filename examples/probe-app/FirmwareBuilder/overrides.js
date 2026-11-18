// SPDX-License-Identifier: MIT
// Source overrides (spec/device/v1/xiaozhi-firmware.md §5). The editable files of a pack are the
// project.bin files below manifest.sources_root + "/". A build may replace their bytes in the
// in-memory file system after loadBundle and before the first compile job. A path that is not
// editable is an error (`not_editable`), never ignored. Without overrides nothing here runs, so the
// build stays the pack's reference build.

export class OverrideError extends Error {
  constructor(code, path) { super(`${code}: ${path}`); this.code = code; this.path = path }
}

// A relative path below sources_root: no empty, ".", ".." segment, not absolute.
export function validRelPath(rel) {
  if (typeof rel !== "string" || rel === "" || rel.startsWith("/") || rel.includes("\\") || rel.includes("\0")) return false
  return rel.split("/").every(s => s !== "" && s !== "." && s !== "..")
}

// sources_root without trailing "/"; null when the pack declares none.
export function normalizeRoot(root) {
  if (typeof root !== "string" || !root.startsWith("/")) return null
  const r = root.replace(/\/+$/, "")
  return r === "" ? null : r
}

// Editable pack paths (absolute) -> path relative to sources_root. `filePaths` are project.bin's file paths.
export function editableFiles(root, filePaths) {
  const r = normalizeRoot(root); const out = new Map()
  if (!r) return out
  for (const p of filePaths) if (p.startsWith(r + "/") && p.length > r.length + 1) out.set(p, p.slice(r.length + 1))
  return out
}

// Maps overrides {rel: bytes} to [{rel, abs, bytes}]. Throws OverrideError("not_editable", rel) for the
// first rel that is not an editable file (also when the pack has no sources_root).
export function mapOverrides(root, filePaths, overrides) {
  const r = normalizeRoot(root); const editable = new Set(editableFiles(root, filePaths).values()); const out = []
  for (const [rel, bytes] of Object.entries(overrides || {})) {
    if (!r || !validRelPath(rel) || !editable.has(rel)) throw new OverrideError("not_editable", rel)
    out.push({ rel, abs: r + "/" + rel, bytes })
  }
  return out
}

// Writes the overrides into `fs` (a MemFS). Returns the mapped list.
export function applyOverrides(fs, root, filePaths, overrides) {
  const mapped = mapOverrides(root, filePaths, overrides)
  for (const m of mapped) fs.put(m.abs, m.bytes)
  return mapped
}

export function fromBase64(s) {
  const b = atob(s), u = new Uint8Array(b.length)
  for (let i = 0; i < b.length; i++) u[i] = b.charCodeAt(i)
  return u
}
// {rel: base64} -> {rel: Uint8Array}
export function decodeOverrides(map) {
  const out = {}
  for (const [rel, b64] of Object.entries(map || {})) out[rel] = fromBase64(String(b64))
  return out
}
