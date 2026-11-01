// SPDX-License-Identifier: MIT
//! The epoch-close record (`wal.md` §4, D7).
//!
//! Body layout: `op u8 = 0xFF`, `wall_ms u64`, `durable_upto u64`.
//!
//! **The record's `mseq` field is `durable_upto`.** The type makes that
//! unrepresentable as an ordinary mutation: [`EpochClose`] has no `mseq` field
//! at all, its [`EpochClose::mseq`] accessor *is* `durable_upto`, and
//! [`crate::record::Record::advances_materialized`] is false for it. A
//! materializer must never apply a close record and must never advance
//! `materialized_upto_mseq` across it.
//!
//! `durable_upto` is the global maximum mutation mseq appended at the close
//! (0 when none), so it may be smaller than the segment's `first_mseq`: the
//! idle-epoch case of `spec/v1/golden/wal/segment-epoch-only.json`, where
//! `first_mseq = 88` and the close record carries `durable_upto = 87`.

use crate::error::{WalError, WalResult};

/// The `op` byte of the epoch-close record body.
pub const OP_EPOCH_CLOSE: u8 = 0xFF;
/// The fixed body size: `op`, `wall_ms`, `durable_upto`.
pub const EPOCH_CLOSE_BODY_BYTES: usize = 17;

/// An epoch-close record body: the D7 close of one epoch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EpochClose {
    /// Unix epoch milliseconds at the close.
    pub wall_ms: u64,
    /// The global maximum mutation mseq appended at the close (0 when none).
    pub durable_upto: u64,
}

impl EpochClose {
    /// A close of `durable_upto` at `wall_ms`.
    pub fn new(wall_ms: u64, durable_upto: u64) -> Self {
        EpochClose { wall_ms, durable_upto }
    }

    /// The `mseq` field of the record: by D7 it *is* `durable_upto`.
    pub fn mseq(&self) -> u64 {
        self.durable_upto
    }

    /// The 17 record-body bytes.
    pub fn body(&self) -> [u8; EPOCH_CLOSE_BODY_BYTES] {
        let mut body = [0u8; EPOCH_CLOSE_BODY_BYTES];
        body[0] = OP_EPOCH_CLOSE;
        body[1..9].copy_from_slice(&self.wall_ms.to_be_bytes());
        body[9..17].copy_from_slice(&self.durable_upto.to_be_bytes());
        body
    }

    /// Parses a record body that must be exactly 17 bytes starting with `0xFF`.
    pub fn parse_body(body: &[u8]) -> WalResult<Self> {
        if body.len() != EPOCH_CLOSE_BODY_BYTES {
            return Err(WalError::malformed(format!(
                "epoch-close body is {} bytes, expected {EPOCH_CLOSE_BODY_BYTES}",
                body.len()
            )));
        }
        if body[0] != OP_EPOCH_CLOSE {
            return Err(WalError::malformed("epoch-close body does not start with 0xFF"));
        }
        let mut wall_ms = [0u8; 8];
        wall_ms.copy_from_slice(&body[1..9]);
        let mut durable_upto = [0u8; 8];
        durable_upto.copy_from_slice(&body[9..17]);
        Ok(EpochClose {
            wall_ms: u64::from_be_bytes(wall_ms),
            durable_upto: u64::from_be_bytes(durable_upto),
        })
    }
}
