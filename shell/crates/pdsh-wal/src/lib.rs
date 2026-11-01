// SPDX-License-Identifier: MIT
//! `pdsh-wal`: the phone-dsh-v1 WAL format and recovery kernel.
//!
//! This crate is the I/O-free half of `spec/v1/wal.md`: the 40-byte segment
//! header (§2), record frames (§3), the epoch-close record (§4), the D19
//! tail-tear classifier (§10), the D9 idempotent appended-replay decision (§6.2),
//! the `manifest.json` model (§7) and the D11 recovery planner (§7.2).
//!
//! Persistence ordering stays per-OS and is deliberately **not** here:
//!
//! * the D18 fsync sequence of §5.2 (materialized files and directories,
//!   `F_FULLFSYNC` of every segment written in the epoch, `fsync` of `wal/`);
//! * the epoch close itself and its wall clock;
//! * the atomic `manifest.json` replace (temp file, fsync, rename, directory
//!   fsync) and every segment unlink;
//! * the staged reconcile file dance (`reconcile.inprogress`, `materialized.staging/`).
//!
//! Format sharing is not durability sharing: the most expensive mistake in a
//! WAL is an fsync order, and that order is naturally per-OS. The recovery
//! planner therefore returns *what* to replay, truncate, drop or rebuild; the
//! caller performs the I/O in the order `wal.md` fixes.
//!
//! Nothing here allocates a checksum implementation: CRC32C is injected through
//! [`Checksum`], so this crate has no dependency on the wire codec.
//!
//! ```
//! use pdsh_wal::{Checksum, SegmentHeader, HEADER_BYTES};
//!
//! // A test-local Castagnoli checksum (production wiring supplies the wire
//! // codec's `crc32c` instead).
//! struct Crc;
//! impl Checksum for Crc {
//!     fn crc32c(&self, _bytes: &[u8]) -> u32 { 0 }
//! }
//!
//! let header = SegmentHeader::new(1, [0u8; 16], &Crc).unwrap();
//! assert_eq!(header.emit().len(), HEADER_BYTES);
//! ```

#![forbid(unsafe_code)]
#![deny(missing_docs)]

pub mod checksum;
pub mod epoch;
pub mod error;
pub mod header;
pub mod json;
pub mod manifest;
pub mod record;
pub mod recovery;
pub mod replay;
pub mod segment;
pub mod tear;

pub use checksum::Checksum;
pub use epoch::EpochClose;
pub use error::{WalError, WalResult};
pub use header::{SegmentHeader, HEADER_BYTES, MAGIC};
pub use manifest::{next_mseq, Manifest, ManifestSegment};
pub use record::{
    Mutation, MutationBody, ParsedRecord, Record, RecordChain, RecordParseError, BODY_HEADER_BYTES,
    MFLAG_APPENDED, MFLAG_ENTRY_CHANGED, OP_CHMOD, OP_EPOCH_CLOSE, OP_MKDIR, OP_REMOVE, OP_WRITE,
    RECORD_PREFIX_BYTES,
};
pub use recovery::{RecoveryInput, RecoveryPlan, SegmentFacts};
pub use replay::{appended_replay, ReplayDecision};
pub use segment::SegmentName;
pub use tear::{classify_tail, scan_segment, SegmentScan, TailVerdict, Truncation};
