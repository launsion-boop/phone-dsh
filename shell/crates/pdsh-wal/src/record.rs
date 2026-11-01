// SPDX-License-Identifier: MIT
//! Record frames (`wal.md` §3) and their order rules.
//!
//! ```text
//! len u32 | crc32c u32 | mseq u64 | body
//! ```
//!
//! `len` covers `mseq` and `body` and excludes `len` and `crc32c`; `crc32c`
//! covers `mseq ‖ body` only. The mutation body is the `0x10 VFS_MUT` payload of
//! `channel.md` §3.1 without its leading `mseq`:
//! `op u8 | mode u32 | mflags u8 | append_from u64 | path_len u16 | path |
//! data_len u32 | data`.
//!
//! Only two record kinds exist (§3 last line): a mutation and the §4 epoch
//! close. They are separate types here — [`Mutation`] has an `mseq`, an
//! [`EpochClose`] has only `wall_ms`/`durable_upto` and its wire `mseq` *is*
//! `durable_upto` — so no materializer can accidentally treat a close record as
//! a mutation or advance `materialized_upto_mseq` across it.
//!
//! [`RecordChain`] is the pure mseq-continuity rule (D3/D17): within one
//! segment mutations start at the header's `first_mseq` and are strictly
//! consecutive, and an epoch close is the last record. The check is a value, not
//! an I/O action, so the scanner and the writer can share it.

use core::fmt;

use crate::checksum::Checksum;
use crate::epoch::EpochClose;
use crate::error::{WalError, WalResult};

pub use crate::epoch::OP_EPOCH_CLOSE;

/// `op` of a complete file write (`channel.md` §3.1).
pub const OP_WRITE: u8 = 1;
/// `op` of a directory create.
pub const OP_MKDIR: u8 = 2;
/// `op` of a remove (a whole subtree for a directory).
pub const OP_REMOVE: u8 = 3;
/// `op` of a mode change.
pub const OP_CHMOD: u8 = 4;
/// `mflags` bit 0 `entryChanged` (`channel.md` §3.1).
pub const MFLAG_ENTRY_CHANGED: u8 = 1 << 0;
/// `mflags` bit 1 `appended`: the data is the suffix from `append_from`.
pub const MFLAG_APPENDED: u8 = 1 << 1;
/// The largest `mode` a mutation may carry.
pub const MAX_MODE: u32 = 0o7777;
/// `len` and `crc32c` in front of every record payload.
pub const RECORD_PREFIX_BYTES: usize = 8;
/// The fixed part of a mutation body before its path.
pub const BODY_HEADER_BYTES: usize = 16;

/// A mutation body: the `VFS_MUT` payload without its leading `mseq`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MutationBody {
    /// `op`: 1 write, 2 mkdir, 3 remove, 4 chmod.
    pub op: u8,
    /// Permission bits, at most `0o7777`; 0 for remove.
    pub mode: u32,
    /// `mflags`: bit 0 `entryChanged`, bit 1 `appended`, bits 2–7 zero.
    pub mflags: u8,
    /// The byte offset an appended suffix starts at; 0 unless `appended` is set.
    pub append_from: u64,
    /// The absolute VFS path. Its D4 grammar is the wire layer's business; this
    /// crate records the bytes faithfully and only requires valid UTF-8.
    pub path: String,
    /// The file bytes of a write; empty for mkdir/remove/chmod.
    pub data: Vec<u8>,
}

impl MutationBody {
    /// A body without validation. Call [`MutationBody::validate`] before
    /// emitting it.
    pub fn new(op: u8, mode: u32, mflags: u8, append_from: u64, path: &str, data: Vec<u8>) -> Self {
        MutationBody {
            op,
            mode,
            mflags,
            append_from,
            path: path.to_string(),
            data,
        }
    }

    /// `true` when `mflags` bit 1 is set: `data` is a suffix from `append_from`.
    pub fn is_appended(&self) -> bool {
        self.mflags & MFLAG_APPENDED != 0
    }

    /// The structural invariants of `channel.md` §3.1 and `wal.md` §3. The D4
    /// path grammar and sink scope are not re-implemented here.
    pub fn validate(&self) -> WalResult<()> {
        let bad = |reason: &str| WalError::malformed(reason.to_string());
        if self.mflags & !(MFLAG_ENTRY_CHANGED | MFLAG_APPENDED) != 0 {
            return Err(bad("reserved mutation flags are set"));
        }
        if self.mode > MAX_MODE {
            return Err(bad("mode exceeds 0o7777"));
        }
        if self.path.is_empty() {
            return Err(bad("path is empty"));
        }
        if self.path.len() > u16::MAX as usize {
            return Err(bad("path exceeds the u16 path_len"));
        }
        if self.data.len() > u32::MAX as usize - RECORD_PREFIX_BYTES {
            return Err(bad("data exceeds the u32 record length"));
        }
        match self.op {
            OP_WRITE => {
                if !self.is_appended() && self.append_from != 0 {
                    return Err(bad("a complete write must have append_from = 0"));
                }
            }
            OP_MKDIR | OP_CHMOD => {
                if self.mflags != 0 || self.append_from != 0 {
                    return Err(bad("mkdir/chmod carries no flags or offset"));
                }
                if !self.data.is_empty() {
                    return Err(bad("mkdir/chmod carries no data"));
                }
            }
            OP_REMOVE => {
                if self.mode != 0 {
                    return Err(bad("remove has mode 0"));
                }
                if self.mflags != 0 || self.append_from != 0 {
                    return Err(bad("remove carries no flags or offset"));
                }
                if !self.data.is_empty() {
                    return Err(bad("remove carries no data"));
                }
            }
            other => {
                return Err(WalError::malformed(format!("unknown VFS op {other}")));
            }
        }
        Ok(())
    }

    /// The record-body bytes, byte-identical to the `VFS_MUT` payload minus its
    /// leading `mseq`.
    pub fn emit(&self) -> WalResult<Vec<u8>> {
        self.validate()?;
        let path = self.path.as_bytes();
        let mut out = Vec::with_capacity(BODY_HEADER_BYTES + path.len() + 4 + self.data.len());
        out.push(self.op);
        out.extend_from_slice(&self.mode.to_be_bytes());
        out.push(self.mflags);
        out.extend_from_slice(&self.append_from.to_be_bytes());
        out.extend_from_slice(&(path.len() as u16).to_be_bytes());
        out.extend_from_slice(path);
        out.extend_from_slice(&(self.data.len() as u32).to_be_bytes());
        out.extend_from_slice(&self.data);
        Ok(out)
    }

    /// Parses a complete, CRC-verified record body and validates it.
    pub fn parse(body: &[u8]) -> WalResult<Self> {
        let bad = |reason: String| WalError::malformed(reason);
        if body.is_empty() {
            return Err(bad("record body is empty".to_string()));
        }
        if body[0] == OP_EPOCH_CLOSE {
            return Err(bad("epoch-close body used as a mutation body".to_string()));
        }
        if body.len() < BODY_HEADER_BYTES {
            return Err(bad(format!(
                "record body is {} bytes, shorter than {BODY_HEADER_BYTES}",
                body.len()
            )));
        }
        let op = body[0];
        let mode = u32::from_be_bytes([body[1], body[2], body[3], body[4]]);
        let mflags = body[5];
        let mut append_from = [0u8; 8];
        append_from.copy_from_slice(&body[6..14]);
        let append_from = u64::from_be_bytes(append_from);
        let path_len = u16::from_be_bytes([body[14], body[15]]) as usize;
        let path_end = BODY_HEADER_BYTES + path_len;
        if body.len() < path_end + 4 {
            return Err(bad(format!(
                "record body is {} bytes, truncated after its path",
                body.len()
            )));
        }
        let path = core::str::from_utf8(&body[BODY_HEADER_BYTES..path_end])
            .map_err(|_| bad("record path is not UTF-8".to_string()))?
            .to_string();
        let data_len =
            u32::from_be_bytes([body[path_end], body[path_end + 1], body[path_end + 2], body[path_end + 3]])
                as usize;
        let data_end = path_end + 4 + data_len;
        if body.len() != data_end {
            return Err(bad(format!(
                "record body is {} bytes but its path/data lengths name {data_end}",
                body.len()
            )));
        }
        let parsed = MutationBody {
            op,
            mode,
            mflags,
            append_from,
            path,
            data: body[path_end + 4..data_end].to_vec(),
        };
        parsed.validate()?;
        Ok(parsed)
    }
}

/// A mutation record: a VFS mutation with its host-allocated mseq.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Mutation {
    /// The VFS mseq; at least 1 and strictly consecutive across the WAL.
    pub mseq: u64,
    /// The mutation body.
    pub body: MutationBody,
}

impl Mutation {
    /// A mutation record, validated.
    pub fn new(mseq: u64, body: MutationBody) -> WalResult<Self> {
        if mseq < 1 {
            return Err(WalError::ZeroMseq);
        }
        body.validate()?;
        Ok(Mutation { mseq, body })
    }
}

/// One WAL record: a mutation or the epoch close of its epoch.
///
/// The two kinds never share a representation: an epoch close has no path, no
/// body layout and no materialized effect, and its wire `mseq` is derived from
/// `durable_upto`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Record {
    /// A VFS mutation (§3).
    Mutation(Mutation),
    /// The epoch-close record (§4).
    EpochClose(EpochClose),
}

impl Record {
    /// A mutation record.
    pub fn mutation(mseq: u64, body: MutationBody) -> WalResult<Self> {
        Ok(Record::Mutation(Mutation::new(mseq, body)?))
    }

    /// The epoch-close record whose wire `mseq` is `durable_upto`.
    pub fn close(wall_ms: u64, durable_upto: u64) -> Self {
        Record::EpochClose(EpochClose::new(wall_ms, durable_upto))
    }

    /// The `mseq` field on the wire. For an epoch close it is `durable_upto`.
    pub fn wire_mseq(&self) -> u64 {
        match self {
            Record::Mutation(mutation) => mutation.mseq,
            Record::EpochClose(close) => close.mseq(),
        }
    }

    /// The mutation mseq, or `None` for an epoch close.
    pub fn mutation_mseq(&self) -> Option<u64> {
        match self {
            Record::Mutation(mutation) => Some(mutation.mseq),
            Record::EpochClose(_) => None,
        }
    }

    /// `true` only for a mutation: the only record that advances
    /// `materialized_upto_mseq` (§4, §10 step 3).
    pub fn advances_materialized(&self) -> bool {
        matches!(self, Record::Mutation(_))
    }

    /// The epoch-close body, or `None` for a mutation.
    pub fn epoch_close(&self) -> Option<&EpochClose> {
        match self {
            Record::EpochClose(close) => Some(close),
            Record::Mutation(_) => None,
        }
    }

    /// The complete record bytes (`len ‖ crc32c ‖ mseq ‖ body`).
    pub fn emit(&self, cks: &dyn Checksum) -> WalResult<Vec<u8>> {
        let (mseq, body) = match self {
            Record::Mutation(mutation) => (mutation.mseq, mutation.body.emit()?),
            Record::EpochClose(close) => (close.mseq(), close.body().to_vec()),
        };
        let payload_len = RECORD_PREFIX_BYTES + body.len();
        if payload_len > u32::MAX as usize {
            return Err(WalError::malformed("record payload exceeds the u32 len"));
        }
        let mut payload = Vec::with_capacity(payload_len);
        payload.extend_from_slice(&mseq.to_be_bytes());
        payload.extend_from_slice(&body);
        let mut out = Vec::with_capacity(RECORD_PREFIX_BYTES + payload_len);
        out.extend_from_slice(&(payload_len as u32).to_be_bytes());
        out.extend_from_slice(&cks.crc32c(&payload).to_be_bytes());
        out.extend_from_slice(&payload);
        Ok(out)
    }

    /// Parses one record at the start of `bytes`; extra trailing bytes are left
    /// to the caller (`byte_len` says how many were consumed).
    pub fn parse(bytes: &[u8], cks: &dyn Checksum) -> Result<ParsedRecord, RecordParseError> {
        if bytes.len() < RECORD_PREFIX_BYTES {
            return Err(RecordParseError::ShortHeader {
                need: RECORD_PREFIX_BYTES,
                have: bytes.len(),
            });
        }
        let len = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
        if len < RECORD_PREFIX_BYTES as u32 {
            return Err(RecordParseError::BadLength(len));
        }
        let total = RECORD_PREFIX_BYTES + len as usize;
        if bytes.len() < total {
            return Err(RecordParseError::ShortRecord {
                total,
                have: bytes.len(),
            });
        }
        let stored = u32::from_be_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);
        let payload = &bytes[RECORD_PREFIX_BYTES..total];
        let computed = cks.crc32c(payload);
        if stored != computed {
            return Err(RecordParseError::CrcMismatch { stored, computed });
        }
        let record = parse_payload(payload).map_err(RecordParseError::Malformed)?;
        Ok(ParsedRecord {
            record,
            byte_len: total,
        })
    }
}

/// `mseq ‖ body` of one record: the CRC input and the two record kinds.
fn parse_payload(payload: &[u8]) -> WalResult<Record> {
    if payload.len() < RECORD_PREFIX_BYTES {
        return Err(WalError::malformed("record payload does not cover mseq"));
    }
    let mut mseq_bytes = [0u8; 8];
    mseq_bytes.copy_from_slice(&payload[0..8]);
    let mseq = u64::from_be_bytes(mseq_bytes);
    let body = &payload[RECORD_PREFIX_BYTES..];
    if body.first() == Some(&OP_EPOCH_CLOSE) {
        let close = EpochClose::parse_body(body)?;
        if close.durable_upto != mseq {
            return Err(WalError::malformed(
                "epoch-close record mseq does not equal durable_upto",
            ));
        }
        return Ok(Record::EpochClose(close));
    }
    if mseq == 0 {
        return Err(WalError::ZeroMseq);
    }
    Ok(Record::Mutation(Mutation {
        mseq,
        body: MutationBody::parse(body)?,
    }))
}

/// One parsed record and the number of bytes it occupied.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedRecord {
    /// The record.
    pub record: Record,
    /// `8 + len`: the bytes consumed at the start of the input.
    pub byte_len: usize,
}

/// Why [`Record::parse`] did not produce a record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RecordParseError {
    /// Fewer than 8 bytes remain for `len` and `crc32c`.
    ShortHeader {
        /// Always 8.
        need: usize,
        /// Bytes available.
        have: usize,
    },
    /// `len < 8`, so the payload cannot even hold `mseq`.
    BadLength(u32),
    /// The record claims `total` bytes but only `have` remain.
    ShortRecord {
        /// `8 + len`.
        total: usize,
        /// Bytes available.
        have: usize,
    },
    /// CRC32C over `mseq ‖ body` does not match the stored value.
    CrcMismatch {
        /// The stored CRC.
        stored: u32,
        /// The computed CRC.
        computed: u32,
    },
    /// The bytes are complete and CRC-verified but the record violates §3/§4.
    Malformed(WalError),
}

/// `true` when an incomplete record's declared `len` agrees with the body
/// header bytes that are present.
///
/// A large mutation is one record (`wal.md` §3), and its `len`, `op`, `mode`,
/// `path_len` and `data_len` are written before the body data. A process killed
/// inside the data therefore leaves a prefix whose declared length is exactly
/// `8 + 16 + path_len + 4 + data_len`. Proving that agreement lets the tail
/// classifier call the file a torn tail without scanning the partial body,
/// which is what burned [`crate::tear::TAIL_SEARCH_CRC_BUDGET`] on legal large
/// records.
///
/// `false` means "not proven"; the caller falls back to the bounded search. A
/// torn record cut before the `data_len` field cannot agree and is left to the
/// (short) search.
pub(crate) fn incomplete_shape_agrees(bytes: &[u8]) -> bool {
    if bytes.len() < RECORD_PREFIX_BYTES {
        return false;
    }
    let len = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as usize;
    if len < RECORD_PREFIX_BYTES {
        return false;
    }
    // `mseq` (8) then the body.
    let payload = &bytes[RECORD_PREFIX_BYTES..];
    if payload.len() < 8 {
        return false;
    }
    let body = &payload[8..];
    if body.is_empty() {
        return false;
    }
    if body[0] == OP_EPOCH_CLOSE {
        // op 1 | wall_ms 8 | durable_upto 8, and the payload also carries mseq 8.
        return len == 8 + 17;
    }
    if body.len() < BODY_HEADER_BYTES + 4 {
        return false;
    }
    let op = body[0];
    if !(OP_WRITE..=OP_CHMOD).contains(&op) {
        return false;
    }
    let mode = u32::from_be_bytes([body[1], body[2], body[3], body[4]]);
    if mode > MAX_MODE {
        return false;
    }
    let mflags = body[5];
    if mflags & !(MFLAG_ENTRY_CHANGED | MFLAG_APPENDED) != 0 {
        return false;
    }
    let path_len = u16::from_be_bytes([body[14], body[15]]) as usize;
    let path_end = BODY_HEADER_BYTES + path_len;
    if body.len() < path_end + 4 {
        return false;
    }
    if std::str::from_utf8(&body[BODY_HEADER_BYTES..path_end]).is_err() {
        return false;
    }
    let data_len = u32::from_be_bytes([
        body[path_end],
        body[path_end + 1],
        body[path_end + 2],
        body[path_end + 3],
    ]) as usize;
    // The declared record payload is mseq (8) + the body it names, no more and
    // no less. A corrupt `len` would have to hit this equation exactly.
    len == 8 + path_end + 4 + data_len
}

impl RecordParseError {
    /// `true` when the failure may be a torn tail (D19): an incomplete `len` or
    /// `crc32c`, an impossible `len`, a record running past the end, or a CRC
    /// mismatch. A malformed but CRC-verified body is never a torn tail: those
    /// bytes were written completely and are simply wrong.
    pub fn is_tail_eligible(&self) -> bool {
        !matches!(self, RecordParseError::Malformed(_))
    }

    /// The [`WalError`] this failure becomes once the tail verdict is known.
    pub fn into_wal_error(self) -> WalError {
        match self {
            RecordParseError::ShortHeader { need, have } => WalError::Truncated { need, have },
            RecordParseError::BadLength(length) => WalError::BadLength(length),
            RecordParseError::ShortRecord { total, have } => WalError::Truncated {
                need: total,
                have,
            },
            RecordParseError::CrcMismatch { stored, computed } => {
                WalError::RecordCrcMismatch { stored, computed }
            }
            RecordParseError::Malformed(error) => error,
        }
    }
}

impl fmt::Display for RecordParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RecordParseError::ShortHeader { need, have } => {
                write!(f, "record prefix is incomplete: need {need} bytes, have {have}")
            }
            RecordParseError::BadLength(length) => {
                write!(f, "record len {length} is smaller than mseq")
            }
            RecordParseError::ShortRecord { total, have } => {
                write!(f, "record claims {total} bytes but only {have} remain")
            }
            RecordParseError::CrcMismatch { stored, computed } => write!(
                f,
                "record CRC32C mismatch: stored {stored:#010x}, computed {computed:#010x}"
            ),
            RecordParseError::Malformed(error) => write!(f, "{error}"),
        }
    }
}

impl std::error::Error for RecordParseError {}

/// The pure mseq-continuity rule of one segment (`wal.md` §3–§4, D3/D17).
///
/// A chain is seeded with the segment header's `first_mseq`. Every mutation must
/// then equal the expected mseq, and an epoch close may appear at most once and
/// only as the last record. The close is *not* checked against the mutation
/// sequence: by §4 its mseq is `durable_upto`, which may be smaller than
/// `first_mseq` (the idle epoch of `golden/wal/segment-epoch-only.json`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordChain {
    first_mseq: u64,
    next_mutation: u64,
    mutations: usize,
    close: Option<EpochClose>,
}

impl RecordChain {
    /// A chain whose first mutation must be `first_mseq`.
    pub fn new(first_mseq: u64) -> Self {
        RecordChain {
            first_mseq,
            next_mutation: first_mseq,
            mutations: 0,
            close: None,
        }
    }

    /// Seeds the chain from a parsed header.
    pub fn from_header(header: &crate::header::SegmentHeader) -> Self {
        RecordChain::new(header.first_mseq)
    }

    /// Appends `record`, enforcing §3–§4 order.
    pub fn push(&mut self, record: &Record) -> WalResult<()> {
        if self.close.is_some() {
            return match record {
                Record::EpochClose(_) => Err(WalError::DuplicateEpochClose),
                Record::Mutation(_) => Err(WalError::RecordAfterEpochClose),
            };
        }
        match record {
            Record::Mutation(mutation) => {
                if mutation.mseq < 1 {
                    return Err(WalError::ZeroMseq);
                }
                if mutation.mseq != self.next_mutation {
                    return Err(WalError::MseqNotConsecutive {
                        expected: self.next_mutation,
                        found: mutation.mseq,
                    });
                }
                self.next_mutation = mutation
                    .mseq
                    .checked_add(1)
                    .ok_or(WalError::MseqExhausted)?;
                self.mutations += 1;
            }
            Record::EpochClose(close) => self.close = Some(*close),
        }
        Ok(())
    }

    /// The `first_mseq` the chain was seeded with.
    pub fn first_mseq(&self) -> u64 {
        self.first_mseq
    }

    /// The mseq the next mutation must carry.
    pub fn next_mutation_mseq(&self) -> u64 {
        self.next_mutation
    }

    /// How many mutations the chain accepted.
    pub fn mutations(&self) -> usize {
        self.mutations
    }

    /// The epoch close, when one was pushed.
    pub fn epoch_close(&self) -> Option<EpochClose> {
        self.close
    }

    /// The highest mutation mseq the chain accepted, 0 when it accepted none
    /// (the manifest's `last_mseq` rule of §7).
    pub fn last_mutation_mseq(&self) -> u64 {
        if self.mutations == 0 {
            0
        } else {
            self.next_mutation - 1
        }
    }
}
