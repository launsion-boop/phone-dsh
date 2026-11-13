# Lazy/ranged boot overlay instead of one full ustar+gzip member

Status: **upstream proposal note; not a patch and not applied**. phone-dsh keeps
its pinned DSH checkout unmodified (AGENTS.md §6, CONTRIBUTING "Zero DSH source
patches"; the pin is DSH `0.2.2-rc.1`, commit
`66491b05e3f05ad35bcdd4f6cd7ed26041d9e3db` per `plugins/dsh-pin.json`). The
current `spec/v1/wal.md` §8 envelope is unchanged in this branch; this note
records why the host cannot remove the remaining boot cost from its side and
what the runtime must accept before it can.

## Problem and measured evidence

The host still hands the Worker the whole materialized tree as one
gzip-compressed ustar archive, and the Worker materializes every entry before
the first request:

| Observation | Value | Where it comes from |
|---|---:|---|
| Boot-overlay pack/serve phase | 5.0–6.6 s | device boot evidence; the dominant serial boot phase |
| Share of total boot | 74% | same evidence |
| Materialized tree | 139 MB | `materialized/{home,workspace}` at the time of the measurement |
| Largest single directory | 126 MB in `phone-dsh-src` | one top-level directory under `workspace/` |

The per-file DEFLATE fragment cache (F1, `overlay-frags/` in
`Sources/PhoneDSHLog/OverlayFragmentCache.swift`) removed the repeated
*recompression* cost for unchanged files. It did not remove the bytes: a warm
boot still concatenates the same fragments into one gzip member, the loopback
route still sends that whole member, and the Worker still inflates and mounts
all 139 MB. The host-side `overlay-compose` line now records that composition
in `boot-timings.log`, but observability is not a fix.

Shrinking the tree is a separate, legitimate measure: `phone-dsh-src` alone is
91% of the tree. It is not a protocol answer, because any workspace that really
holds that much content pays the same full-transfer and full-materialization
cost on every boot.

## Why the host cannot fix this without an upstream change

Two constraints meet at the same envelope:

1. **The phone contract pins the full archive.** `spec/v1/wal.md` §8 defines the
   boot overlay as a ustar archive whose transport envelope is a single gzip
   member. A bare ustar is explicitly not tolerated; it fails to boot. The
   archive is rebuilt per boot and only its decompressed ustar is contractual,
   so the host may cache fragments but may not change what the Worker receives.
2. **The pinned runtime only reads that envelope.** In the pinned DSH checkout,
   `packages/experimental/webworker-runtime/src/storage/image-gzip.ts` inflates
   the whole response body, and `createWorkerHost` passes every overlay through
   the same `readImage` path before `loadVfsOverlay` seeds the in-memory VFS
   (`packages/experimental/webworker-runtime/src/worker-host.ts`). There is no
   overlay manifest reader and no per-entry fetch hook today.

A host that sent a manifest, JSON, an HTTP `Range` response, or a second
content-addressed URL today would therefore fail boot, not boot lazily. Patching
the pinned checkout is prohibited, so the host can only report the cost until
the runtime accepts another form.

## Concrete protocol change requested

Add a **lazy overlay form** alongside the existing archive. The preferred form
is a manifest plus content-addressed blobs; a per-entry/member range form is an
acceptable alternative if maintainers prefer to reuse the current tar reader.

### Preferred: overlay manifest + content-addressed blobs

The host exposes, for the same `boot_id` and materialized watermark:

```jsonc
// GET /image/overlay/<boot_id>.json
{
  "format": 1,
  "boot_id": "<32 lowercase hex>",
  "materialized_upto_mseq": 42,
  "entries": [
    // The same entry set the archive already has: home/… and workspace/…,
    // directories with their mode, regular files with mode, size and sha256.
    {"path": "home/", "kind": "dir", "mode": 493, "size": 0},
    {"path": "home/AGENTS.md", "kind": "file", "mode": 420, "size": 1024,
     "sha256": "<64 lowercase hex>"},
    {"path": "workspace/phone-dsh-src/README.md", "kind": "file",
     "mode": 420, "size": 8123, "sha256": "<64 lowercase hex>"}
  ],
  "tombstones": []
}
```

```http
GET /blobs/sha256/<64-hex>
200 OK
Content-Type: application/octet-stream
Content-Length: <size>
ETag: "<64-hex>"

<the exact file bytes>
```

Semantics to freeze:

- The manifest is bounded and deterministic: paths stay under `home/` or
  `workspace/`, symlinks and special files are refused exactly as in §8, and
  `sha256` is the digest of the file bytes, not of a tar entry.
- The Worker mounts directory metadata and file sizes eagerly, but fetches a
  file's blob only on first read. A successful first read makes the ordinary VFS
  entry visible; a failed/missing blob fails that read loudly and is never a
  silently empty file.
- Blobs are immutable and reusable across boots and overlays. The host keeps
  the legacy full archive route as well; F1's fragment cache remains useful for
  producing the legacy archive, not for the lazy form.
- `tombstones` is optional and only needed if the runtime can start from an
  earlier overlay layer. The current boot uses a fresh VFS plus the base image,
  so an empty list is legal; do not invent a second deletion language for it.
- The in-memory VFS remains the runtime authority. The first mutation of a
  fetched path is an ordinary `VFS_MUT`; `VFS_RESYNC` semantics do not change.

### Alternative: indexed/ranged single member

If maintainers want to keep one archive endpoint, publish a small index of
per-entry offsets/lengths into the existing gzip member (or into the independent
DEFLATE fragments the host already caches), then let the Worker fetch only the
members it opens, with HTTP `Range`. This avoids a second storage layout, but it
still requires a new runtime reader that understands the index and does not
inflate the whole body. It is not implementable by the host alone either.

## Compatibility rule

The request is additive; no version or content-type change may strand either
side:

- **Old host → new Worker:** the host keeps sending the legacy single
  ustar+gzip member at the existing overlay URL. A new Worker must accept it and
  use the current eager path (or mount it lazily only if it can do so from the
  same bytes). A manifest attempt that receives gzip/404 falls back to the
  legacy URL once.
- **New host → old Worker:** the legacy URL and bytes remain unchanged. The host
  serves the manifest and blobs only when the bundled/new Worker opts in (for
  example an explicit `PDSH-Overlay-Format: manifest` request or a boot config
  value it sets). An old Worker never receives a JSON body at the archive URL.
- **New host ↔ new Worker:** the Worker prefers the lazy form, falls back to the
  full archive if the manifest/blob route is unavailable, and never mixes the
  two for one boot. The archive remains the compatibility path until the tested
  DSH range no longer contains a reader that lacks the lazy form.
- **Data/rollback:** no persisted host format changes. The legacy archive can
  always be rebuilt from the materialized tree; the lazy manifest and blobs are
  derived state and may be discarded and rebuilt. An older runtime still boots
  from the legacy route.

## What the app-side change would be if §8 admits it

The phone host would add, behind the same materialized watermark that already
gates `overlay-cache.tar`:

1. A manifest writer that hashes the files it already walks and writes
   `{path, kind, mode, size, sha256}`. The manifest walk can reuse F1's lstat
   identity; add the SHA-256 to the fragment index so an unchanged file is not
   reread merely to recompute its digest, and hash a changed file once.
2. A content-addressed blob store under the workspace's derived state (a copy
   or a copy-on-write clone of a materialized file, never a hard link, because
   an appended materialized write would mutate a shared inode), pruned by the
   same watermark/erasure path that removes `overlay-frags/`.
3. Two loopback routes: `/image/overlay/<boot_id>.json` and
   `/blobs/sha256/<hash>`, with immutable cache headers keyed by the digest and
   the existing per-launch authorization otherwise unchanged.
4. An engine-boot configuration that gives a capable Worker the manifest URL and
   gives an older Worker the current `overlay-<boot_id>.tar` URL. No channel
   frame, HELLO field or WAL record is added.

The corresponding DSH change is in the pinned runtime, not this repository: an
overlay reader that accepts the manifest, registers lazy entries in the mounted
VFS, and fetches a blob on first access. `readImage`/`loadVfsOverlay` would need
to accept both the legacy gzip member and the manifest; the image path itself is
unchanged.

## Expected effect

- The boot overlay phase becomes metadata work: a manifest walk with cached
  digests for unchanged files, not a 139 MB gzip assembly and transfer. The
  measured 5.0–6.6 s / 74% serial phase should become sub-second for an
  unchanged tree; a changed file is hashed once and its blob fetched on first
  access.
- Resident Worker bytes become the files actually touched, not the whole
  materialized tree. A boot that touches a few files should no longer reserve
  139 MB for the overlay.
- A cold cache pays one blob fetch per file opened; that is smaller and
  incremental, and content-addressed blobs can be cached across boots. It is not
  a claim that the total bytes on disk disappear: the host still keeps the
  materialized tree and the derived blob/manifest state until compaction.

## Tests and open questions for maintainers

- Runtime unit test: a manifest with two files mounts both metadata entries,
  fetches only the opened file, rejects a wrong digest/missing blob loudly, and
  falls back to a gzip member when the manifest route is absent.
- Host/runtime contract test: old gzip archive boots a new Worker; new manifest
  boots a new Worker; an old Worker still boots from the legacy URL.
- Device measurement is required before claiming the sub-second/resident-byte
  effect; a simulator or unit test cannot establish either.

Open questions: whether the runtime should expose lazy entries through
`MemoryVfs` itself or through the loader; whether directories need first-class
manifest entries (the sketch keeps them for mode fidelity); and whether the
manifest is served at the existing overlay URL with content negotiation or at a
new sibling URL. None of these change the compatibility rule above.

## Not verified

This proposal was not applied to the pinned DSH checkout and no DSH test ran.
It is not a device, power-loss, WebKit or model end-to-end result. The phone-side
composition line in this branch only observes the current full archive; it does
not implement the lazy form.
