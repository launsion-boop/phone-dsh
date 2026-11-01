// SPDX-License-Identifier: MIT
//! The ten binary payloads of `channel.md` §3.
//!
//! Every integer is big-endian. `decode` validates the wire structure of the
//! payload: field presence, exact length, enumerated byte domains, reserved
//! bits and UTF-8. The semantic rules that need connection state (`mseq`
//! expectations, path scope, fence generation, flow control) belong to the
//! channel layer of `channel.md` §7–§9.

use crate::canonical_json::{JsonObject, JsonValue};
use crate::cursor::{Reader, Writer};
use crate::error::WireError;

/// One VFS mutation carries at most 15 MiB of data (`channel.md` §6); the host
/// rejects a larger `data_len` with `BAD_PAYLOAD`.
pub const MAX_MUTATION_DATA_LEN: usize = 15 * 1024 * 1024;

/// An API request body is at most 4 MiB (`channel.md` §3.7). §3.8 states no
/// separate cap for an API response chunk; the 16 MiB frame bound applies.
pub const MAX_API_BODY_LEN: usize = 4 * 1024 * 1024;

/// `mflags` bit 0: the directory entry changed (create, replace, remove, chmod).
pub const MFLAG_ENTRY_CHANGED: u8 = 0x01;

/// `mflags` bit 1: `data` is the file suffix starting at `append_from`.
pub const MFLAG_APPENDED: u8 = 0x02;

/// Both defined `mflags` bits; bits 2–7 are reserved and must be zero.
pub const MFLAGS_ALL: u8 = MFLAG_ENTRY_CHANGED | MFLAG_APPENDED;

/// VFS mutation operations (`channel.md` §3.1).
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
#[repr(u8)]
pub enum VfsOp {
    /// `op = 1`: write data (complete or appended suffix).
    Write = 1,
    /// `op = 2`: create a directory.
    Mkdir = 2,
    /// `op = 3`: remove a file or directory.
    Remove = 3,
    /// `op = 4`: change permission bits.
    Chmod = 4,
}

impl VfsOp {
    /// The `u8` of §3.1.
    pub const fn byte(self) -> u8 {
        self as u8
    }

    /// Resolves an `op` byte; an unknown operation is `BAD_PAYLOAD`.
    pub fn from_byte(byte: u8) -> Result<Self, WireError> {
        match byte {
            1 => Ok(Self::Write),
            2 => Ok(Self::Mkdir),
            3 => Ok(Self::Remove),
            4 => Ok(Self::Chmod),
            _ => Err(WireError::bad_payload(format!(
                "unknown VFS mutation op {byte}"
            ))),
        }
    }
}

/// VFS_ACK / VFS_BARRIER / JOURNAL_ACK level (`channel.md` §3.2, §3.3, §3.6).
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
#[repr(u8)]
pub enum AckLevel {
    /// Level 1: the `write()` returned; a kill does not lose the bytes.
    Write = 1,
    /// Level 2: the epoch closed with `F_FULLFSYNC` (D18).
    EpochFsync = 2,
}

impl AckLevel {
    /// The level byte.
    pub const fn byte(self) -> u8 {
        self as u8
    }

    /// Resolves a level byte; a value other than 1 or 2 is `BAD_PAYLOAD`.
    pub fn from_byte(byte: u8) -> Result<Self, WireError> {
        match byte {
            1 => Ok(Self::Write),
            2 => Ok(Self::EpochFsync),
            _ => Err(WireError::bad_payload(format!(
                "ack level must be 1 or 2, got {byte}"
            ))),
        }
    }
}

/// VFS_MUT payload (`channel.md` §3.1).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VfsMutation {
    /// Host-allocated mutation sequence, `>= 1`.
    pub mseq: u64,
    /// Mutation operation.
    pub op: VfsOp,
    /// Permission bits for write/mkdir/chmod, 0 for remove.
    pub mode: u32,
    /// `mflags` bits of §3.1.
    pub mflags: u8,
    /// Byte offset the appended suffix starts at, 0 otherwise.
    pub append_from: u64,
    /// UTF-8 absolute path under `/dsh/home/` or `/dsh/workspace/`.
    pub path: String,
    /// Raw file bytes; empty for mkdir/remove/chmod.
    pub data: Vec<u8>,
}

impl VfsMutation {
    /// `mflags` bit 0: the directory entry changed.
    pub fn entry_changed(&self) -> bool {
        self.mflags & MFLAG_ENTRY_CHANGED != 0
    }

    /// `mflags` bit 1: `data` is the suffix starting at `append_from`.
    pub fn appended(&self) -> bool {
        self.mflags & MFLAG_APPENDED != 0
    }

    /// Encodes `mseq ‖ op ‖ mode ‖ mflags ‖ append_from ‖ path_len ‖ path ‖
    /// data_len ‖ data`.
    pub fn encode(&self) -> Result<Vec<u8>, WireError> {
        if self.mseq == 0 {
            return Err(WireError::bad_mseq("VFS_MUT mseq starts at 1"));
        }
        if self.mflags & !MFLAGS_ALL != 0 {
            return Err(WireError::bad_payload(
                "VFS_MUT mflags has reserved bits set",
            ));
        }
        let path = self.path.as_bytes();
        if path.len() > usize::from(u16::MAX) {
            return Err(WireError::bad_payload("VFS_MUT path length exceeds a u16"));
        }
        if self.data.len() > MAX_MUTATION_DATA_LEN {
            return Err(WireError::bad_payload(format!(
                "VFS_MUT data length {} exceeds {MAX_MUTATION_DATA_LEN} bytes",
                self.data.len()
            )));
        }
        let data_len = u32::try_from(self.data.len())
            .map_err(|_| WireError::bad_payload("VFS_MUT data length exceeds a u32"))?;
        let mut writer = Writer::with_capacity(28 + path.len() + self.data.len());
        writer.write_u64(self.mseq);
        writer.write_u8(self.op.byte());
        writer.write_u32(self.mode);
        writer.write_u8(self.mflags);
        writer.write_u64(self.append_from);
        writer.write_u16(path.len() as u16);
        writer.write_bytes(path);
        writer.write_u32(data_len);
        writer.write_bytes(&self.data);
        Ok(writer.into_vec())
    }

    /// Decodes `mseq ‖ body` (`channel.md` §3.1).
    pub fn decode(payload: &[u8]) -> Result<Self, WireError> {
        let mut reader = Reader::new(payload);
        let mseq = reader.read_u64()?;
        if mseq == 0 {
            return Err(WireError::bad_mseq("VFS_MUT mseq starts at 1"));
        }
        let op = VfsOp::from_byte(reader.read_u8()?)?;
        let mode = reader.read_u32()?;
        let mflags = reader.read_u8()?;
        if mflags & !MFLAGS_ALL != 0 {
            return Err(WireError::bad_payload(
                "VFS_MUT mflags has reserved bits set",
            ));
        }
        let append_from = reader.read_u64()?;
        let path_len = usize::from(reader.read_u16()?);
        let path_bytes = reader.read_bytes(path_len)?;
        let path = core::str::from_utf8(path_bytes)
            .map_err(|_| WireError::bad_payload("VFS_MUT path is not valid UTF-8"))?
            .to_owned();
        let data_len = reader.read_u32()? as usize;
        if data_len > MAX_MUTATION_DATA_LEN {
            return Err(WireError::bad_payload(format!(
                "VFS_MUT data length {data_len} exceeds {MAX_MUTATION_DATA_LEN} bytes"
            )));
        }
        let data = reader.read_bytes(data_len)?.to_vec();
        reader.finish()?;
        Ok(Self {
            mseq,
            op,
            mode,
            mflags,
            append_from,
            path,
            data,
        })
    }
}

/// VFS_ACK payload (`channel.md` §3.2).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct VfsAck {
    /// Acknowledged level.
    pub level: AckLevel,
    /// Highest contiguous `mseq` covered.
    pub upto_mseq: u64,
}

impl VfsAck {
    /// Encodes `level ‖ upto_mseq` (9 bytes).
    pub fn encode(&self) -> Vec<u8> {
        let mut writer = Writer::with_capacity(9);
        writer.write_u8(self.level.byte());
        writer.write_u64(self.upto_mseq);
        writer.into_vec()
    }

    /// Decodes a 9-byte VFS_ACK payload.
    pub fn decode(payload: &[u8]) -> Result<Self, WireError> {
        let mut reader = Reader::new(payload);
        let level = AckLevel::from_byte(reader.read_u8()?)?;
        let upto_mseq = reader.read_u64()?;
        reader.finish()?;
        Ok(Self { level, upto_mseq })
    }
}

/// VFS_BARRIER payload (`channel.md` §3.3).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct VfsBarrier {
    /// Requested level, 1 or 2.
    pub want_level: AckLevel,
    /// Highest `mseq` the barrier covers.
    pub upto_mseq: u64,
}

impl VfsBarrier {
    /// Encodes `want_level ‖ upto_mseq` (9 bytes).
    pub fn encode(&self) -> Vec<u8> {
        let mut writer = Writer::with_capacity(9);
        writer.write_u8(self.want_level.byte());
        writer.write_u64(self.upto_mseq);
        writer.into_vec()
    }

    /// Decodes a 9-byte VFS_BARRIER payload.
    pub fn decode(payload: &[u8]) -> Result<Self, WireError> {
        let mut reader = Reader::new(payload);
        let want_level = AckLevel::from_byte(reader.read_u8()?)?;
        let upto_mseq = reader.read_u64()?;
        reader.finish()?;
        Ok(Self {
            want_level,
            upto_mseq,
        })
    }
}

/// VFS_RESYNC payload (`channel.md` §3.4).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VfsResync {
    /// Absolute path under the VFS sink.
    pub path: String,
}

impl VfsResync {
    /// Encodes `path_len ‖ path`.
    pub fn encode(&self) -> Result<Vec<u8>, WireError> {
        let path = self.path.as_bytes();
        if path.len() > usize::from(u16::MAX) {
            return Err(WireError::bad_payload(
                "VFS_RESYNC path length exceeds a u16",
            ));
        }
        let mut writer = Writer::with_capacity(2 + path.len());
        writer.write_u16(path.len() as u16);
        writer.write_bytes(path);
        Ok(writer.into_vec())
    }

    /// Decodes a VFS_RESYNC payload.
    pub fn decode(payload: &[u8]) -> Result<Self, WireError> {
        let mut reader = Reader::new(payload);
        let path_len = usize::from(reader.read_u16()?);
        let path_bytes = reader.read_bytes(path_len)?;
        let path = core::str::from_utf8(path_bytes)
            .map_err(|_| WireError::bad_payload("VFS_RESYNC path is not valid UTF-8"))?
            .to_owned();
        reader.finish()?;
        Ok(Self { path })
    }
}

/// JOURNAL payload (`channel.md` §3.5).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Journal {
    /// Per-session journal sequence, `>= 1`.
    pub jseq: u64,
    /// Session identifier (D6).
    pub session_id: String,
    /// Opaque tool-journal record bytes, at least one byte.
    pub record: Vec<u8>,
}

impl Journal {
    /// Encodes `jseq ‖ session_id_len ‖ session_id ‖ record`.
    pub fn encode(&self) -> Result<Vec<u8>, WireError> {
        if self.jseq == 0 {
            return Err(WireError::bad_payload("JOURNAL jseq starts at 1"));
        }
        let session_id = self.session_id.as_bytes();
        if session_id.len() > usize::from(u16::MAX) {
            return Err(WireError::bad_payload(
                "JOURNAL session_id length exceeds a u16",
            ));
        }
        if self.record.is_empty() {
            return Err(WireError::bad_payload(
                "a JOURNAL record carries at least one byte",
            ));
        }
        let mut writer = Writer::with_capacity(10 + session_id.len() + self.record.len());
        writer.write_u64(self.jseq);
        writer.write_u16(session_id.len() as u16);
        writer.write_bytes(session_id);
        writer.write_bytes(&self.record);
        Ok(writer.into_vec())
    }

    /// Decodes a JOURNAL payload.
    pub fn decode(payload: &[u8]) -> Result<Self, WireError> {
        let mut reader = Reader::new(payload);
        let jseq = reader.read_u64()?;
        if jseq == 0 {
            return Err(WireError::bad_payload("JOURNAL jseq starts at 1"));
        }
        let session_len = usize::from(reader.read_u16()?);
        let session_bytes = reader.read_bytes(session_len)?;
        let session_id = core::str::from_utf8(session_bytes)
            .map_err(|_| WireError::bad_payload("JOURNAL session_id is not valid UTF-8"))?
            .to_owned();
        let record = reader.rest().to_vec();
        if record.is_empty() {
            return Err(WireError::bad_payload(
                "a JOURNAL record carries at least one byte",
            ));
        }
        Ok(Self {
            jseq,
            session_id,
            record,
        })
    }
}

/// JOURNAL_ACK payload (`channel.md` §3.6).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct JournalAck {
    /// Acknowledged level.
    pub level: AckLevel,
    /// Session identifier (D6).
    pub session_id: String,
    /// Highest contiguous `jseq`.
    pub upto_jseq: u64,
}

impl JournalAck {
    /// Encodes `level ‖ session_id_len ‖ session_id ‖ upto_jseq`.
    pub fn encode(&self) -> Result<Vec<u8>, WireError> {
        let session_id = self.session_id.as_bytes();
        if session_id.len() > usize::from(u16::MAX) {
            return Err(WireError::bad_payload(
                "JOURNAL_ACK session_id length exceeds a u16",
            ));
        }
        let mut writer = Writer::with_capacity(11 + session_id.len());
        writer.write_u8(self.level.byte());
        writer.write_u16(session_id.len() as u16);
        writer.write_bytes(session_id);
        writer.write_u64(self.upto_jseq);
        Ok(writer.into_vec())
    }

    /// Decodes a JOURNAL_ACK payload.
    pub fn decode(payload: &[u8]) -> Result<Self, WireError> {
        let mut reader = Reader::new(payload);
        let level = AckLevel::from_byte(reader.read_u8()?)?;
        let session_len = usize::from(reader.read_u16()?);
        if reader.remaining() != session_len + 8 {
            return Err(WireError::bad_payload(
                "JOURNAL_ACK session_id length does not match the payload",
            ));
        }
        let session_bytes = reader.read_bytes(session_len)?;
        let session_id = core::str::from_utf8(session_bytes)
            .map_err(|_| WireError::bad_payload("JOURNAL_ACK session_id is not valid UTF-8"))?
            .to_owned();
        let upto_jseq = reader.read_u64()?;
        reader.finish()?;
        Ok(Self {
            level,
            session_id,
            upto_jseq,
        })
    }
}

/// API_REQ payload (`channel.md` §3.7).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApiRequest {
    /// Request id, unique among in-flight requests of the connection.
    pub req_id: u32,
    /// Canonical JSON head `{method, path, headers}`.
    pub head: JsonObject,
    /// Raw request body, at most 4 MiB.
    pub body: Vec<u8>,
}

impl ApiRequest {
    /// Encodes `req_id ‖ head_len ‖ head ‖ body`.
    pub fn encode(&self) -> Result<Vec<u8>, WireError> {
        if self.body.len() > MAX_API_BODY_LEN {
            return Err(WireError::bad_payload(format!(
                "API_REQ body length {} exceeds {MAX_API_BODY_LEN} bytes",
                self.body.len()
            )));
        }
        let head = self.head.to_canonical_bytes();
        let head_len = u32::try_from(head.len())
            .map_err(|_| WireError::bad_payload("API_REQ head length exceeds a u32"))?;
        let mut writer = Writer::with_capacity(8 + head.len() + self.body.len());
        writer.write_u32(self.req_id);
        writer.write_u32(head_len);
        writer.write_bytes(&head);
        writer.write_bytes(&self.body);
        Ok(writer.into_vec())
    }

    /// Decodes an API_REQ payload.
    pub fn decode(payload: &[u8]) -> Result<Self, WireError> {
        let mut reader = Reader::new(payload);
        let req_id = reader.read_u32()?;
        let head_len = reader.read_u32()? as usize;
        if head_len == 0 {
            return Err(WireError::bad_payload("API_REQ head must not be empty"));
        }
        if head_len > reader.remaining() {
            return Err(WireError::bad_payload(
                "API_REQ head length overruns the payload",
            ));
        }
        let head = JsonObject::parse_bytes(reader.read_bytes(head_len)?)?;
        let body = reader.rest().to_vec();
        if body.len() > MAX_API_BODY_LEN {
            return Err(WireError::bad_payload(format!(
                "API_REQ body length {} exceeds {MAX_API_BODY_LEN} bytes",
                body.len()
            )));
        }
        Ok(Self { req_id, head, body })
    }
}

/// API_RES payload (`channel.md` §3.8).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApiResponse {
    /// Request id.
    pub req_id: u32,
    /// Canonical JSON head `{status, headers}` on the first chunk, `None` when
    /// `head_len = 0` (a continuation chunk).
    pub head: Option<JsonObject>,
    /// Raw response chunk; may be empty.
    pub body: Vec<u8>,
}

impl ApiResponse {
    /// Encodes `req_id ‖ head_len ‖ head ‖ body`.
    ///
    /// `channel.md` §3.8 states no separate body cap; a complete frame is still
    /// bounded by the 16 MiB payload limit of §1.
    pub fn encode(&self) -> Result<Vec<u8>, WireError> {
        let head = match &self.head {
            Some(head) => head.to_canonical_bytes(),
            None => Vec::new(),
        };
        let head_len = u32::try_from(head.len())
            .map_err(|_| WireError::bad_payload("API_RES head length exceeds a u32"))?;
        let mut writer = Writer::with_capacity(8 + head.len() + self.body.len());
        writer.write_u32(self.req_id);
        writer.write_u32(head_len);
        writer.write_bytes(&head);
        writer.write_bytes(&self.body);
        Ok(writer.into_vec())
    }

    /// Decodes an API_RES payload.
    pub fn decode(payload: &[u8]) -> Result<Self, WireError> {
        let mut reader = Reader::new(payload);
        let req_id = reader.read_u32()?;
        let head_len = reader.read_u32()? as usize;
        if head_len > reader.remaining() {
            return Err(WireError::bad_payload(
                "API_RES head length overruns the payload",
            ));
        }
        let head = if head_len == 0 {
            None
        } else {
            Some(JsonObject::parse_bytes(reader.read_bytes(head_len)?)?)
        };
        let body = reader.rest().to_vec();
        Ok(Self { req_id, head, body })
    }
}

/// API_END payload (`channel.md` §3.9): exactly one `req_id`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ApiEnd {
    /// Request id whose response is complete.
    pub req_id: u32,
}

impl ApiEnd {
    /// Encodes the 4-byte payload.
    pub fn encode(&self) -> Vec<u8> {
        self.req_id.to_be_bytes().to_vec()
    }

    /// Decodes a 4-byte API_END payload.
    pub fn decode(payload: &[u8]) -> Result<Self, WireError> {
        if payload.len() != 4 {
            return Err(WireError::bad_payload(format!(
                "API_END payload is {} bytes, expected 4",
                payload.len()
            )));
        }
        let mut reader = Reader::new(payload);
        let req_id = reader.read_u32()?;
        Ok(Self { req_id })
    }
}

/// API_ABORT payload (`channel.md` §3.10): `req_id` followed by the canonical
/// JSON object `{"reason": <string>}`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApiAbort {
    /// Request id to terminate.
    pub req_id: u32,
    /// Reason string inside the JSON object.
    pub reason: String,
}

impl ApiAbort {
    /// Encodes `req_id ‖ {"reason": ...}`.
    pub fn encode(&self) -> Vec<u8> {
        let mut object = JsonObject::new();
        object.insert("reason", JsonValue::String(self.reason.clone()));
        let reason = object.to_canonical_bytes();
        let mut writer = Writer::with_capacity(4 + reason.len());
        writer.write_u32(self.req_id);
        writer.write_bytes(&reason);
        writer.into_vec()
    }

    /// Decodes an API_ABORT payload.
    ///
    /// Unknown members of the reason object are ignored (§4 allows it).
    pub fn decode(payload: &[u8]) -> Result<Self, WireError> {
        let mut reader = Reader::new(payload);
        let req_id = reader.read_u32()?;
        let object = JsonObject::parse_bytes(reader.rest())?;
        let reason = match object.get("reason") {
            Some(JsonValue::String(reason)) => reason.clone(),
            Some(_) => {
                return Err(WireError::bad_payload("API_ABORT reason must be a string"));
            }
            None => {
                return Err(WireError::bad_payload(
                    "API_ABORT payload has no reason member",
                ));
            }
        };
        Ok(Self { req_id, reason })
    }
}
