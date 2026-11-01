// SPDX-License-Identifier: MIT
//! Golden-`fields` JSON and `pdsh_wire::Frame` in both directions.
//!
//! The wire codec is `pdsh-wire`; this module only translates the JSON dialect
//! that `spec/v1/golden/README.md` §1–§3 fixes for a frame's `fields` member.
//! For a JSON payload frame `fields` is the payload object itself; for a binary
//! payload frame it is the member table of `golden/README.md` §3 (binary
//! members as lowercase hex strings).
//!
//! `encode_frame` also accepts the whole golden vector object (the `type`,
//! `type_byte`, `seq`, `fields`, `payload_hex` and `frame_hex` members), so a
//! test can feed a golden file in unmodified. Extra members are ignored;
//! `fields` and a frame type are required.

use pdsh_wire::{
    decode_with_header, AckLevel, ApiAbort, ApiEnd, ApiRequest, ApiResponse, Frame, FrameType,
    Journal, JournalAck, JsonObject, JsonValue, VfsAck, VfsBarrier, VfsMutation, VfsOp, VfsResync,
    WireError,
};

/// Encodes one frame from golden-`fields` JSON and a frame `seq`.
///
/// `frame_json` is a JSON object with a `fields` member and either a `type`
/// member (the `channel.md` §2 name) or a `type_byte` member; when both are
/// present they must agree. The members `seq`, `payload_hex` and `frame_hex`
/// of a golden vector are ignored, and the `seq` argument is the one written
/// into the header.
pub fn encode_frame(frame_json: &str, seq: u64) -> Result<Vec<u8>, WireError> {
    let value = JsonValue::parse(frame_json)?;
    let object = value
        .as_object()
        .ok_or_else(|| WireError::bad_payload("frame JSON must be an object"))?;
    let frame_type = frame_type_of(object)?;
    let fields = match object.get("fields") {
        Some(JsonValue::Object(fields)) => fields,
        Some(_) => {
            return Err(WireError::bad_payload(
                "frame JSON fields member must be an object",
            ))
        }
        None => return Err(WireError::bad_payload("frame JSON has no fields member")),
    };
    frame_from_fields(frame_type, fields)?.encode(seq)
}

/// Decodes one complete frame and returns the canonical JSON of its `fields`.
///
/// The frame type is carried by the header and validated by the decoder; this
/// function reports the semantic payload in the golden-`fields` dialect.
pub fn decode_frame(bytes: &[u8]) -> Result<String, WireError> {
    let (_, frame) = decode_with_header(bytes)?;
    Ok(fields_of(&frame)?.to_canonical_json())
}

/// Re-encodes any legal JSON value as canonical JSON (`channel.md` §5).
///
/// A duplicate member, a non-integer number and malformed JSON are
/// `BAD_PAYLOAD`.
pub fn canonical_json(json: &str) -> Result<String, WireError> {
    Ok(JsonValue::parse(json)?.to_canonical_json())
}

fn frame_type_of(object: &JsonObject) -> Result<FrameType, WireError> {
    let by_name = match object.get("type") {
        Some(JsonValue::String(name)) => Some(frame_type_from_name(name)?),
        Some(_) => {
            return Err(WireError::bad_payload(
                "frame JSON type member must be a string",
            ))
        }
        None => None,
    };
    let by_byte = match object.get("type_byte") {
        Some(value) => {
            let byte = value
                .as_u64()
                .and_then(|value| u8::try_from(value).ok())
                .ok_or_else(|| {
                    WireError::bad_payload("frame JSON type_byte member must be an integer 0..=255")
                })?;
            Some(FrameType::from_byte(byte).ok_or_else(|| {
                WireError::bad_payload(format!("unknown frame type byte 0x{byte:02X}"))
            })?)
        }
        None => None,
    };
    match (by_name, by_byte) {
        (Some(by_name), Some(by_byte)) if by_name != by_byte => {
            Err(WireError::bad_payload(format!(
                "frame type {} disagrees with type_byte 0x{:02X}",
                by_name.name(),
                by_byte.byte()
            )))
        }
        (Some(frame_type), _) | (None, Some(frame_type)) => Ok(frame_type),
        (None, None) => Err(WireError::bad_payload(
            "frame JSON needs a type or type_byte member",
        )),
    }
}

fn frame_type_from_name(name: &str) -> Result<FrameType, WireError> {
    FrameType::ALL
        .iter()
        .copied()
        .find(|frame_type| frame_type.name() == name)
        .ok_or_else(|| WireError::bad_payload(format!("unknown frame type name {name:?}")))
}

fn frame_from_fields(frame_type: FrameType, fields: &JsonObject) -> Result<Frame, WireError> {
    Ok(match frame_type {
        FrameType::Hello => Frame::Hello(fields.clone()),
        FrameType::ExecReq => Frame::ExecReq(fields.clone()),
        FrameType::ExecEvt => Frame::ExecEvt(fields.clone()),
        FrameType::ExecCtl => Frame::ExecCtl(fields.clone()),
        FrameType::Lifecycle => Frame::Lifecycle(fields.clone()),
        FrameType::Console => Frame::Console(fields.clone()),
        FrameType::Fence => Frame::Fence(fields.clone()),
        FrameType::Error => Frame::Error(fields.clone()),
        FrameType::VfsMut => Frame::VfsMut(vfs_mutation(fields)?),
        FrameType::VfsAck => Frame::VfsAck(VfsAck {
            level: AckLevel::from_byte(u8_member(fields, "level")?)?,
            upto_mseq: u64_member(fields, "upto_mseq")?,
        }),
        FrameType::VfsBarrier => Frame::VfsBarrier(VfsBarrier {
            want_level: AckLevel::from_byte(u8_member(fields, "want_level")?)?,
            upto_mseq: u64_member(fields, "upto_mseq")?,
        }),
        FrameType::VfsResync => Frame::VfsResync(VfsResync {
            path: string_member(fields, "path")?.to_owned(),
        }),
        FrameType::Journal => Frame::Journal(Journal {
            jseq: u64_member(fields, "jseq")?,
            session_id: string_member(fields, "session_id")?.to_owned(),
            record: hex_member(fields, "record_hex")?,
        }),
        FrameType::JournalAck => Frame::JournalAck(JournalAck {
            level: AckLevel::from_byte(u8_member(fields, "level")?)?,
            session_id: string_member(fields, "session_id")?.to_owned(),
            upto_jseq: u64_member(fields, "upto_jseq")?,
        }),
        FrameType::ApiReq => Frame::ApiReq(ApiRequest {
            req_id: u32_member(fields, "req_id")?,
            head: object_member(fields, "head")?.clone(),
            body: hex_member(fields, "body_hex")?,
        }),
        FrameType::ApiRes => Frame::ApiRes(ApiResponse {
            req_id: u32_member(fields, "req_id")?,
            head: match member(fields, "head")? {
                JsonValue::Null => None,
                JsonValue::Object(head) => Some(head.clone()),
                _ => {
                    return Err(WireError::bad_payload(
                        "API_RES fields head member must be an object or null",
                    ))
                }
            },
            body: hex_member(fields, "body_hex")?,
        }),
        FrameType::ApiEnd => Frame::ApiEnd(ApiEnd {
            req_id: u32_member(fields, "req_id")?,
        }),
        FrameType::ApiAbort => Frame::ApiAbort(ApiAbort {
            req_id: u32_member(fields, "req_id")?,
            reason: string_member(fields, "reason")?.to_owned(),
        }),
    })
}

fn vfs_mutation(fields: &JsonObject) -> Result<VfsMutation, WireError> {
    let data = hex_member(fields, "data_hex")?;
    let data_len = u32_member(fields, "data_len")?;
    if data_len as usize != data.len() {
        return Err(WireError::bad_payload(format!(
            "VFS_MUT data_len is {data_len} but data_hex is {} bytes",
            data.len()
        )));
    }
    Ok(VfsMutation {
        mseq: u64_member(fields, "mseq")?,
        op: VfsOp::from_byte(u8_member(fields, "op")?)?,
        mode: u32_member(fields, "mode")?,
        mflags: u8_member(fields, "mflags")?,
        append_from: u64_member(fields, "append_from")?,
        path: string_member(fields, "path")?.to_owned(),
        data,
    })
}

fn fields_of(frame: &Frame) -> Result<JsonObject, WireError> {
    Ok(match frame {
        Frame::Hello(object)
        | Frame::ExecReq(object)
        | Frame::ExecEvt(object)
        | Frame::ExecCtl(object)
        | Frame::Lifecycle(object)
        | Frame::Console(object)
        | Frame::Fence(object)
        | Frame::Error(object) => object.clone(),
        Frame::VfsMut(mutation) => JsonObject::from_pairs([
            (
                "append_from".to_owned(),
                integer(mutation.append_from.into()),
            ),
            ("data_hex".to_owned(), text(hex_string(&mutation.data))),
            ("data_len".to_owned(), integer(mutation.data.len() as i128)),
            ("mflags".to_owned(), integer(mutation.mflags.into())),
            ("mode".to_owned(), integer(mutation.mode.into())),
            ("mseq".to_owned(), integer(mutation.mseq.into())),
            ("op".to_owned(), integer(mutation.op.byte().into())),
            ("path".to_owned(), text(mutation.path.clone())),
        ])?,
        Frame::VfsAck(ack) => JsonObject::from_pairs([
            ("level".to_owned(), integer(ack.level.byte().into())),
            ("upto_mseq".to_owned(), integer(ack.upto_mseq.into())),
        ])?,
        Frame::VfsBarrier(barrier) => JsonObject::from_pairs([
            (
                "want_level".to_owned(),
                integer(barrier.want_level.byte().into()),
            ),
            ("upto_mseq".to_owned(), integer(barrier.upto_mseq.into())),
        ])?,
        Frame::VfsResync(resync) => {
            JsonObject::from_pairs([("path".to_owned(), text(resync.path.clone()))])?
        }
        Frame::Journal(journal) => JsonObject::from_pairs([
            ("jseq".to_owned(), integer(journal.jseq.into())),
            ("record_hex".to_owned(), text(hex_string(&journal.record))),
            ("session_id".to_owned(), text(journal.session_id.clone())),
        ])?,
        Frame::JournalAck(ack) => JsonObject::from_pairs([
            ("level".to_owned(), integer(ack.level.byte().into())),
            ("session_id".to_owned(), text(ack.session_id.clone())),
            ("upto_jseq".to_owned(), integer(ack.upto_jseq.into())),
        ])?,
        Frame::ApiReq(request) => JsonObject::from_pairs([
            ("body_hex".to_owned(), text(hex_string(&request.body))),
            ("head".to_owned(), JsonValue::Object(request.head.clone())),
            ("req_id".to_owned(), integer(request.req_id.into())),
        ])?,
        Frame::ApiRes(response) => JsonObject::from_pairs([
            ("body_hex".to_owned(), text(hex_string(&response.body))),
            (
                "head".to_owned(),
                match &response.head {
                    Some(head) => JsonValue::Object(head.clone()),
                    None => JsonValue::Null,
                },
            ),
            ("req_id".to_owned(), integer(response.req_id.into())),
        ])?,
        Frame::ApiEnd(end) => {
            JsonObject::from_pairs([("req_id".to_owned(), integer(end.req_id.into()))])?
        }
        Frame::ApiAbort(abort) => JsonObject::from_pairs([
            ("reason".to_owned(), text(abort.reason.clone())),
            ("req_id".to_owned(), integer(abort.req_id.into())),
        ])?,
    })
}

fn member<'a>(fields: &'a JsonObject, name: &str) -> Result<&'a JsonValue, WireError> {
    fields
        .get(name)
        .ok_or_else(|| WireError::bad_payload(format!("fields has no {name:?} member")))
}

fn u64_member(fields: &JsonObject, name: &str) -> Result<u64, WireError> {
    member(fields, name)?.as_u64().ok_or_else(|| {
        WireError::bad_payload(format!(
            "fields {name:?} member must be a non-negative integer"
        ))
    })
}

fn u32_member(fields: &JsonObject, name: &str) -> Result<u32, WireError> {
    let value = u64_member(fields, name)?;
    u32::try_from(value)
        .map_err(|_| WireError::bad_payload(format!("fields {name:?} member exceeds a u32")))
}

fn u8_member(fields: &JsonObject, name: &str) -> Result<u8, WireError> {
    let value = u64_member(fields, name)?;
    u8::try_from(value)
        .map_err(|_| WireError::bad_payload(format!("fields {name:?} member exceeds a u8")))
}

fn string_member<'a>(fields: &'a JsonObject, name: &str) -> Result<&'a str, WireError> {
    member(fields, name)?
        .as_str()
        .ok_or_else(|| WireError::bad_payload(format!("fields {name:?} member must be a string")))
}

fn object_member<'a>(fields: &'a JsonObject, name: &str) -> Result<&'a JsonObject, WireError> {
    member(fields, name)?
        .as_object()
        .ok_or_else(|| WireError::bad_payload(format!("fields {name:?} member must be an object")))
}

fn hex_member(fields: &JsonObject, name: &str) -> Result<Vec<u8>, WireError> {
    let value = string_member(fields, name)?;
    hex_bytes(value).map_err(|error| {
        WireError::bad_payload(format!("fields {name:?} member: {}", error.message()))
    })
}

fn integer(value: i128) -> JsonValue {
    JsonValue::Integer(value)
}

fn text(value: impl Into<String>) -> JsonValue {
    JsonValue::String(value.into())
}

/// Lowercase hex of `bytes` (`golden/README.md` §2).
fn hex_string(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for &byte in bytes {
        out.push(char::from(DIGITS[usize::from(byte >> 4)]));
        out.push(char::from(DIGITS[usize::from(byte & 0x0F)]));
    }
    out
}

/// Decodes lowercase hex; any other character is `BAD_PAYLOAD`.
fn hex_bytes(value: &str) -> Result<Vec<u8>, WireError> {
    let bytes = value.as_bytes();
    if bytes.len() % 2 != 0 {
        return Err(WireError::bad_payload(
            "hex string has an odd number of characters",
        ));
    }
    let mut out = Vec::with_capacity(bytes.len() / 2);
    for pair in bytes.chunks(2) {
        out.push((hex_digit(pair[0])? << 4) | hex_digit(pair[1])?);
    }
    Ok(out)
}

fn hex_digit(byte: u8) -> Result<u8, WireError> {
    match byte {
        b'0'..=b'9' => Ok(byte - b'0'),
        b'a'..=b'f' => Ok(byte - b'a' + 10),
        _ => Err(WireError::bad_payload(format!(
            "hex string contains the non-lowercase-hex character 0x{byte:02X}"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::{canonical_json, decode_frame, encode_frame};

    #[test]
    fn vfs_ack_round_trips() {
        let json = r#"{"type":"VFS_ACK","fields":{"level":1,"upto_mseq":45}}"#;
        let frame = encode_frame(json, 3).expect("encode");
        assert_eq!(
            decode_frame(&frame).expect("decode"),
            r#"{"level":1,"upto_mseq":45}"#
        );
    }

    #[test]
    fn vfs_mut_data_len_must_match_data_hex() {
        let json = r#"{"type":"VFS_MUT","fields":{"mseq":1,"op":1,"mode":420,"mflags":1,"append_from":0,"path":"/dsh/workspace/a","data_hex":"00","data_len":2}}"#;
        let error = encode_frame(json, 1).expect_err("mismatch must fail");
        assert_eq!(error.code(), pdsh_wire::ErrorCode::BadPayload);
    }

    #[test]
    fn type_and_type_byte_must_agree() {
        let json = r#"{"type":"VFS_ACK","type_byte":18,"fields":{"level":1,"upto_mseq":1}}"#;
        let error = encode_frame(json, 1).expect_err("disagreement must fail");
        assert_eq!(error.code(), pdsh_wire::ErrorCode::BadPayload);
    }

    #[test]
    fn canonical_json_sorts_and_rejects_duplicates() {
        assert_eq!(
            canonical_json(r#"{ "b" : 2, "a" : 1 }"#).expect("canonical"),
            r#"{"a":1,"b":2}"#
        );
        let error = canonical_json(r#"{"a":1,"a":2}"#).expect_err("duplicate must fail");
        assert_eq!(error.code(), pdsh_wire::ErrorCode::BadPayload);
    }
}
