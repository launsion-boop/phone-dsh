// SPDX-License-Identifier: MIT
//! `manifest.json` (`wal.md` §7, D11/D17).
//!
//! Fields: `format` (1), `boot_id` (32 lowercase hex), `materialized_upto_mseq`
//! (the strictly contiguous watermark), `last_mseq` (the never-reused high-water
//! mark), `last_durable_epoch` and `segments[]` of
//! `{file, epoch, first_mseq, last_mseq}` in `<epoch,segment>` order.
//!
//! `next_mseq = max(last_mseq, WAL tail) + 1` (D17); truncation never lowers it.
//! The type keeps the two numbers apart: [`Manifest::last_mseq`] is the
//! allocated high-water mark, [`Manifest::materialized_upto_mseq`] is the
//! applied prefix, and [`Manifest::next_mseq`] takes the WAL tail as an
//! argument instead of guessing it.
//!
//! Parsing is strict about the file shape and semantic about the values:
//!
//! * [`WalError::ManifestInvalid`] means the JSON is not the file this crate
//!   writes (unreadable or schema-invalid). `wal.md` §7.2 sends that case to the
//!   missing-manifest rule, so a caller maps it to "no manifest".
//! * [`WalError::Corrupt`] means the file decoded but its contents are
//!   impossible (`materialized_upto_mseq > last_mseq`, a duplicated or
//!   overlapping segment range, a segment file name that disagrees with its
//!   `epoch`). That is `WAL_CORRUPT` and must fail loud instead of being
//!   rebuilt as if the checkpoint were absent.
//!
//! The emitted JSON is canonical in the D5 sense (UTF-8, no insignificant
//! whitespace, members sorted by code point, integers only, `/` unescaped).

use crate::error::{WalError, WalResult};
use crate::json::{self, Json};
use crate::segment::{SegmentName, MAX_EPOCH};

/// The only manifest `format` of proto 1.
pub const MANIFEST_FORMAT: u16 = 1;
/// The 16 raw bytes of the `boot_id`.
pub const BOOT_ID_BYTES: usize = 16;
/// The 32 lowercase hex characters the schema requires.
pub const BOOT_ID_HEX_CHARS: usize = 32;

/// One `segments[]` entry of `manifest.json`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestSegment {
    /// The relative segment name, `wal/<epoch:08d>.<segment:06d>.xlwal`.
    pub file: String,
    /// The epoch number, at least 1.
    pub epoch: u32,
    /// The segment header's `first_mseq`.
    pub first_mseq: u64,
    /// The highest mutation mseq in the segment; 0 when it holds none.
    pub last_mseq: u64,
}

impl ManifestSegment {
    /// The manifest view of a segment.
    pub fn new(name: SegmentName, first_mseq: u64, last_mseq: u64) -> Self {
        ManifestSegment {
            file: name.file(),
            epoch: name.epoch,
            first_mseq,
            last_mseq,
        }
    }

    /// The parsed segment name, cross-checked against [`ManifestSegment::epoch`].
    pub fn name(&self) -> WalResult<SegmentName> {
        let name = SegmentName::parse(&self.file)
            .map_err(|_| WalError::corrupt(format!("manifest lists segment {:?}", self.file)))?;
        if name.epoch != self.epoch {
            return Err(WalError::corrupt(format!(
                "manifest segment {:?} disagrees with its epoch {}",
                self.file, self.epoch
            )));
        }
        Ok(name)
    }
}

/// The WAL checkpoint of one workspace.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Manifest {
    /// `format`, always 1 for proto 1.
    pub format: u16,
    /// The raw 16 boot-id bytes.
    pub boot_id: [u8; BOOT_ID_BYTES],
    /// The strictly contiguous materialized watermark; 0 when none.
    pub materialized_upto_mseq: u64,
    /// The highest mseq ever allocated and accepted at level 1; 0 when none.
    pub last_mseq: u64,
    /// The epoch number of the most recently closed (level-2 durable) epoch.
    pub last_durable_epoch: u32,
    /// The retained segments at the time of the write.
    pub segments: Vec<ManifestSegment>,
}

impl Manifest {
    /// A format-1 manifest.
    pub fn new(
        boot_id: [u8; BOOT_ID_BYTES],
        materialized_upto_mseq: u64,
        last_mseq: u64,
        last_durable_epoch: u32,
        segments: Vec<ManifestSegment>,
    ) -> Self {
        Manifest {
            format: MANIFEST_FORMAT,
            boot_id,
            materialized_upto_mseq,
            last_mseq,
            last_durable_epoch,
            segments,
        }
    }

    /// The `boot_id` as the 32 lowercase hex characters of D6.
    pub fn boot_id_hex(&self) -> String {
        let mut out = String::with_capacity(BOOT_ID_HEX_CHARS);
        for byte in self.boot_id {
            out.push_str(&format!("{byte:02x}"));
        }
        out
    }

    /// The segments in `<epoch,segment>` order (the order of `segments[]`).
    pub fn segments_sorted(&self) -> Vec<&ManifestSegment> {
        let mut sorted: Vec<&ManifestSegment> = self.segments.iter().collect();
        sorted.sort_by(|left, right| {
            left.epoch
                .cmp(&right.epoch)
                .then_with(|| left.file.cmp(&right.file))
        });
        sorted
    }

    /// `next_mseq = max(last_mseq, wal_tail) + 1` (D17).
    pub fn next_mseq(&self, wal_tail: u64) -> WalResult<u64> {
        next_mseq(self.last_mseq, wal_tail)
    }

    /// Semantic validation of §7. Returns [`WalError::Corrupt`] for contents
    /// that cannot be a real checkpoint.
    pub fn validate(&self) -> WalResult<()> {
        if self.format != MANIFEST_FORMAT {
            return Err(WalError::corrupt(format!(
                "manifest format {} is not {MANIFEST_FORMAT}",
                self.format
            )));
        }
        if self.materialized_upto_mseq > self.last_mseq {
            return Err(WalError::corrupt(format!(
                "manifest materialized_upto_mseq {} is above last_mseq {}",
                self.materialized_upto_mseq, self.last_mseq
            )));
        }
        if self.last_durable_epoch > MAX_EPOCH {
            return Err(WalError::corrupt(format!(
                "manifest last_durable_epoch {} is out of range",
                self.last_durable_epoch
            )));
        }
        let mut named: Vec<(SegmentName, &ManifestSegment)> = Vec::with_capacity(self.segments.len());
        for segment in &self.segments {
            let name = segment.name()?;
            if segment.first_mseq < 1 {
                return Err(WalError::corrupt(format!(
                    "manifest segment {} has first_mseq 0",
                    segment.file
                )));
            }
            if segment.last_mseq != 0 && segment.last_mseq < segment.first_mseq {
                return Err(WalError::corrupt(format!(
                    "manifest segment {} has first_mseq {} above last_mseq {}",
                    segment.file, segment.first_mseq, segment.last_mseq
                )));
            }
            if segment.last_mseq > self.last_mseq {
                return Err(WalError::corrupt(format!(
                    "manifest segment {} names mutation {} above last_mseq {}",
                    segment.file, segment.last_mseq, self.last_mseq
                )));
            }
            if named.iter().any(|(other, _)| *other == name) {
                return Err(WalError::corrupt(format!(
                    "manifest lists segment {} twice",
                    segment.file
                )));
            }
            named.push((name, segment));
        }
        named.sort_by_key(|entry| entry.0);
        let mut covered = 0u64;
        for (_, segment) in named {
            if segment.last_mseq == 0 {
                continue;
            }
            if segment.first_mseq <= covered {
                return Err(WalError::corrupt(format!(
                    "manifest segment {} overlaps the mseq range below {}",
                    segment.file, covered
                )));
            }
            covered = segment.last_mseq;
        }
        Ok(())
    }

    /// Parses `manifest.json` text. See the module documentation for the
    /// difference between [`WalError::ManifestInvalid`] and
    /// [`WalError::Corrupt`].
    pub fn parse(text: &str) -> WalResult<Manifest> {
        let value = json::parse(text)
            .map_err(|error| WalError::ManifestInvalid(format!("{error}")))?;
        if value.as_object().is_none() {
            return Err(WalError::ManifestInvalid("not a JSON object".to_string()));
        }
        let format = u16::try_from(require_uint(&value, "format")?).map_err(|_| {
            WalError::ManifestInvalid("format does not fit u16".to_string())
        })?;
        let boot_id = parse_boot_id(require_string(&value, "boot_id")?)?;
        let materialized_upto_mseq = require_uint(&value, "materialized_upto_mseq")?;
        let last_mseq = require_uint(&value, "last_mseq")?;
        let last_durable_epoch = u32::try_from(require_uint(&value, "last_durable_epoch")?)
            .map_err(|_| {
                WalError::ManifestInvalid("last_durable_epoch does not fit u32".to_string())
            })?;
        let segments_value = required_member(&value, "segments")?;
        let segments_array = segments_value.as_array().ok_or_else(|| {
            WalError::ManifestInvalid("segments is not an array".to_string())
        })?;
        let mut segments = Vec::with_capacity(segments_array.len());
        for entry in segments_array {
            if entry.as_object().is_none() {
                return Err(WalError::ManifestInvalid(
                    "a segments[] entry is not an object".to_string(),
                ));
            }
            segments.push(ManifestSegment {
                file: require_string(entry, "file")?.to_string(),
                epoch: u32::try_from(require_uint(entry, "epoch")?).map_err(|_| {
                    WalError::ManifestInvalid("segment epoch does not fit u32".to_string())
                })?,
                first_mseq: require_uint(entry, "first_mseq")?,
                last_mseq: require_uint(entry, "last_mseq")?,
            });
        }
        let manifest = Manifest {
            format,
            boot_id,
            materialized_upto_mseq,
            last_mseq,
            last_durable_epoch,
            segments,
        };
        manifest.validate()?;
        Ok(manifest)
    }

    /// The canonical JSON bytes of §7.1's rewrite.
    pub fn to_json(&self) -> String {
        let mut out = String::with_capacity(256 + self.segments.len() * 96);
        out.push_str("{\"boot_id\":");
        push_json_string(&mut out, &self.boot_id_hex());
        out.push_str(",\"format\":");
        out.push_str(&self.format.to_string());
        out.push_str(",\"last_durable_epoch\":");
        out.push_str(&self.last_durable_epoch.to_string());
        out.push_str(",\"last_mseq\":");
        out.push_str(&self.last_mseq.to_string());
        out.push_str(",\"materialized_upto_mseq\":");
        out.push_str(&self.materialized_upto_mseq.to_string());
        out.push_str(",\"segments\":[");
        for (index, segment) in self.segments_sorted().iter().enumerate() {
            if index > 0 {
                out.push(',');
            }
            out.push_str("{\"epoch\":");
            out.push_str(&segment.epoch.to_string());
            out.push_str(",\"file\":");
            push_json_string(&mut out, &segment.file);
            out.push_str(",\"first_mseq\":");
            out.push_str(&segment.first_mseq.to_string());
            out.push_str(",\"last_mseq\":");
            out.push_str(&segment.last_mseq.to_string());
            out.push('}');
        }
        out.push_str("]}");
        out
    }
}

/// `next_mseq = max(last_mseq, wal_tail) + 1` (D17). Fails when the high-water
/// mark is `u64::MAX`: mseq is never reused.
pub fn next_mseq(last_mseq: u64, wal_tail: u64) -> WalResult<u64> {
    last_mseq
        .max(wal_tail)
        .checked_add(1)
        .ok_or(WalError::MseqExhausted)
}

fn required_member<'a>(value: &'a Json, name: &str) -> WalResult<&'a Json> {
    value.get(name).ok_or_else(|| {
        WalError::ManifestInvalid(format!("missing member {name}"))
    })
}

fn require_uint(value: &Json, name: &str) -> WalResult<u64> {
    required_member(value, name)?
        .as_u64()
        .ok_or_else(|| WalError::ManifestInvalid(format!("member {name} is not an integer")))
}

fn require_string<'a>(value: &'a Json, name: &str) -> WalResult<&'a str> {
    required_member(value, name)?
        .as_str()
        .ok_or_else(|| WalError::ManifestInvalid(format!("member {name} is not a string")))
}

fn parse_boot_id(text: &str) -> WalResult<[u8; BOOT_ID_BYTES]> {
    if text.len() != BOOT_ID_HEX_CHARS {
        return Err(WalError::ManifestInvalid(format!(
            "boot_id is {} characters, expected {BOOT_ID_HEX_CHARS}",
            text.len()
        )));
    }
    let mut boot_id = [0u8; BOOT_ID_BYTES];
    for (index, slot) in boot_id.iter_mut().enumerate() {
        let pair = &text[index * 2..index * 2 + 2];
        if !pair.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)) {
            return Err(WalError::ManifestInvalid(
                "boot_id is not 32 lowercase hex characters".to_string(),
            ));
        }
        *slot = u8::from_str_radix(pair, 16)
            .map_err(|_| WalError::ManifestInvalid("boot_id is not hex".to_string()))?;
    }
    Ok(boot_id)
}

/// Appends `text` as a JSON string. Segment names and hex digests never need an
/// escape, but a caller-built manifest may carry anything, so escape anyway.
fn push_json_string(out: &mut String, text: &str) {
    out.push('"');
    for character in text.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            character if (character as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", character as u32));
            }
            character => out.push(character),
        }
    }
    out.push('"');
}
