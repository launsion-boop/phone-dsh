// SPDX-License-Identifier: MIT
//! Tail-tear classification (`wal.md` §10, D19) and whole-segment scanning.
//!
//! D19: an incomplete or mismatching `len`/`crc32c` **with no complete record
//! after it** is a torn tail — power loss may lose the open epoch — so it is
//! truncated to the last complete record and logged, not an error. A CRC
//! failure that is not at the tail, or an invalid record followed by a valid
//! one, is `WAL_CORRUPT` → `Failed`.
//!
//! [`classify_tail`] is a pure function over the **record region** of one
//! segment file (the bytes after the 40-byte header). Offsets in the verdict
//! are relative to that region; add [`crate::header::HEADER_BYTES`] for a file
//! offset. Whether a tear may be truncated at all — only the newest segment of
//! the `wal/` directory may be torn, because later segments prove earlier ones
//! were written completely — is the caller's decision, and the recovery planner
//! rejects a torn non-newest segment.
//!
//! Deciding "no complete record after it" needs a search, because a corrupt
//! `len` hides where the next record would start. A legal record cut short is
//! first proved by its own `len`/body header, so a legal large tail never needs
//! that search. The remaining search is bounded by [`TAIL_SEARCH_WINDOW`] and
//! by a CRC work budget ([`TAIL_SEARCH_CRC_BUDGET`]); exhausting it reports "a
//! complete record may follow", i.e. [`TailVerdict::Corrupt`], because a corrupt
//! `len` is then the remaining explanation and this crate fails loud rather
//! than silently truncating an acknowledged record.

use crate::checksum::Checksum;
use crate::error::WalError;
use crate::header::{SegmentHeader, HEADER_BYTES};
use crate::record::{
    incomplete_shape_agrees, Record, RecordChain, RecordParseError, RECORD_PREFIX_BYTES,
};
use crate::segment::SegmentName;

/// How far past a failure the byte scan looks for a complete record when the
/// failing record's `len` cannot be trusted. A record is written as one
/// contiguous chunk, so a real continuation almost always starts at the
/// claimed end; the window only covers a corrupted `len`.
pub const TAIL_SEARCH_WINDOW: usize = 4096;

/// The CRC work the fallback tail search may spend before it fails loud
/// instead of truncating.
///
/// This is a **work bound, not a coverage bound**. A legal mutation carries up
/// to 15 MiB of data (`channel.md` §3.1) plus its body header, well above this
/// 4 MiB value, so the budget alone could never prove a large tear. The legal
/// shape is proved from the record's own `len`/`body` header before this search
/// runs; the budget only bounds the search that remains when that shape does
/// **not** agree, where a corrupt `len` is the remaining explanation and
/// failing loud is the correct outcome.
pub const TAIL_SEARCH_CRC_BUDGET: usize = 4 * 1024 * 1024;

/// The D19 verdict for the record region of one segment file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TailVerdict {
    /// Every byte belongs to a complete, CRC-verified record.
    Clean,
    /// Keep the first `keep` bytes of the region and drop `dropped`; the
    /// truncation is logged (segment, byte offset, dropped bytes) and is not an
    /// error.
    Truncate {
        /// Bytes of the region that form the last complete record prefix.
        keep: usize,
        /// Bytes after `keep` that the torn tail rule drops.
        dropped: usize,
    },
    /// A failure that is not at the tail: `WAL_CORRUPT`.
    Corrupt {
        /// Region offset of the failing record.
        at: usize,
    },
}

/// A truncation the caller must apply and log.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Truncation {
    /// The segment file to truncate.
    pub name: SegmentName,
    /// The file length to keep, header included (`HEADER_BYTES + keep` of the
    /// region verdict).
    pub keep_len: usize,
    /// The bytes the truncation drops.
    pub dropped_bytes: usize,
}

impl Truncation {
    /// The byte offset the log record of §10 step 2 names: the end of the last
    /// complete record, which is also the new file length.
    pub fn offset(&self) -> usize {
        self.keep_len
    }
}

/// Classifies the tail of a segment's record region.
pub fn classify_tail(region: &[u8], cks: &dyn Checksum) -> TailVerdict {
    let (offset, failure) = walk(region, cks, |_| {});
    verdict_for(region, offset, failure, cks)
}

/// One parsed segment file: header verdict, verified record prefix and the D19
/// tail verdict.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SegmentScan {
    /// The header, when it parsed and verified.
    pub header: Option<SegmentHeader>,
    /// Why the header did not verify, when it did not.
    pub header_error: Option<WalError>,
    /// The verified record prefix, in file order (the epoch close last).
    pub records: Vec<Record>,
    /// The D19 verdict over the record region.
    pub verdict: TailVerdict,
    /// A `wal.md` §3–§4 order violation among the verified records: a mutation
    /// that does not continue `first_mseq`, a duplicate epoch close, or a record
    /// after the close. The bytes are individually valid, so this is not a tear;
    /// it is corruption (`WAL_CORRUPT`), exactly like a non-tail CRC failure.
    pub chain_error: Option<WalError>,
    /// Bytes of the file that belong to the header and the verified records:
    /// the length to keep after a truncation.
    pub valid_len: usize,
    /// The size of the record region (`file length - HEADER_BYTES`).
    pub record_region_len: usize,
}

impl SegmentScan {
    /// `true` when the header parsed and verified.
    pub fn header_ok(&self) -> bool {
        self.header.is_some()
    }

    /// `true` when the scan found a failure that is not a torn tail: a non-tail
    /// byte failure or a record-order violation.
    pub fn is_corrupt(&self) -> bool {
        matches!(self.verdict, TailVerdict::Corrupt { .. }) || self.chain_error.is_some()
    }

    /// The truncation this scan requires, when its tail is torn.
    pub fn truncation(&self, name: SegmentName) -> Option<Truncation> {
        match self.verdict {
            TailVerdict::Truncate { keep, dropped } => Some(Truncation {
                name,
                keep_len: HEADER_BYTES + keep,
                dropped_bytes: dropped,
            }),
            TailVerdict::Clean | TailVerdict::Corrupt { .. } => None,
        }
    }

    /// The lowest mutation mseq in the verified prefix.
    pub fn first_mutation_mseq(&self) -> Option<u64> {
        self.records
            .iter()
            .find_map(|record| record.mutation_mseq())
    }

    /// The highest mutation mseq in the verified prefix, 0 when it holds none
    /// (header-only or idle-close segment; §7 `last_mseq` is 0 then).
    pub fn last_mutation_mseq(&self) -> u64 {
        self.records
            .iter()
            .filter_map(|record| record.mutation_mseq())
            .max()
            .unwrap_or(0)
    }

    /// The `durable_upto` of the epoch-close record, when the segment holds one.
    pub fn epoch_close(&self) -> Option<u64> {
        self.records
            .iter()
            .find_map(|record| record.epoch_close().map(|close| close.durable_upto))
    }
}

/// Parses one segment file: header, verified record prefix, D19 verdict.
///
/// A file shorter than its header, or a header whose magic/format/reserved/
/// `first_mseq`/CRC is wrong, has no trusted record region: the scan reports the
/// header error, no records and `valid_len = 0`, and the caller applies §10
/// step 1 (a listed segment follows the missing-segment rule; an unlisted one is
/// `WAL_CORRUPT`).
///
/// The verified records are also run through [`RecordChain`], so a segment whose
/// mutations are not consecutive from `first_mseq`, that holds two epoch closes,
/// or that has a record after the close reports [`SegmentScan::chain_error`] and
/// [`SegmentScan::is_corrupt`].
pub fn scan_segment(bytes: &[u8], cks: &dyn Checksum) -> SegmentScan {
    if bytes.len() < HEADER_BYTES {
        return SegmentScan {
            header: None,
            header_error: Some(WalError::Truncated {
                need: HEADER_BYTES,
                have: bytes.len(),
            }),
            records: Vec::new(),
            verdict: TailVerdict::Clean,
            chain_error: None,
            valid_len: 0,
            record_region_len: 0,
        };
    }
    let header = match SegmentHeader::parse(bytes, cks) {
        Ok(header) => header,
        Err(error) => {
            return SegmentScan {
                header: None,
                header_error: Some(error),
                records: Vec::new(),
                verdict: TailVerdict::Clean,
                chain_error: None,
                valid_len: 0,
                record_region_len: 0,
            }
        }
    };
    let region = &bytes[HEADER_BYTES..];
    let mut records = Vec::new();
    let (offset, failure) = walk(region, cks, |record| records.push(record.clone()));
    let verdict = verdict_for(region, offset, failure, cks);
    let mut chain = RecordChain::from_header(&header);
    let chain_error = records
        .iter()
        .find_map(|record| chain.push(record).err());
    let kept = match verdict {
        TailVerdict::Clean => region.len(),
        TailVerdict::Truncate { keep, .. } => keep,
        TailVerdict::Corrupt { at } => at,
    };
    SegmentScan {
        header: Some(header),
        header_error: None,
        records,
        verdict,
        chain_error,
        valid_len: HEADER_BYTES + kept,
        record_region_len: region.len(),
    }
}

/// Walks the verified prefix of a record region, feeding each record to `sink`.
/// Returns the offset of the first failure (or the region length) and that
/// failure.
fn walk(
    region: &[u8],
    cks: &dyn Checksum,
    mut sink: impl FnMut(&Record),
) -> (usize, Option<RecordParseError>) {
    let mut offset = 0;
    while offset < region.len() {
        match Record::parse(&region[offset..], cks) {
            Ok(parsed) => {
                sink(&parsed.record);
                offset += parsed.byte_len;
            }
            Err(error) => return (offset, Some(error)),
        }
    }
    (offset, None)
}

/// Turns a walk result into the D19 verdict.
fn verdict_for(
    region: &[u8],
    offset: usize,
    failure: Option<RecordParseError>,
    cks: &dyn Checksum,
) -> TailVerdict {
    match failure {
        None => TailVerdict::Clean,
        Some(error) if !error.is_tail_eligible() => TailVerdict::Corrupt { at: offset },
        Some(_) => {
            if has_complete_record_after(region, offset, cks) {
                TailVerdict::Corrupt { at: offset }
            } else {
                TailVerdict::Truncate {
                    keep: offset,
                    dropped: region.len() - offset,
                }
            }
        }
    }
}

/// The `8 + len` a record at `offset` claims, when its `len` is plausible.
fn claimed_total(region: &[u8], offset: usize) -> Option<usize> {
    if region.len() < offset + 4 {
        return None;
    }
    let len = u32::from_be_bytes([
        region[offset],
        region[offset + 1],
        region[offset + 2],
        region[offset + 3],
    ]);
    if len < RECORD_PREFIX_BYTES as u32 {
        return None;
    }
    Some(RECORD_PREFIX_BYTES + len as usize)
}

/// D19's "no complete record after it" test.
fn has_complete_record_after(region: &[u8], offset: usize, cks: &dyn Checksum) -> bool {
    match claimed_total(region, offset) {
        // The claim fits: the next record can only start where this one says it
        // ends. A record found there proves the failure is not at the tail.
        Some(total) if offset + total <= region.len() => {
            return Record::parse(&region[offset + total..], cks).is_ok()
        }
        // The claim runs past the end. If the record's own `len` agrees with
        // the body header that is already on disk, it is a legal record cut
        // short — a torn tail, with no complete record after its claimed end.
        // Proving this without scanning is what keeps a legal large record
        // (up to 15 MiB of data, far above the 4 MiB fallback budget) from
        // being misreported as corruption.
        Some(_) if incomplete_shape_agrees(&region[offset..]) => return false,
        // Otherwise the `len` itself may be corrupt: search a bounded window
        // for a complete record.
        _ => {}
    }
    scan_for_record(region, offset + 1, cks)
}

/// Best-effort forward search for a complete, CRC-verified record.
fn scan_for_record(region: &[u8], start: usize, cks: &dyn Checksum) -> bool {
    if region.len() < RECORD_PREFIX_BYTES {
        return false;
    }
    let last_start = region.len() - RECORD_PREFIX_BYTES;
    if start > last_start {
        return false;
    }
    let end = last_start.min(start.saturating_add(TAIL_SEARCH_WINDOW));
    let mut budget = TAIL_SEARCH_CRC_BUDGET;
    for candidate in start..=end {
        match Record::parse(&region[candidate..], cks) {
            // A CRC-verified record — even one whose body is malformed — is a
            // complete record after the failure.
            Ok(_) | Err(RecordParseError::Malformed(_)) => return true,
            Err(RecordParseError::CrcMismatch { .. }) => {
                // This candidate's record fits the region (a `ShortRecord`
                // never reaches this arm), so the cap is defensive: never
                // charge more bytes than the candidate can actually contain.
                let spent = claimed_total(region, candidate)
                    .unwrap_or(RECORD_PREFIX_BYTES)
                    .min(region.len() - candidate);
                budget = budget.saturating_sub(spent);
                if budget == 0 {
                    // Undecidable within budget: fail loud, never truncate on a
                    // guess. The legal large-tail shape was proved above, so
                    // this is the corrupt-length case.
                    return true;
                }
            }
            Err(_) => {}
        }
    }
    false
}
