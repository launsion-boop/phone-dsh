// SPDX-License-Identifier: MIT
//! The 18 frame types of `channel.md` §2, the [`Frame`] value and the
//! frame-level encoder/decoder.
//!
//! Ten types carry a binary payload (§3) and eight carry canonical JSON (§4).
//! `decode` validates the header (§1), the type byte and the payload structure;
//! the direction rules of §2 and the connection rules of §7 are the channel
//! layer's job. [`FrameType::direction`] exposes the §2 table so that layer can
//! report `PROTO_MISMATCH`.

use crate::canonical_json::JsonObject;
use crate::error::WireError;
use crate::header::{Header, HEADER_LEN};
use crate::payloads::{
    ApiAbort, ApiEnd, ApiRequest, ApiResponse, Journal, JournalAck, VfsAck, VfsBarrier,
    VfsMutation, VfsResync,
};

/// The 18 frame type bytes of `channel.md` §2.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
#[repr(u8)]
pub enum FrameType {
    /// `0x01` HELLO, both directions, JSON.
    Hello = 0x01,
    /// `0x10` VFS_MUT, worker → host, binary.
    VfsMut = 0x10,
    /// `0x11` VFS_ACK, host → worker, binary.
    VfsAck = 0x11,
    /// `0x12` VFS_BARRIER, worker → host, binary.
    VfsBarrier = 0x12,
    /// `0x13` VFS_RESYNC, host → worker, binary.
    VfsResync = 0x13,
    /// `0x20` EXEC_REQ, worker → host, JSON.
    ExecReq = 0x20,
    /// `0x21` EXEC_EVT, host → worker, JSON.
    ExecEvt = 0x21,
    /// `0x22` EXEC_CTL, worker → host, JSON.
    ExecCtl = 0x22,
    /// `0x30` JOURNAL, worker → host, binary.
    Journal = 0x30,
    /// `0x31` JOURNAL_ACK, host → worker, binary.
    JournalAck = 0x31,
    /// `0x40` API_REQ, host → worker, binary.
    ApiReq = 0x40,
    /// `0x41` API_RES, worker → host, binary.
    ApiRes = 0x41,
    /// `0x42` API_END, worker → host, binary.
    ApiEnd = 0x42,
    /// `0x43` API_ABORT, both directions, binary.
    ApiAbort = 0x43,
    /// `0x50` LIFECYCLE, host → worker, JSON.
    Lifecycle = 0x50,
    /// `0x60` CONSOLE, worker → host, JSON.
    Console = 0x60,
    /// `0x70` FENCE, host → worker, JSON.
    Fence = 0x70,
    /// `0x7F` ERROR, both directions, JSON.
    Error = 0x7F,
}

impl FrameType {
    /// Every type, in byte order.
    pub const ALL: [Self; 18] = [
        Self::Hello,
        Self::VfsMut,
        Self::VfsAck,
        Self::VfsBarrier,
        Self::VfsResync,
        Self::ExecReq,
        Self::ExecEvt,
        Self::ExecCtl,
        Self::Journal,
        Self::JournalAck,
        Self::ApiReq,
        Self::ApiRes,
        Self::ApiEnd,
        Self::ApiAbort,
        Self::Lifecycle,
        Self::Console,
        Self::Fence,
        Self::Error,
    ];

    /// The `type` byte.
    pub const fn byte(self) -> u8 {
        self as u8
    }

    /// Resolves a type byte; an unknown byte is `None` (`BAD_PAYLOAD` when it
    /// arrives on the wire, §2).
    pub const fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            0x01 => Some(Self::Hello),
            0x10 => Some(Self::VfsMut),
            0x11 => Some(Self::VfsAck),
            0x12 => Some(Self::VfsBarrier),
            0x13 => Some(Self::VfsResync),
            0x20 => Some(Self::ExecReq),
            0x21 => Some(Self::ExecEvt),
            0x22 => Some(Self::ExecCtl),
            0x30 => Some(Self::Journal),
            0x31 => Some(Self::JournalAck),
            0x40 => Some(Self::ApiReq),
            0x41 => Some(Self::ApiRes),
            0x42 => Some(Self::ApiEnd),
            0x43 => Some(Self::ApiAbort),
            0x50 => Some(Self::Lifecycle),
            0x60 => Some(Self::Console),
            0x70 => Some(Self::Fence),
            0x7F => Some(Self::Error),
            _ => None,
        }
    }

    /// The normative name from the §2 table.
    pub const fn name(self) -> &'static str {
        match self {
            Self::Hello => "HELLO",
            Self::VfsMut => "VFS_MUT",
            Self::VfsAck => "VFS_ACK",
            Self::VfsBarrier => "VFS_BARRIER",
            Self::VfsResync => "VFS_RESYNC",
            Self::ExecReq => "EXEC_REQ",
            Self::ExecEvt => "EXEC_EVT",
            Self::ExecCtl => "EXEC_CTL",
            Self::Journal => "JOURNAL",
            Self::JournalAck => "JOURNAL_ACK",
            Self::ApiReq => "API_REQ",
            Self::ApiRes => "API_RES",
            Self::ApiEnd => "API_END",
            Self::ApiAbort => "API_ABORT",
            Self::Lifecycle => "LIFECYCLE",
            Self::Console => "CONSOLE",
            Self::Fence => "FENCE",
            Self::Error => "ERROR",
        }
    }

    /// Whether the payload is canonical JSON rather than a binary body (§2).
    pub const fn has_json_payload(self) -> bool {
        matches!(
            self,
            Self::Hello
                | Self::ExecReq
                | Self::ExecEvt
                | Self::ExecCtl
                | Self::Lifecycle
                | Self::Console
                | Self::Fence
                | Self::Error
        )
    }

    /// The direction row of the §2 table.
    pub const fn direction(self) -> Direction {
        match self {
            Self::VfsMut
            | Self::VfsBarrier
            | Self::ExecReq
            | Self::ExecCtl
            | Self::Journal
            | Self::ApiRes
            | Self::ApiEnd
            | Self::Console => Direction::WorkerToHost,
            Self::VfsAck
            | Self::VfsResync
            | Self::ExecEvt
            | Self::JournalAck
            | Self::ApiReq
            | Self::Lifecycle
            | Self::Fence => Direction::HostToWorker,
            Self::Hello | Self::ApiAbort | Self::Error => Direction::Both,
        }
    }
}

/// The direction row of the §2 table.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum Direction {
    /// Worker → host only.
    WorkerToHost,
    /// Host → worker only.
    HostToWorker,
    /// Either direction.
    Both,
}

impl Direction {
    /// The `channel.md` §2 spelling.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::WorkerToHost => "worker → host",
            Self::HostToWorker => "host → worker",
            Self::Both => "both",
        }
    }

    /// Whether a host may send a frame of this direction.
    pub const fn allows_host_to_worker(self) -> bool {
        matches!(self, Self::HostToWorker | Self::Both)
    }

    /// Whether a worker may send a frame of this direction.
    pub const fn allows_worker_to_host(self) -> bool {
        matches!(self, Self::WorkerToHost | Self::Both)
    }
}

/// One decoded frame's payload, tagged by type.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Frame {
    /// `0x01` HELLO JSON object (§4.1).
    Hello(JsonObject),
    /// `0x10` VFS_MUT (§3.1).
    VfsMut(VfsMutation),
    /// `0x11` VFS_ACK (§3.2).
    VfsAck(VfsAck),
    /// `0x12` VFS_BARRIER (§3.3).
    VfsBarrier(VfsBarrier),
    /// `0x13` VFS_RESYNC (§3.4).
    VfsResync(VfsResync),
    /// `0x20` EXEC_REQ JSON object (§4.2).
    ExecReq(JsonObject),
    /// `0x21` EXEC_EVT JSON object (§4.3).
    ExecEvt(JsonObject),
    /// `0x22` EXEC_CTL JSON object (§4.4).
    ExecCtl(JsonObject),
    /// `0x30` JOURNAL (§3.5).
    Journal(Journal),
    /// `0x31` JOURNAL_ACK (§3.6).
    JournalAck(JournalAck),
    /// `0x40` API_REQ (§3.7).
    ApiReq(ApiRequest),
    /// `0x41` API_RES (§3.8).
    ApiRes(ApiResponse),
    /// `0x42` API_END (§3.9).
    ApiEnd(ApiEnd),
    /// `0x43` API_ABORT (§3.10).
    ApiAbort(ApiAbort),
    /// `0x50` LIFECYCLE JSON object (§4.5).
    Lifecycle(JsonObject),
    /// `0x60` CONSOLE JSON object (§4.6).
    Console(JsonObject),
    /// `0x70` FENCE JSON object (§4.7).
    Fence(JsonObject),
    /// `0x7F` ERROR JSON object (§4.8).
    Error(JsonObject),
}

impl Frame {
    /// The type of this frame.
    pub const fn frame_type(&self) -> FrameType {
        match self {
            Self::Hello(_) => FrameType::Hello,
            Self::VfsMut(_) => FrameType::VfsMut,
            Self::VfsAck(_) => FrameType::VfsAck,
            Self::VfsBarrier(_) => FrameType::VfsBarrier,
            Self::VfsResync(_) => FrameType::VfsResync,
            Self::ExecReq(_) => FrameType::ExecReq,
            Self::ExecEvt(_) => FrameType::ExecEvt,
            Self::ExecCtl(_) => FrameType::ExecCtl,
            Self::Journal(_) => FrameType::Journal,
            Self::JournalAck(_) => FrameType::JournalAck,
            Self::ApiReq(_) => FrameType::ApiReq,
            Self::ApiRes(_) => FrameType::ApiRes,
            Self::ApiEnd(_) => FrameType::ApiEnd,
            Self::ApiAbort(_) => FrameType::ApiAbort,
            Self::Lifecycle(_) => FrameType::Lifecycle,
            Self::Console(_) => FrameType::Console,
            Self::Fence(_) => FrameType::Fence,
            Self::Error(_) => FrameType::Error,
        }
    }

    /// The JSON object of a JSON payload frame, `None` for a binary payload.
    pub fn json_object(&self) -> Option<&JsonObject> {
        match self {
            Self::Hello(object)
            | Self::ExecReq(object)
            | Self::ExecEvt(object)
            | Self::ExecCtl(object)
            | Self::Lifecycle(object)
            | Self::Console(object)
            | Self::Fence(object)
            | Self::Error(object) => Some(object),
            _ => None,
        }
    }

    /// Encodes the payload bytes after the 16-byte header.
    ///
    /// JSON payloads are emitted as canonical JSON (§5), so a decoded payload
    /// that arrived with other whitespace, member order or escapes re-encodes
    /// to the canonical bytes.
    pub fn encode_payload(&self) -> Result<Vec<u8>, WireError> {
        match self {
            Self::Hello(object)
            | Self::ExecReq(object)
            | Self::ExecEvt(object)
            | Self::ExecCtl(object)
            | Self::Lifecycle(object)
            | Self::Console(object)
            | Self::Fence(object)
            | Self::Error(object) => Ok(object.to_canonical_bytes()),
            Self::VfsMut(mutation) => mutation.encode(),
            Self::VfsAck(ack) => Ok(ack.encode()),
            Self::VfsBarrier(barrier) => Ok(barrier.encode()),
            Self::VfsResync(resync) => resync.encode(),
            Self::Journal(journal) => journal.encode(),
            Self::JournalAck(ack) => ack.encode(),
            Self::ApiReq(request) => request.encode(),
            Self::ApiRes(response) => response.encode(),
            Self::ApiEnd(end) => Ok(end.encode()),
            Self::ApiAbort(abort) => Ok(abort.encode()),
        }
    }

    /// Encodes one complete frame: header with `seq` and the payload.
    pub fn encode(&self, seq: u64) -> Result<Vec<u8>, WireError> {
        let payload = self.encode_payload()?;
        let header = Header::new(self.frame_type().byte(), seq, payload.len())?;
        let mut frame = Vec::with_capacity(HEADER_LEN + payload.len());
        frame.extend_from_slice(&header.emit());
        frame.extend_from_slice(&payload);
        Ok(frame)
    }

    /// Decodes one payload given its type byte (the header is parsed elsewhere).
    pub fn decode_payload(type_byte: u8, payload: &[u8]) -> Result<Self, WireError> {
        let frame_type = FrameType::from_byte(type_byte).ok_or_else(|| {
            WireError::bad_payload(format!("unknown frame type byte 0x{type_byte:02X}"))
        })?;
        match frame_type {
            FrameType::Hello => Ok(Self::Hello(parse_json_object(payload)?)),
            FrameType::VfsMut => Ok(Self::VfsMut(VfsMutation::decode(payload)?)),
            FrameType::VfsAck => Ok(Self::VfsAck(VfsAck::decode(payload)?)),
            FrameType::VfsBarrier => Ok(Self::VfsBarrier(VfsBarrier::decode(payload)?)),
            FrameType::VfsResync => Ok(Self::VfsResync(VfsResync::decode(payload)?)),
            FrameType::ExecReq => Ok(Self::ExecReq(parse_json_object(payload)?)),
            FrameType::ExecEvt => Ok(Self::ExecEvt(parse_json_object(payload)?)),
            FrameType::ExecCtl => Ok(Self::ExecCtl(parse_json_object(payload)?)),
            FrameType::Journal => Ok(Self::Journal(Journal::decode(payload)?)),
            FrameType::JournalAck => Ok(Self::JournalAck(JournalAck::decode(payload)?)),
            FrameType::ApiReq => Ok(Self::ApiReq(ApiRequest::decode(payload)?)),
            FrameType::ApiRes => Ok(Self::ApiRes(ApiResponse::decode(payload)?)),
            FrameType::ApiEnd => Ok(Self::ApiEnd(ApiEnd::decode(payload)?)),
            FrameType::ApiAbort => Ok(Self::ApiAbort(ApiAbort::decode(payload)?)),
            FrameType::Lifecycle => Ok(Self::Lifecycle(parse_json_object(payload)?)),
            FrameType::Console => Ok(Self::Console(parse_json_object(payload)?)),
            FrameType::Fence => Ok(Self::Fence(parse_json_object(payload)?)),
            FrameType::Error => Ok(Self::Error(parse_json_object(payload)?)),
        }
    }
}

fn parse_json_object(payload: &[u8]) -> Result<JsonObject, WireError> {
    JsonObject::parse_bytes(payload)
}

/// Decodes one complete frame (header and payload) and returns it with its
/// header.
///
/// A payload-level failure carries the header's `seq` as `ref_seq`.
pub fn decode_with_header(bytes: &[u8]) -> Result<(Header, Frame), WireError> {
    let header = Header::parse(bytes)?;
    let frame_type = FrameType::from_byte(header.type_byte).ok_or_else(|| {
        WireError::bad_payload(format!(
            "unknown frame type byte 0x{:02X}",
            header.type_byte
        ))
    })?;
    let expected = header.total_len();
    if bytes.len() < expected {
        return Err(WireError::bad_payload(format!(
            "frame payload is truncated: {} bytes after the header, len is {}",
            bytes.len() - HEADER_LEN,
            header.len
        ))
        .with_ref_seq(header.seq));
    }
    if bytes.len() > expected {
        return Err(WireError::bad_payload(format!(
            "frame has {} trailing bytes",
            bytes.len() - expected
        ))
        .with_ref_seq(header.seq));
    }
    let frame =
        Frame::decode_payload(frame_type.byte(), &bytes[HEADER_LEN..]).map_err(|error| {
            if error.ref_seq().is_some() {
                error
            } else {
                error.with_ref_seq(header.seq)
            }
        })?;
    Ok((header, frame))
}

/// Decodes one complete frame and discards the header fields.
pub fn decode(bytes: &[u8]) -> Result<Frame, WireError> {
    decode_with_header(bytes).map(|(_, frame)| frame)
}

/// Encodes one complete frame: the header with `seq` plus the payload.
///
/// This is the free-function form of [`Frame::encode`].
pub fn encode(frame: &Frame, seq: u64) -> Result<Vec<u8>, WireError> {
    frame.encode(seq)
}
