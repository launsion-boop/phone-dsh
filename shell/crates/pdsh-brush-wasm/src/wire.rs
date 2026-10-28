// SPDX-License-Identifier: MIT
//! Binary framing between the wasm shell and the Worker host.
//!
//! The guest cannot call JSON helpers without pulling another dependency into
//! the wasm module, and the payload is small and flat, so both sides use a
//! length-prefixed little-endian encoding. Lengths are `u32`; every buffer is
//! bounded by [`MAX_WIRE_BYTES`] on decode so a broken host cannot make the
//! guest allocate without limit.
//!
//! Request:  `name, argv[], stdin, cwd, env[]`
//! Response: `exit_code i32, stdout, stderr, flags u32`

use std::fmt;

use crate::dispatch::{CommandRequest, CommandResult};

/// Upper bound for one encoded request or response.
pub const MAX_WIRE_BYTES: usize = 16 * 1024 * 1024;

/// Flag set in a response when the host observed a cancellation.
pub const RESPONSE_FLAG_CANCELLED: u32 = 1;

/// A malformed payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WireError(pub String);

impl fmt::Display for WireError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for WireError {}

fn put_bytes(out: &mut Vec<u8>, bytes: &[u8]) -> Result<(), WireError> {
    let length = u32::try_from(bytes.len())
        .map_err(|_| WireError("payload field is larger than 4 GiB".to_string()))?;
    out.extend_from_slice(&length.to_le_bytes());
    out.extend_from_slice(bytes);
    Ok(())
}

fn put_string(out: &mut Vec<u8>, value: &str) -> Result<(), WireError> {
    put_bytes(out, value.as_bytes())
}

/// Encodes one dispatch request.
pub fn encode_request(request: &CommandRequest<'_>) -> Result<Vec<u8>, WireError> {
    let mut out = Vec::new();
    put_string(&mut out, request.command)?;
    let argc = u32::try_from(request.args.len())
        .map_err(|_| WireError("too many arguments".to_string()))?;
    out.extend_from_slice(&argc.to_le_bytes());
    for argument in request.args {
        put_string(&mut out, argument)?;
    }
    put_bytes(&mut out, request.stdin)?;
    put_string(&mut out, &request.cwd)?;
    let env_count = u32::try_from(request.env.len())
        .map_err(|_| WireError("too many environment variables".to_string()))?;
    out.extend_from_slice(&env_count.to_le_bytes());
    for (name, value) in &request.env {
        put_string(&mut out, name)?;
        put_string(&mut out, value)?;
    }
    Ok(out)
}

/// Encodes one dispatch response.
#[must_use]
pub fn encode_result(result: &CommandResult, cancelled: bool) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&result.exit_code.to_le_bytes());
    // The length prefixes cannot fail for a response this size; a failure
    // would mean a multi-gigabyte buffer, which the callers never build.
    let _ = put_bytes(&mut out, &result.stdout);
    let _ = put_bytes(&mut out, &result.stderr);
    let flags = if cancelled { RESPONSE_FLAG_CANCELLED } else { 0 };
    out.extend_from_slice(&flags.to_le_bytes());
    out
}

/// A decoded request with owned storage.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OwnedRequest {
    /// Command name.
    pub command: String,
    /// Arguments after the command name.
    pub args: Vec<String>,
    /// Standard input bytes.
    pub stdin: Vec<u8>,
    /// Guest working directory.
    pub cwd: String,
    /// Exported environment.
    pub env: Vec<(String, String)>,
}

/// Parses a request written by [`encode_request`].
pub fn decode_request(bytes: &[u8]) -> Result<OwnedRequest, WireError> {
    let mut reader = Reader::new(bytes);
    let command = reader.string()?;
    let argc = reader.u32()?;
    let mut args = Vec::with_capacity(usize::try_from(argc).unwrap_or(0).min(1024));
    for _ in 0..argc {
        args.push(reader.string()?);
    }
    let stdin = reader.bytes()?;
    let cwd = reader.string()?;
    let env_count = reader.u32()?;
    let mut env = Vec::with_capacity(usize::try_from(env_count).unwrap_or(0).min(1024));
    for _ in 0..env_count {
        let name = reader.string()?;
        let value = reader.string()?;
        env.push((name, value));
    }
    reader.finish()?;
    Ok(OwnedRequest {
        command,
        args,
        stdin,
        cwd,
        env,
    })
}

/// A decoded response.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OwnedResult {
    /// Process exit status.
    pub exit_code: i32,
    /// Standard output.
    pub stdout: Vec<u8>,
    /// Standard error.
    pub stderr: Vec<u8>,
    /// Whether the host cancelled the command.
    pub cancelled: bool,
}

/// Parses a response written by [`encode_result`].
pub fn decode_result(bytes: &[u8]) -> Result<OwnedResult, WireError> {
    let mut reader = Reader::new(bytes);
    let exit_code = reader.i32()?;
    let stdout = reader.bytes()?;
    let stderr = reader.bytes()?;
    let flags = reader.u32()?;
    reader.finish()?;
    Ok(OwnedResult {
        exit_code,
        stdout,
        stderr,
        cancelled: flags & RESPONSE_FLAG_CANCELLED != 0,
    })
}

struct Reader<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Reader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    fn take(&mut self, length: usize) -> Result<&'a [u8], WireError> {
        if length > MAX_WIRE_BYTES {
            return Err(WireError(format!("field of {length} bytes is too large")));
        }
        let end = self
            .offset
            .checked_add(length)
            .ok_or_else(|| WireError("payload length overflow".to_string()))?;
        if end > self.bytes.len() {
            return Err(WireError("truncated payload".to_string()));
        }
        let slice = &self.bytes[self.offset..end];
        self.offset = end;
        Ok(slice)
    }

    fn u32(&mut self) -> Result<u32, WireError> {
        let bytes = self.take(4)?;
        Ok(u32::from_le_bytes(
            bytes.try_into().map_err(|_| WireError("bad u32".to_string()))?,
        ))
    }

    fn i32(&mut self) -> Result<i32, WireError> {
        Ok(i32::from_le_bytes(
            self.take(4)?
                .try_into()
                .map_err(|_| WireError("bad i32".to_string()))?,
        ))
    }

    fn bytes(&mut self) -> Result<Vec<u8>, WireError> {
        let length = usize::try_from(self.u32()?)
            .map_err(|_| WireError("bad length".to_string()))?;
        Ok(self.take(length)?.to_vec())
    }

    fn string(&mut self) -> Result<String, WireError> {
        String::from_utf8(self.bytes()?).map_err(|_| WireError("invalid UTF-8".to_string()))
    }

    fn finish(&self) -> Result<(), WireError> {
        if self.offset == self.bytes.len() {
            Ok(())
        } else {
            Err(WireError(format!(
                "{} trailing bytes",
                self.bytes.len() - self.offset
            )))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request() -> OwnedRequest {
        OwnedRequest {
            command: "cat".to_string(),
            args: vec!["-n".to_string(), "a b.txt".to_string()],
            stdin: b"line\n".to_vec(),
            cwd: "/dsh/workspace".to_string(),
            env: vec![("HOME".to_string(), "/dsh/home".to_string())],
        }
    }

    #[test]
    fn request_round_trips() {
        let owned = request();
        let encoded = encode_request(&CommandRequest {
            command: &owned.command,
            args: &owned.args,
            stdin: &owned.stdin,
            cwd: owned.cwd.clone(),
            env: owned.env.clone(),
        })
        .expect("encode");
        assert_eq!(decode_request(&encoded).expect("decode"), owned);
    }

    #[test]
    fn response_round_trips() {
        let result = CommandResult {
            exit_code: 3,
            stdout: b"out".to_vec(),
            stderr: b"err".to_vec(),
        };
        let encoded = encode_result(&result, true);
        let decoded = decode_result(&encoded).expect("decode");
        assert_eq!(decoded.exit_code, 3);
        assert_eq!(decoded.stdout, b"out");
        assert_eq!(decoded.stderr, b"err");
        assert!(decoded.cancelled);
    }

    #[test]
    fn truncated_payload_is_rejected() {
        let owned = request();
        let encoded = encode_request(&CommandRequest {
            command: &owned.command,
            args: &owned.args,
            stdin: &owned.stdin,
            cwd: owned.cwd.clone(),
            env: owned.env.clone(),
        })
        .expect("encode");
        assert!(decode_request(&encoded[..encoded.len() - 1]).is_err());
    }

    #[test]
    fn trailing_bytes_are_rejected() {
        let encoded = encode_result(&CommandResult::default(), false);
        let mut extended = encoded;
        extended.push(0);
        assert!(decode_result(&extended).is_err());
    }
}
