// SPDX-License-Identifier: MIT
//! Segment names (`wal.md` §1): `wal/<epoch:08d>.<segment:06d>.xlwal`.
//!
//! Epoch numbers start at 1, segment numbers start at 0 within their epoch.
//! The manifest stores the relative form with the `wal/` prefix
//! (`schema/manifest.schema.json`); a directory entry carries the bare form.
//! Ordering is `<epoch, segment>`, which is also the replay order.

use core::fmt;
use core::str::FromStr;

use crate::error::{WalError, WalResult};

/// The extension every WAL segment file uses.
pub const SEGMENT_EXTENSION: &str = "xlwal";
/// The relative directory prefix of a segment file inside a workspace.
pub const SEGMENT_DIRECTORY: &str = "wal";
/// The largest epoch number the 8-digit form can express.
pub const MAX_EPOCH: u32 = 99_999_999;
/// The largest segment number the 6-digit form can express.
pub const MAX_SEGMENT: u32 = 999_999;

/// An `<epoch, segment>` pair naming one WAL segment file.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SegmentName {
    /// Epoch number, at least 1.
    pub epoch: u32,
    /// Segment number inside its epoch, from 0.
    pub segment: u32,
}

impl SegmentName {
    /// A name, checked against the ranges the fixed-width form allows.
    pub fn new(epoch: u32, segment: u32) -> WalResult<Self> {
        if !(1..=MAX_EPOCH).contains(&epoch) {
            return Err(WalError::BadSegmentName(format!("epoch {epoch}")));
        }
        if segment > MAX_SEGMENT {
            return Err(WalError::BadSegmentName(format!("segment {segment}")));
        }
        Ok(SegmentName { epoch, segment })
    }

    /// The bare file name, `00000001.000000.xlwal`.
    pub fn base_name(&self) -> String {
        format!("{:08}.{:06}.{}", self.epoch, self.segment, SEGMENT_EXTENSION)
    }

    /// The manifest form, `wal/00000001.000000.xlwal`.
    pub fn file(&self) -> String {
        format!("{}/{}", SEGMENT_DIRECTORY, self.base_name())
    }

    /// Parses the manifest form or the bare directory form. Both must use the
    /// zero-padded fixed widths, so one segment has exactly one spelling.
    pub fn parse(text: &str) -> WalResult<Self> {
        let base = text.strip_prefix("wal/").unwrap_or(text);
        let bad = || WalError::BadSegmentName(text.to_string());
        if base.len() != 8 + 1 + 6 + 1 + SEGMENT_EXTENSION.len() {
            return Err(bad());
        }
        let (epoch_text, rest) = base.split_at(8);
        if !rest.starts_with('.') {
            return Err(bad());
        }
        let (segment_text, extension) = rest[1..].split_at(6);
        if extension != format!(".{SEGMENT_EXTENSION}") {
            return Err(bad());
        }
        let digits = |value: &str| -> WalResult<u32> {
            if !value.bytes().all(|b| b.is_ascii_digit()) {
                return Err(bad());
            }
            value.parse::<u32>().map_err(|_| bad())
        };
        let epoch = digits(epoch_text)?;
        let segment = digits(segment_text)?;
        SegmentName::new(epoch, segment).map_err(|_| bad())
    }
}

impl fmt::Display for SegmentName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.file())
    }
}

impl FromStr for SegmentName {
    type Err = WalError;

    fn from_str(text: &str) -> WalResult<Self> {
        SegmentName::parse(text)
    }
}
