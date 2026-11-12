# Overlay manifest reader and tombstones for the pinned DSH runtime

Status: **upstream requirement note; not a patch, not submitted, not applied.** This note records
what the pinned DeepSeek Harness (DSH) runtime must provide before phone-dsh can stop repacking the
whole workspace on every boot. It does not assert that any part of it exists today, and it is not a
`git format-patch` draft: there is no implementation here to submit. It follows the process of
[`docs/upstream/README.md`](README.md): an upstream need is recorded here, and a patch is generated
from a temporary clone only after the runtime-side shape is agreed.

- Owning phoneDSH contract: [`spec/v1/wal.md`](../../spec/v1/wal.md) §8 and §8.1 (`target`).
- Tracking gap: [GAP-41](../../spec/README.md) (P02, P20), owner `contracts-w6` / upstream.
- Phone-side records: [PC-20261112-single-copy-incremental-boot](../protocol-changes/PC-20261112-single-copy-incremental-boot.md)
  (Q1) and [PC-20261113-w6-recovery-acceptance](../protocol-changes/PC-20261113-w6-recovery-acceptance.md).

## 1. Why this cannot be solved in this repository

The boot overlay is read by the pinned runtime's `readImage` (`storage/image-gzip`) in the DSH
checkout named by `PDSH_DSH_CHECKOUT`. It accepts only a gzip-wrapped ustar archive; a bare ustar, a
JSON manifest, or any second envelope fails the boot. phone-dsh may not patch or vendor DSH
(`AGENTS.md` §6, enforced by `scripts/ci/no_dsh_patch.py`), and its own `OverlayPacker` can produce
only ustar+gzip. Consequently `spec/v1/wal.md` §8.1 is `target` and **not callable**, and the host
still repacks the whole materialized tree once per changed watermark.

**NOT_VERIFIED:** the pinned checkout was not re-read for this note (`PDSH_DSH_CHECKOUT` is unset in
this worktree). The statements about `readImage` are inherited from `spec/v1/wal.md` §8, §8.1 and
[`docs/upstream/README.md`](README.md), not from a fresh reading of `storage/image-gzip`.

## 2. Required capabilities

All five are needed. Any one missing leaves the per-boot archive in place, because the runtime can
then read only a complete gzip'd ustar tree.

| # | Capability | Today | Required behaviour | Why a partial version is not enough |
|---|---|---|---|---|
| C1 | Manifest overlay reader | gzip → ustar → whole-tree mount only | Accept a manifest layer `{format, boot_id, materialized_upto_mseq, entries[{path, sha256, mode, size}], tombstones[]}` and expose it as a VFS layer whose entries are resolved on read | Without C1 nothing else can be tested; the manifest must be a layer the runtime mounts, not a side file the host interprets |
| C2 | Blob-on-demand fetch | Image shards only (`lazy/<sha256>.tar.gz`), a packaging-time concept | On the first read of a manifest entry, fetch `/blobs/sha256/<hash>` from the same loopback origin and serve those bytes | Mounting every blob up front is a full copy again: the point is that untouched paths cost nothing |
| C3 | Tombstone / whiteout | Overlay entries replace a base file wholesale; there is **no delete** | A `tombstones` entry removes a path inherited from a lower layer (base image or earlier overlay) so it is absent and unreadable | Deletions are common (session erase, pruning, `tmp` cleanup outside the volatile root). Without C3, every deletion forces a full repack and the acceptance below cannot be met |
| C4 | Capability negotiation | None: sending an unsupported overlay fails the boot | A capability string the host can query before boot (e.g. `overlay-manifest/1`), so an older runtime is not sent a manifest it cannot read | Discovery by failed boot is not deployable; an old/new pair must agree before the first request |
| C5 | Manifest/blob failure surface | Per-boot archive is keyed by `boot_id` (32 hex, per boot) and a broken archive fails the boot | Serve the manifest and blobs at boot-scoped or content-addressed routes the runtime can cache per session, and make a manifest with a missing or digest-mismatched blob fail the boot loudly, never as an empty file | A silently empty file turns a storage fault into data loss the worker cannot detect |

## 3. Proposed shapes (for agreement, not frozen upstream)

The phone-side contract already fixes the manifest body and its invariants in
[`spec/v1/wal.md`](../../spec/v1/wal.md) §8.1; the runtime side may choose different routes, but the
semantics below must survive the agreement.

```json
{"format":1,"boot_id":"<32 hex>","materialized_upto_mseq":42,
 "entries":[{"path":"home/AGENTS.md","sha256":"<64 hex>","mode":420,"size":1024}],
 "tombstones":["workspace/old.txt"]}
```

- `entries` are `home/...` and `workspace/...` only; never symlinks or special files. `sha256` is the
  §14.1 digest of the file's bytes.
- `tombstones` removes an inherited path (C3) and is empty when nothing was deleted. **It is not an
  optional nicety**: a tombstone slot in the schema without runtime support would be a second
  unimplemented `target` and is worse than no tombstone field at all.
- The host serves the manifest at `/image/overlay/<boot_id>.json` and the blobs at
  `/blobs/sha256/<hash>`; both stay `no-store` unless the runtime confirms that a content-addressed
  route may be cached `private, max-age=31536000, immutable` with no per-launch token in the URL.
- The in-memory VFS stays the runtime authority; a mutation of a manifest path is an ordinary
  `VFS_MUT` once the bytes are present, and the host's materialized copy remains the `VFS_RESYNC`
  replay source. Neither rule changes with the manifest.

## 4. Acceptance for closing GAP-41

Upstream-side evidence (in the pinned checkout's own test suite, run there, not here):

1. the runtime boots a workspace from a manifest plus the blob route, and a first read of a path
   fetches its blob only then (C1 + C2);
2. a tombstoned path inherited from the base image is absent and unreadable after boot (C3);
3. a runtime without the capability string refuses the manifest cleanly instead of booting a partial
   tree, and a host that sees the capability absent keeps sending the archive (C4);
4. a missing or digest-mismatched blob fails the boot loudly (C5).

Phone-side evidence, only after the above exists: all four ends (Swift, Rust, Kotlin, TS counter-check
codec) read the same manifest schema and golden vectors with their real decoders; a real device boot
with no mutation measures the ≤ 1 s `target` in
[`spec/v1/wal.md`](../../spec/v1/wal.md) §8.1; then and only then may §8.1 change from `target` to
`implemented` and GAP-41 close. A spec checker or a container run is not that evidence.

## 5. What phone-dsh will not do while this is pending

- It does not send a manifest, and it does not add a second overlay format or a runtime patch.
- It does not claim "recovery independent of workspace size". The acceptance is the two-clause form of
  §8.1: a no-mutation boot ≤ 1 s (`target`), a mutated boot O(bytes) with no size-independent promise.
- It does not ship a layered-ustar workaround unless the owner explicitly authorizes it. The existing
  ordered `overlays` array could carry incremental layers, but tar cannot express a deletion, so any
  removal would still force a full repack and the "independent of size" claim would remain false.
  Inventing that layer would also need a P02 clause for layer order, layer count and forced full
  packs, plus a P16/P20 change for the boot URL policy — not something to add silently.
