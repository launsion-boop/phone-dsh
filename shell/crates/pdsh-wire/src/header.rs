// SPDX-License-Identifier: MIT
//! The fixed 16-byte frame header of `channel.md` §1.
//!
//! ```text
//! offset 0  : magic   u16 = 0x5A4C
//! offset 2  : type    u8
//! offset 3  : flags   u8 = 0
//! offset 4  : seq     u64
//! offset 12 : len     u32, 1 <= len <= 16 MiB
//! ```
//!
//! Every integer is big-endian. A bad magic is `BAD_MAGIC`; non-zero flags, a
//! zero length or a length above 16 MiB is `BAD_PAYLOAD` (§1, §10).

use core::fmt;

use crate::error::WireError;

/// Header magic of every phone-dsh-v1 frame.
pub const MAGIC: u16 = 0x5A4C;

/// Fixed header size in bytes.
pub const HEADER_LEN: usize = 16;

/// Largest payload a frame may carry: 16 MiB (`channel.md` §1).
pub const MAX_PAYLOAD_LEN: usize = 16 * 1024 * 1024;

/// Largest complete frame: header plus the 16 MiB payload bound.
pub const MAX_FRAME_LEN: usize = HEADER_LEN + MAX_PAYLOAD_LEN;

/// The 16-byte frame header.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct Header {
    /// `type` byte of `channel.md` §2.
    pub type_byte: u8,
    /// `flags`: always zero in proto 1.
    pub flags: u8,
    /// Per-connection, per-direction frame sequence (§7).
    pub seq: u64,
    /// Payload length in bytes.
    pub len: u32,
}

impl Header {
    /// Builds a header for a payload of `payload_len` bytes.
    ///
    /// Rejects `seq = 0` with `BAD_SEQ` (the first frame of a direction is
    /// `seq = 1`, §7) and a payload length outside `1..=16 MiB` with
    /// `BAD_PAYLOAD` (§1).
    pub fn new(type_byte: u8, seq: u64, payload_len: usize) -> Result<Self, WireError> {
        if seq == 0 {
            return Err(WireError::bad_seq("frame seq starts at 1"));
        }
        if payload_len == 0 {
            return Err(WireError::bad_payload("frames have no zero-length payload"));
        }
        if payload_len > MAX_PAYLOAD_LEN {
            return Err(WireError::bad_payload(format!(
                "payload length {payload_len} exceeds {MAX_PAYLOAD_LEN} bytes"
            )));
        }
        let len = u32::try_from(payload_len)
            .map_err(|_| WireError::bad_payload("payload length exceeds a u32"))?;
        Ok(Self {
            type_byte,
            flags: 0,
            seq,
            len,
        })
    }

    /// Parses the first 16 bytes of `bytes`.
    ///
    /// Extra bytes are ignored here; the frame decoder checks that the frame is
    /// exactly `HEADER_LEN + len` bytes long.
    pub fn parse(bytes: &[u8]) -> Result<Self, WireError> {
        if bytes.len() < HEADER_LEN {
            return Err(WireError::bad_payload(format!(
                "frame header is {} bytes, need {HEADER_LEN}",
                bytes.len()
            )));
        }
        let magic = u16::from_be_bytes([bytes[0], bytes[1]]);
        if magic != MAGIC {
            return Err(WireError::bad_magic(magic));
        }
        let type_byte = bytes[2];
        let flags = bytes[3];
        if flags != 0 {
            return Err(WireError::bad_payload(format!(
                "frame flags must be zero, got {flags}"
            )));
        }
        let seq = u64::from_be_bytes([
            bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
        ]);
        let len = u32::from_be_bytes([bytes[12], bytes[13], bytes[14], bytes[15]]);
        if len == 0 {
            return Err(WireError::bad_payload("frames have no zero-length payload"));
        }
        if len as usize > MAX_PAYLOAD_LEN {
            return Err(WireError::bad_payload(format!(
                "payload length {len} exceeds {MAX_PAYLOAD_LEN} bytes"
            )));
        }
        Ok(Self {
            type_byte,
            flags,
            seq,
            len,
        })
    }

    /// Encodes the 16 header bytes (big-endian).
    pub fn emit(&self) -> [u8; HEADER_LEN] {
        let mut bytes = [0u8; HEADER_LEN];
        bytes[0..2].copy_from_slice(&MAGIC.to_be_bytes());
        bytes[2] = self.type_byte;
        bytes[3] = self.flags;
        bytes[4..12].copy_from_slice(&self.seq.to_be_bytes());
        bytes[12..16].copy_from_slice(&self.len.to_be_bytes());
        bytes
    }

    /// Total frame length implied by this header.
    pub fn total_len(&self) -> usize {
        HEADER_LEN + self.len as usize
    }
}

impl fmt::Display for Header {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "type 0x{:02X} seq {} len {}",
            self.type_byte, self.seq, self.len
        )
    }
}
