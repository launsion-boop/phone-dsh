// SPDX-License-Identifier: MIT
//! `pdsh-wire`: the phone-dsh-v1 frame codec.
//!
//! This crate implements the byte-level contract fixed by `spec/v1/channel.md`:
//! the 16-byte big-endian header, the 18 frame types (10 binary payloads and 8
//! canonical JSON payloads), canonical JSON (D5) and CRC32C. It is the Rust
//! carrier of P1; the JNI binding and the Kotlin side consume the public
//! surface re-exported here.
//!
//! The golden vectors in `spec/v1/golden/frames` are the conformance oracle:
//! [`Frame::encode`] reproduces `frame_hex` byte for byte and [`decode`]
//! accepts it again.
//!
//! # Boundaries
//!
//! [`decode`] validates the header and the payload's wire structure only:
//! magic, flags, the 1..=16 MiB payload bound, known type bytes, length fields,
//! UTF-8 and JSON syntax. Connection-level rules of `channel.md` §7, §8 and §10
//! (`seq` monotonicity, expected `mseq`, path scope, fence generation, HELLO
//! capability sets) belong to the channel layer. [`WireError`] can express
//! every §10 code, so one error type crosses the JNI boundary.

#![forbid(unsafe_code)]

pub mod canonical_json;
pub mod crc32c;
pub mod error;
pub mod frames;
pub mod header;
pub mod payloads;

mod cursor;

pub use canonical_json::{JsonObject, JsonValue};
pub use crc32c::crc32c;
pub use error::{ErrorCode, WireError};
pub use frames::{decode, decode_with_header, encode, Direction, Frame, FrameType};
pub use header::{Header, HEADER_LEN, MAGIC, MAX_FRAME_LEN, MAX_PAYLOAD_LEN};
pub use payloads::{
    AckLevel, ApiAbort, ApiEnd, ApiRequest, ApiResponse, Journal, JournalAck, VfsAck, VfsBarrier,
    VfsMutation, VfsOp, VfsResync, MAX_API_BODY_LEN, MAX_MUTATION_DATA_LEN, MFLAGS_ALL,
    MFLAG_APPENDED, MFLAG_ENTRY_CHANGED,
};
