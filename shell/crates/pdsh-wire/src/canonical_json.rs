// SPDX-License-Identifier: MIT
//! Canonical JSON of `channel.md` §5 (decision D5) and a strict JSON parser.
//!
//! Encoding: UTF-8, no insignificant whitespace, member names sorted by Unicode
//! code point, `/` never escaped, integers only (no fraction, exponent or
//! `-0`), no duplicate member name, non-ASCII emitted literally, `\"` and `\\`
//! escaped and control characters as `\b \f \n \r \t` or lowercase `\u00xx`.
//!
//! Decoding accepts any legal JSON object regardless of member order,
//! whitespace or escapes, then re-encodes canonically. A duplicate member, a
//! non-integer number or malformed JSON is `BAD_PAYLOAD` (§5).
//!
//! Sorting rule: a [`JsonObject`] keeps its members sorted by [`str`] order.
//! For valid UTF-8, byte order and Unicode code point order are the same order
//! (UTF-8 is order-preserving), which is exactly the §5 rule; the choice is
//! documented at [`JsonObject::from_pairs`].

use core::fmt::Write as _;

use crate::error::WireError;

/// Maximum nesting depth the parser accepts.
///
/// The protocol payloads are shallow (the deepest is a fence object inside a
/// HELLO); the bound keeps a hostile 16 MiB payload from exhausting the stack.
pub const MAX_JSON_DEPTH: usize = 128;

/// One JSON value with integer-only numbers.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum JsonValue {
    /// `null`.
    Null,
    /// `true` or `false`.
    Bool(bool),
    /// An integer; the wire has no fraction, exponent or `-0`.
    Integer(i128),
    /// A UTF-8 string.
    String(String),
    /// An array.
    Array(Vec<JsonValue>),
    /// An object with canonically sorted, unique member names.
    Object(JsonObject),
}

impl JsonValue {
    /// Parses one legal JSON value.
    ///
    /// Rejects a duplicate object member, a number with a fraction or an
    /// exponent, malformed input, trailing characters and nesting deeper than
    /// [`MAX_JSON_DEPTH`], all as `BAD_PAYLOAD`.
    pub fn parse(text: &str) -> Result<Self, WireError> {
        let mut parser = Parser::new(text);
        parser.skip_whitespace();
        let value = parser.parse_value(0)?;
        parser.skip_whitespace();
        if parser.offset != parser.bytes.len() {
            return Err(WireError::bad_payload(
                "trailing characters after the JSON value",
            ));
        }
        Ok(value)
    }

    /// Parses one legal JSON value from UTF-8 bytes.
    pub fn parse_bytes(bytes: &[u8]) -> Result<Self, WireError> {
        let text = core::str::from_utf8(bytes)
            .map_err(|_| WireError::bad_payload("JSON payload is not valid UTF-8"))?;
        Self::parse(text)
    }

    /// Encodes this value as canonical JSON (§5).
    pub fn to_canonical_json(&self) -> String {
        let mut out = String::new();
        write_value(&mut out, self);
        out
    }

    /// Encodes this value as canonical UTF-8 bytes.
    pub fn to_canonical_bytes(&self) -> Vec<u8> {
        self.to_canonical_json().into_bytes()
    }

    /// The object behind this value, when it is one.
    pub fn as_object(&self) -> Option<&JsonObject> {
        match self {
            Self::Object(object) => Some(object),
            _ => None,
        }
    }

    /// The array behind this value, when it is one.
    pub fn as_array(&self) -> Option<&[JsonValue]> {
        match self {
            Self::Array(items) => Some(items),
            _ => None,
        }
    }

    /// The string behind this value, when it is one.
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Self::String(value) => Some(value),
            _ => None,
        }
    }

    /// The boolean behind this value, when it is one.
    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Self::Bool(value) => Some(*value),
            _ => None,
        }
    }

    /// The integer behind this value, when it is one.
    pub fn as_integer(&self) -> Option<i128> {
        match self {
            Self::Integer(value) => Some(*value),
            _ => None,
        }
    }

    /// The integer behind this value as a `u64`, when it fits.
    pub fn as_u64(&self) -> Option<u64> {
        match self {
            Self::Integer(value) if *value >= 0 && *value <= i128::from(u64::MAX) => {
                Some(*value as u64)
            }
            _ => None,
        }
    }

    /// The integer behind this value as an `i64`, when it fits.
    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Self::Integer(value)
                if *value >= i128::from(i64::MIN) && *value <= i128::from(i64::MAX) =>
            {
                Some(*value as i64)
            }
            _ => None,
        }
    }
}

/// A JSON object: unique member names, sorted by code point.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct JsonObject {
    members: Vec<(String, JsonValue)>,
}

impl JsonObject {
    /// An empty object.
    pub fn new() -> Self {
        Self {
            members: Vec::new(),
        }
    }

    /// Builds an object from members in any order.
    ///
    /// The members are sorted by byte order, which for valid UTF-8 is Unicode
    /// code point order (UTF-8 preserves code point order), the rule of
    /// `channel.md` §5. A duplicate member name is `BAD_PAYLOAD`.
    pub fn from_pairs<I>(pairs: I) -> Result<Self, WireError>
    where
        I: IntoIterator<Item = (String, JsonValue)>,
    {
        let mut object = Self {
            members: pairs.into_iter().collect(),
        };
        object.members.sort_by(|left, right| left.0.cmp(&right.0));
        for pair in object.members.windows(2) {
            if pair[0].0 == pair[1].0 {
                return Err(WireError::bad_payload(format!(
                    "duplicate JSON member name {:?}",
                    pair[0].0
                )));
            }
        }
        Ok(object)
    }

    /// Parses a JSON value and requires it to be an object.
    pub fn parse(text: &str) -> Result<Self, WireError> {
        match JsonValue::parse(text)? {
            JsonValue::Object(object) => Ok(object),
            _ => Err(WireError::bad_payload("a JSON payload must be an object")),
        }
    }

    /// Parses UTF-8 JSON bytes and requires the root to be an object.
    pub fn parse_bytes(bytes: &[u8]) -> Result<Self, WireError> {
        match JsonValue::parse_bytes(bytes)? {
            JsonValue::Object(object) => Ok(object),
            _ => Err(WireError::bad_payload("a JSON payload must be an object")),
        }
    }

    /// Inserts or replaces one member, returning the previous value.
    pub fn insert(&mut self, key: impl Into<String>, value: JsonValue) -> Option<JsonValue> {
        let key = key.into();
        match self
            .members
            .binary_search_by(|probe| probe.0.as_str().cmp(key.as_str()))
        {
            Ok(index) => Some(core::mem::replace(&mut self.members[index].1, value)),
            Err(index) => {
                self.members.insert(index, (key, value));
                None
            }
        }
    }

    /// The value of one member.
    pub fn get(&self, key: &str) -> Option<&JsonValue> {
        self.members
            .binary_search_by(|probe| probe.0.as_str().cmp(key))
            .ok()
            .map(|index| &self.members[index].1)
    }

    /// The number of members.
    pub fn len(&self) -> usize {
        self.members.len()
    }

    /// Whether the object has no members.
    pub fn is_empty(&self) -> bool {
        self.members.is_empty()
    }

    /// Members in canonical order (code point order).
    pub fn iter(&self) -> impl Iterator<Item = (&str, &JsonValue)> {
        self.members
            .iter()
            .map(|(key, value)| (key.as_str(), value))
    }

    /// Encodes this object as canonical JSON (§5).
    pub fn to_canonical_json(&self) -> String {
        let mut out = String::new();
        write_object(&mut out, self);
        out
    }

    /// Encodes this object as canonical UTF-8 bytes.
    pub fn to_canonical_bytes(&self) -> Vec<u8> {
        self.to_canonical_json().into_bytes()
    }
}

fn write_value(out: &mut String, value: &JsonValue) {
    match value {
        JsonValue::Null => out.push_str("null"),
        JsonValue::Bool(true) => out.push_str("true"),
        JsonValue::Bool(false) => out.push_str("false"),
        JsonValue::Integer(number) => {
            let _ = write!(out, "{number}");
        }
        JsonValue::String(text) => write_string(out, text),
        JsonValue::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_value(out, item);
            }
            out.push(']');
        }
        JsonValue::Object(object) => write_object(out, object),
    }
}

fn write_object(out: &mut String, object: &JsonObject) {
    out.push('{');
    for (index, (key, value)) in object.members.iter().enumerate() {
        if index > 0 {
            out.push(',');
        }
        write_string(out, key);
        out.push(':');
        write_value(out, value);
    }
    out.push('}');
}

fn write_string(out: &mut String, text: &str) {
    out.push('"');
    for character in text.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0C}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            control if (control as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", control as u32);
            }
            other => out.push(other),
        }
    }
    out.push('"');
}

struct Parser<'a> {
    text: &'a str,
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Parser<'a> {
    fn new(text: &'a str) -> Self {
        Self {
            text,
            bytes: text.as_bytes(),
            offset: 0,
        }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.offset).copied()
    }

    fn bump(&mut self) -> Option<u8> {
        let byte = self.peek()?;
        self.offset += 1;
        Some(byte)
    }

    fn skip_whitespace(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\n' | b'\r')) {
            self.offset += 1;
        }
    }

    fn expect(&mut self, byte: u8, what: &str) -> Result<(), WireError> {
        match self.bump() {
            Some(found) if found == byte => Ok(()),
            _ => Err(WireError::bad_payload(format!(
                "expected {what} in JSON payload"
            ))),
        }
    }

    fn parse_value(&mut self, depth: usize) -> Result<JsonValue, WireError> {
        if depth > MAX_JSON_DEPTH {
            return Err(WireError::bad_payload(
                "JSON nesting is deeper than the codec allows",
            ));
        }
        self.skip_whitespace();
        match self.peek() {
            None => Err(WireError::bad_payload("unexpected end of JSON payload")),
            Some(b'{') => self.parse_object(depth),
            Some(b'[') => self.parse_array(depth),
            Some(b'"') => Ok(JsonValue::String(self.parse_string()?)),
            Some(b't') => self.parse_literal("true", JsonValue::Bool(true)),
            Some(b'f') => self.parse_literal("false", JsonValue::Bool(false)),
            Some(b'n') => self.parse_literal("null", JsonValue::Null),
            Some(b'-' | b'0'..=b'9') => self.parse_number(),
            Some(_) => Err(WireError::bad_payload("unexpected character in JSON value")),
        }
    }

    fn parse_literal(&mut self, literal: &str, value: JsonValue) -> Result<JsonValue, WireError> {
        if self.bytes[self.offset..].starts_with(literal.as_bytes()) {
            self.offset += literal.len();
            Ok(value)
        } else {
            Err(WireError::bad_payload("malformed JSON literal"))
        }
    }

    fn parse_array(&mut self, depth: usize) -> Result<JsonValue, WireError> {
        self.expect(b'[', "'['")?;
        let mut items = Vec::new();
        self.skip_whitespace();
        if self.peek() == Some(b']') {
            self.offset += 1;
            return Ok(JsonValue::Array(items));
        }
        loop {
            items.push(self.parse_value(depth + 1)?);
            self.skip_whitespace();
            match self.bump() {
                Some(b',') => self.skip_whitespace(),
                Some(b']') => break,
                _ => return Err(WireError::bad_payload("malformed JSON array")),
            }
        }
        Ok(JsonValue::Array(items))
    }

    fn parse_object(&mut self, depth: usize) -> Result<JsonValue, WireError> {
        self.expect(b'{', "'{'")?;
        let mut pairs: Vec<(String, JsonValue)> = Vec::new();
        self.skip_whitespace();
        if self.peek() == Some(b'}') {
            self.offset += 1;
            return Ok(JsonValue::Object(JsonObject::new()));
        }
        loop {
            self.skip_whitespace();
            if self.peek() != Some(b'"') {
                return Err(WireError::bad_payload(
                    "a JSON member name must be a string",
                ));
            }
            let key = self.parse_string()?;
            self.skip_whitespace();
            self.expect(b':', "':' after a member name")?;
            let value = self.parse_value(depth + 1)?;
            pairs.push((key, value));
            self.skip_whitespace();
            match self.bump() {
                Some(b',') => self.skip_whitespace(),
                Some(b'}') => break,
                _ => return Err(WireError::bad_payload("malformed JSON object")),
            }
        }
        Ok(JsonValue::Object(JsonObject::from_pairs(pairs)?))
    }

    fn parse_string(&mut self) -> Result<String, WireError> {
        self.expect(b'"', "'\"'")?;
        let mut out = String::new();
        let mut segment_start = self.offset;
        loop {
            let byte = self
                .bump()
                .ok_or_else(|| WireError::bad_payload("unterminated JSON string"))?;
            match byte {
                b'"' => {
                    out.push_str(&self.text[segment_start..self.offset - 1]);
                    return Ok(out);
                }
                b'\\' => {
                    out.push_str(&self.text[segment_start..self.offset - 1]);
                    self.parse_escape(&mut out)?;
                    segment_start = self.offset;
                }
                0x00..=0x1F => {
                    return Err(WireError::bad_payload(
                        "a JSON string cannot contain a raw control character",
                    ));
                }
                _ => {}
            }
        }
    }

    fn parse_escape(&mut self, out: &mut String) -> Result<(), WireError> {
        let escape = self
            .bump()
            .ok_or_else(|| WireError::bad_payload("unterminated JSON escape"))?;
        match escape {
            b'"' => out.push('"'),
            b'\\' => out.push('\\'),
            b'/' => out.push('/'),
            b'b' => out.push('\u{08}'),
            b'f' => out.push('\u{0C}'),
            b'n' => out.push('\n'),
            b'r' => out.push('\r'),
            b't' => out.push('\t'),
            b'u' => {
                let scalar = self.parse_unicode_escape()?;
                let character = char::from_u32(scalar).ok_or_else(|| {
                    WireError::bad_payload("invalid Unicode escape in JSON string")
                })?;
                out.push(character);
            }
            _ => return Err(WireError::bad_payload("unknown JSON escape sequence")),
        }
        Ok(())
    }

    fn parse_unicode_escape(&mut self) -> Result<u32, WireError> {
        let first = self.parse_hex4()?;
        if (0xD800..=0xDBFF).contains(&first) {
            self.expect(b'\\', "a low surrogate escape")?;
            self.expect(b'u', "a low surrogate escape")?;
            let second = self.parse_hex4()?;
            if !(0xDC00..=0xDFFF).contains(&second) {
                return Err(WireError::bad_payload(
                    "a JSON string has an unpaired high surrogate",
                ));
            }
            return Ok(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00));
        }
        if (0xDC00..=0xDFFF).contains(&first) {
            return Err(WireError::bad_payload(
                "a JSON string has an unpaired low surrogate",
            ));
        }
        Ok(first)
    }

    fn parse_hex4(&mut self) -> Result<u32, WireError> {
        let mut value = 0u32;
        for _ in 0..4 {
            let digit = match self.bump() {
                Some(byte @ b'0'..=b'9') => byte - b'0',
                Some(byte @ b'a'..=b'f') => byte - b'a' + 10,
                Some(byte @ b'A'..=b'F') => byte - b'A' + 10,
                _ => return Err(WireError::bad_payload("invalid \\u escape in JSON string")),
            };
            value = value * 16 + u32::from(digit);
        }
        Ok(value)
    }

    fn parse_number(&mut self) -> Result<JsonValue, WireError> {
        let start = self.offset;
        if self.peek() == Some(b'-') {
            self.offset += 1;
        }
        match self.peek() {
            Some(b'0') => self.offset += 1,
            Some(b'1'..=b'9') => {
                while matches!(self.peek(), Some(b'0'..=b'9')) {
                    self.offset += 1;
                }
            }
            _ => return Err(WireError::bad_payload("malformed JSON number")),
        }
        if matches!(self.peek(), Some(b'.' | b'e' | b'E')) {
            return Err(WireError::bad_payload(
                "canonical JSON accepts integers only (no fraction or exponent)",
            ));
        }
        let text = &self.text[start..self.offset];
        let value: i128 = text
            .parse()
            .map_err(|_| WireError::bad_payload("JSON integer is out of the i128 range"))?;
        Ok(JsonValue::Integer(value))
    }
}

#[cfg(test)]
mod tests {
    use super::{JsonObject, JsonValue};

    #[test]
    fn canonical_form_matches_the_spec_example() {
        let value = JsonValue::parse(r#"{"b":["x","/y"],"a":1}"#).expect("parse");
        assert_eq!(value.to_canonical_json(), r#"{"a":1,"b":["x","/y"]}"#);
    }

    #[test]
    fn duplicate_member_is_rejected() {
        assert!(JsonValue::parse(r#"{"a":1,"a":2}"#).is_err());
    }

    #[test]
    fn non_integer_number_is_rejected() {
        assert!(JsonValue::parse(r#"{"a":1.5}"#).is_err());
        assert!(JsonValue::parse(r#"{"a":1e3}"#).is_err());
    }

    #[test]
    fn object_members_are_sorted_by_code_point() {
        let mut object = JsonObject::new();
        object.insert("z", JsonValue::Integer(1));
        object.insert("\u{e9}", JsonValue::Integer(2));
        object.insert("a", JsonValue::Integer(3));
        assert_eq!(object.to_canonical_json(), "{\"a\":3,\"z\":1,\"\u{e9}\":2}");
    }
}
