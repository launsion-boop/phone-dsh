// SPDX-License-Identifier: MIT
//! Wire error codes of `channel.md` §10 and the codec's error value.
//!
//! The codec itself reports wire-format failures (`BAD_MAGIC`, `BAD_PAYLOAD`,
//! `BAD_MSEQ`). The connection layer owns the semantic rules (`BAD_SEQ`
//! monotonicity, expected `mseq`, path scope, fence generation, capability sets)
//! but builds the same [`WireError`], so one error type crosses the JNI
//! boundary and one constant table names the codes.

use core::fmt;

/// The ten error codes fixed by `channel.md` §10.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum ErrorCode {
    /// Header magic is not `0x5A4C`.
    BadMagic,
    /// Inbound `seq` is not the exact next value.
    BadSeq,
    /// `VFS_MUT` `mseq` is not the expected value (or is zero).
    BadMseq,
    /// A `VFS_MUT` or `VFS_RESYNC` path violates §6.
    BadPath,
    /// Malformed payload, unknown type byte, non-zero flags, length out of
    /// range, bad JSON, identifier, capability set, level or length field.
    BadPayload,
    /// Execution authority is stale.
    FenceStale,
    /// A `VFS_RESYNC` cannot be answered because the path is no longer a
    /// regular file.
    VfsConflict,
    /// A mutation is refused for a resource limit; diagnostic, does not close.
    VfsRefused,
    /// 32 MiB unacked and no ack progress for 30 s.
    RingTimeout,
    /// HELLO `proto` is not 1, a HELLO rule is broken or a known type arrives
    /// in the wrong direction.
    ProtoMismatch,
}

impl ErrorCode {
    /// Every code, in the order of the §10 table.
    pub const ALL: [Self; 10] = [
        Self::BadMagic,
        Self::BadSeq,
        Self::BadMseq,
        Self::BadPath,
        Self::BadPayload,
        Self::FenceStale,
        Self::VfsConflict,
        Self::VfsRefused,
        Self::RingTimeout,
        Self::ProtoMismatch,
    ];

    /// The uppercase wire name from the §10 table.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::BadMagic => "BAD_MAGIC",
            Self::BadSeq => "BAD_SEQ",
            Self::BadMseq => "BAD_MSEQ",
            Self::BadPath => "BAD_PATH",
            Self::BadPayload => "BAD_PAYLOAD",
            Self::FenceStale => "FENCE_STALE",
            Self::VfsConflict => "VFS_CONFLICT",
            Self::VfsRefused => "VFS_REFUSED",
            Self::RingTimeout => "RING_TIMEOUT",
            Self::ProtoMismatch => "PROTO_MISMATCH",
        }
    }

    /// Whether the failure closes the channel; every code but `VFS_REFUSED`
    /// does (§10).
    pub const fn closes_connection(self) -> bool {
        !matches!(self, Self::VfsRefused)
    }
}

impl fmt::Display for ErrorCode {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

/// One wire failure: a §10 code, a human-readable detail and the `seq` of the
/// offending frame when it is known.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WireError {
    code: ErrorCode,
    message: String,
    ref_seq: Option<u64>,
}

impl WireError {
    /// Builds an error from a code and a detail message.
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            ref_seq: None,
        }
    }

    /// The §10 code.
    pub fn code(&self) -> ErrorCode {
        self.code
    }

    /// The human-readable detail (never a wire field).
    pub fn message(&self) -> &str {
        &self.message
    }

    /// The `seq` of the offending frame, when the caller knows it.
    pub fn ref_seq(&self) -> Option<u64> {
        self.ref_seq
    }

    /// Attaches the offending frame's `seq`; this is the `ref_seq` member of a
    /// §4.8 ERROR payload.
    pub fn with_ref_seq(mut self, seq: u64) -> Self {
        self.ref_seq = Some(seq);
        self
    }

    /// `BAD_MAGIC` for a header whose first two bytes are `magic`.
    pub fn bad_magic(magic: u16) -> Self {
        Self::new(
            ErrorCode::BadMagic,
            format!("frame magic is 0x{magic:04X}, expected 0x5A4C"),
        )
    }

    /// `BAD_SEQ`: the connection layer's sequence rule of §7.
    pub fn bad_seq(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::BadSeq, message)
    }

    /// `BAD_MSEQ`: a mutation sequence that is zero or not the expected value.
    pub fn bad_mseq(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::BadMseq, message)
    }

    /// `BAD_PATH`: a path outside the mutation sink of §6.
    pub fn bad_path(path: &str) -> Self {
        Self::new(
            ErrorCode::BadPath,
            format!("path violates channel.md §6: {path:?}"),
        )
    }

    /// `BAD_PAYLOAD`: a wire-format violation.
    pub fn bad_payload(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::BadPayload, message)
    }

    /// `PROTO_MISMATCH`: a HELLO rule or frame direction violation.
    pub fn proto_mismatch(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::ProtoMismatch, message)
    }
}

impl fmt::Display for WireError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.code.as_str())?;
        formatter.write_str(": ")?;
        formatter.write_str(&self.message)?;
        if let Some(seq) = self.ref_seq {
            write!(formatter, " (ref_seq {seq})")?;
        }
        Ok(())
    }
}

impl std::error::Error for WireError {}
