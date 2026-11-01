// SPDX-License-Identifier: MIT
//! D9 idempotent appended replay (`wal.md` §6.2).
//!
//! For an appended record with `append_from = A` and data length `L`, let `S` be
//! the current size of the materialized file:
//!
//! * `S == A` → append the data (the record was not applied yet);
//! * `S >= A + L` and the bytes at `[A, A + L)` equal the record data → skip
//!   (already applied);
//! * anything else, including a missing file or a directory → base mismatch
//!   (`VFS_RESYNC`, §5.1).
//!
//! The skip case makes consecutive appends replay-safe: base 6 bytes, append
//! `A=6` of 6, then `A=12` of 6 — a 6-byte file applies both, an 18-byte file
//! skips both, a 12-byte file skips the first and applies the second.
//!
//! This module decides only; it reads and writes nothing. The caller supplies
//! the file's size and the bytes at `append_from`.

/// What replaying one appended record must do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReplayDecision {
    /// `S == A`: append the data at `append_from`.
    Applied,
    /// The bytes are already present at `[A, A + L)`: do nothing.
    Skip,
    /// Base mismatch (`§5.1`): stop materializing the path and send
    /// `VFS_RESYNC`; `materialized_upto_mseq` stays below the record.
    Resync,
}

/// The pure D9 decision for one appended record.
///
/// `existing_at_offset` is the materialized file's bytes starting at
/// `append_from` (at least `data.len()` of them when the file is longer), or
/// `None` when the path is absent, is a directory, or is not a regular file —
/// all of which are a base mismatch.
pub fn appended_replay(
    current_size: u64,
    append_from: u64,
    data: &[u8],
    existing_at_offset: Option<&[u8]>,
) -> ReplayDecision {
    let Some(existing) = existing_at_offset else {
        return ReplayDecision::Resync;
    };
    if current_size == append_from {
        return ReplayDecision::Applied;
    }
    let end = match append_from.checked_add(data.len() as u64) {
        Some(end) => end,
        None => return ReplayDecision::Resync,
    };
    if current_size >= end && existing.len() >= data.len() && &existing[..data.len()] == data {
        return ReplayDecision::Skip;
    }
    ReplayDecision::Resync
}
