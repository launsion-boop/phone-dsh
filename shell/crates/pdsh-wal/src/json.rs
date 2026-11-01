// SPDX-License-Identifier: MIT
//! A minimal JSON reader for `manifest.json` (`wal.md` §7) and the conformance
//! tests.
//!
//! This is deliberately **not** a general JSON parser. It accepts exactly the
//! subset the host writes and the golden vectors use:
//!
//! * objects, arrays, strings, `true`, `false`, `null` and unsigned integers;
//! * no floats, no exponents, no negative numbers (every manifest value is a
//!   non-negative integer), no `\u` escapes (canonical JSON of D5 never needs
//!   them for this file), no comments;
//! * duplicate object members are rejected (D5 forbids them).
//!
//! The subset is small so that this crate stays dependency-free while the
//! manifest still has a single typed reader: [`crate::manifest::Manifest`]
//! maps this value tree onto its fields and rejects everything else. Decoders
//! may ignore unknown members (`spec/v1/README.md` §2); the caller's schema
//! check is the stricter gate.

use core::fmt;

/// A JSON value of the supported subset.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Json {
    /// `null`.
    Null,
    /// `true` or `false`.
    Bool(bool),
    /// A non-negative integer that fits `u64`.
    Uint(u64),
    /// A string.
    String(String),
    /// An array.
    Array(Vec<Json>),
    /// An object; members keep file order and no name repeats.
    Object(Vec<(String, Json)>),
}

impl Json {
    /// The member `name` of an object.
    pub fn get(&self, name: &str) -> Option<&Json> {
        match self {
            Json::Object(members) => members
                .iter()
                .find_map(|(key, value)| (key == name).then_some(value)),
            _ => None,
        }
    }

    /// The value as a `u64`.
    pub fn as_u64(&self) -> Option<u64> {
        match self {
            Json::Uint(value) => Some(*value),
            _ => None,
        }
    }

    /// The value as a string slice.
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::String(value) => Some(value),
            _ => None,
        }
    }

    /// The value as an array.
    pub fn as_array(&self) -> Option<&[Json]> {
        match self {
            Json::Array(values) => Some(values),
            _ => None,
        }
    }

    /// The value as an object's members.
    pub fn as_object(&self) -> Option<&[(String, Json)]> {
        match self {
            Json::Object(members) => Some(members),
            _ => None,
        }
    }
}

/// Why the text is not in the supported subset.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct JsonError {
    message: &'static str,
    offset: usize,
}

impl JsonError {
    /// The byte offset the parser stopped at.
    pub fn offset(&self) -> usize {
        self.offset
    }

    /// The fixed reason text.
    pub fn message(&self) -> &'static str {
        self.message
    }
}

impl fmt::Display for JsonError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} at byte {}", self.message, self.offset)
    }
}

impl std::error::Error for JsonError {}

/// The deepest nesting the reader accepts. Every file this crate reads is two
/// levels deep; the cap keeps a hostile input from exhausting the stack.
pub const MAX_DEPTH: usize = 32;

/// Parses one JSON value from the whole of `text`.
pub fn parse(text: &str) -> Result<Json, JsonError> {
    let mut parser = Parser {
        bytes: text.as_bytes(),
        pos: 0,
    };
    parser.skip_whitespace();
    let value = parser.value(0)?;
    parser.skip_whitespace();
    if parser.pos != parser.bytes.len() {
        return Err(parser.error("trailing bytes after the JSON value"));
    }
    Ok(value)
}

struct Parser<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Parser<'a> {
    fn error(&self, message: &'static str) -> JsonError {
        JsonError {
            message,
            offset: self.pos,
        }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn skip_whitespace(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.pos += 1;
        }
    }

    fn expect(&mut self, byte: u8, message: &'static str) -> Result<(), JsonError> {
        if self.peek() != Some(byte) {
            return Err(self.error(message));
        }
        self.pos += 1;
        Ok(())
    }

    fn value(&mut self, depth: usize) -> Result<Json, JsonError> {
        if depth > MAX_DEPTH {
            return Err(self.error("JSON nesting is too deep"));
        }
        match self.peek() {
            Some(b'{') => self.object(depth),
            Some(b'[') => self.array(depth),
            Some(b'"') => Ok(Json::String(self.string()?)),
            Some(b't') => self.literal(b"true", Json::Bool(true)),
            Some(b'f') => self.literal(b"false", Json::Bool(false)),
            Some(b'n') => self.literal(b"null", Json::Null),
            Some(byte) if byte.is_ascii_digit() => self.uint(),
            _ => Err(self.error("expected a JSON value")),
        }
    }

    fn literal(&mut self, text: &[u8], value: Json) -> Result<Json, JsonError> {
        if self.bytes[self.pos..].starts_with(text) {
            self.pos += text.len();
            Ok(value)
        } else {
            Err(self.error("unknown JSON literal"))
        }
    }

    fn object(&mut self, depth: usize) -> Result<Json, JsonError> {
        self.expect(b'{', "expected an object")?;
        let mut members: Vec<(String, Json)> = Vec::new();
        self.skip_whitespace();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(Json::Object(members));
        }
        loop {
            self.skip_whitespace();
            let name = self.string()?;
            if members.iter().any(|(key, _)| key == &name) {
                return Err(self.error("duplicate object member"));
            }
            self.skip_whitespace();
            self.expect(b':', "expected a member separator")?;
            self.skip_whitespace();
            let value = self.value(depth + 1)?;
            members.push((name, value));
            self.skip_whitespace();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b'}') => {
                    self.pos += 1;
                    return Ok(Json::Object(members));
                }
                _ => return Err(self.error("expected ',' or '}'")),
            }
        }
    }

    fn array(&mut self, depth: usize) -> Result<Json, JsonError> {
        self.expect(b'[', "expected an array")?;
        let mut values = Vec::new();
        self.skip_whitespace();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(Json::Array(values));
        }
        loop {
            self.skip_whitespace();
            values.push(self.value(depth + 1)?);
            self.skip_whitespace();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b']') => {
                    self.pos += 1;
                    return Ok(Json::Array(values));
                }
                _ => return Err(self.error("expected ',' or ']'")),
            }
        }
    }

    fn string(&mut self) -> Result<String, JsonError> {
        self.expect(b'"', "expected a string")?;
        let mut out: Vec<u8> = Vec::new();
        loop {
            match self.peek() {
                None => return Err(self.error("unterminated string")),
                Some(b'"') => {
                    self.pos += 1;
                    return String::from_utf8(out).map_err(|_| self.error("string is not UTF-8"));
                }
                Some(b'\\') => {
                    self.pos += 1;
                    let escape = self.peek().ok_or_else(|| self.error("unterminated escape"))?;
                    self.pos += 1;
                    match escape {
                        b'"' => out.push(b'"'),
                        b'\\' => out.push(b'\\'),
                        b'/' => out.push(b'/'),
                        b'b' => out.push(0x08),
                        b'f' => out.push(0x0c),
                        b'n' => out.push(b'\n'),
                        b'r' => out.push(b'\r'),
                        b't' => out.push(b'\t'),
                        // Canonical JSON of this project never needs a `\u`
                        // escape: the manifest and the golden vectors are ASCII.
                        _ => return Err(self.error("unsupported string escape")),
                    }
                }
                Some(byte) if byte < 0x20 => {
                    return Err(self.error("raw control character in a string"))
                }
                Some(byte) => {
                    out.push(byte);
                    self.pos += 1;
                }
            }
        }
    }

    fn uint(&mut self) -> Result<Json, JsonError> {
        let start = self.pos;
        while matches!(self.peek(), Some(byte) if byte.is_ascii_digit()) {
            self.pos += 1;
        }
        let text = core::str::from_utf8(&self.bytes[start..self.pos])
            .map_err(|_| self.error("number is not ASCII"))?;
        if text.len() > 1 && text.starts_with('0') {
            return Err(self.error("number has a leading zero"));
        }
        let value = text
            .parse::<u64>()
            .map_err(|_| self.error("number does not fit u64"))?;
        Ok(Json::Uint(value))
    }
}
