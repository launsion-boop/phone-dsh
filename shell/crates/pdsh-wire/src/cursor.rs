// SPDX-License-Identifier: MIT
//! Internal big-endian reader and writer used by every binary payload codec.
//!
//! All multi-byte integers on the wire are big-endian (`channel.md` §1), and
//! every out-of-bounds read is a `BAD_PAYLOAD`, never a panic.

use crate::error::WireError;

/// Bounds-checked big-endian reader over one payload slice.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Reader<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Reader<'a> {
    pub(crate) fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    pub(crate) fn remaining(&self) -> usize {
        self.bytes.len() - self.offset
    }

    pub(crate) fn read_u8(&mut self) -> Result<u8, WireError> {
        self.require(1)?;
        let value = self.bytes[self.offset];
        self.offset += 1;
        Ok(value)
    }

    pub(crate) fn read_u16(&mut self) -> Result<u16, WireError> {
        let bytes = self.read_array::<2>()?;
        Ok(u16::from_be_bytes(bytes))
    }

    pub(crate) fn read_u32(&mut self) -> Result<u32, WireError> {
        let bytes = self.read_array::<4>()?;
        Ok(u32::from_be_bytes(bytes))
    }

    pub(crate) fn read_u64(&mut self) -> Result<u64, WireError> {
        let bytes = self.read_array::<8>()?;
        Ok(u64::from_be_bytes(bytes))
    }

    pub(crate) fn read_bytes(&mut self, len: usize) -> Result<&'a [u8], WireError> {
        self.require(len)?;
        let start = self.offset;
        self.offset += len;
        Ok(&self.bytes[start..self.offset])
    }

    /// Consumes and returns every remaining byte.
    pub(crate) fn rest(&mut self) -> &'a [u8] {
        let start = self.offset;
        self.offset = self.bytes.len();
        &self.bytes[start..]
    }

    /// Fails when the payload has bytes after the last field.
    pub(crate) fn finish(self) -> Result<(), WireError> {
        if self.offset == self.bytes.len() {
            Ok(())
        } else {
            Err(WireError::bad_payload(format!(
                "payload has {} trailing bytes",
                self.bytes.len() - self.offset
            )))
        }
    }

    fn read_array<const N: usize>(&mut self) -> Result<[u8; N], WireError> {
        let bytes = self.read_bytes(N)?;
        let mut array = [0u8; N];
        array.copy_from_slice(bytes);
        Ok(array)
    }

    fn require(&self, len: usize) -> Result<(), WireError> {
        if self.remaining() < len {
            return Err(WireError::bad_payload(format!(
                "payload is truncated: need {len} bytes, have {}",
                self.remaining()
            )));
        }
        Ok(())
    }
}

/// Big-endian writer for one payload.
#[derive(Clone, Debug)]
pub(crate) struct Writer {
    bytes: Vec<u8>,
}

impl Writer {
    pub(crate) fn with_capacity(capacity: usize) -> Self {
        Self {
            bytes: Vec::with_capacity(capacity),
        }
    }

    pub(crate) fn write_u8(&mut self, value: u8) {
        self.bytes.push(value);
    }

    pub(crate) fn write_u16(&mut self, value: u16) {
        self.bytes.extend_from_slice(&value.to_be_bytes());
    }

    pub(crate) fn write_u32(&mut self, value: u32) {
        self.bytes.extend_from_slice(&value.to_be_bytes());
    }

    pub(crate) fn write_u64(&mut self, value: u64) {
        self.bytes.extend_from_slice(&value.to_be_bytes());
    }

    pub(crate) fn write_bytes(&mut self, bytes: &[u8]) {
        self.bytes.extend_from_slice(bytes);
    }

    pub(crate) fn into_vec(self) -> Vec<u8> {
        self.bytes
    }
}

#[cfg(test)]
mod tests {
    use super::Reader;

    #[test]
    fn truncated_reads_are_errors_not_panics() {
        let mut reader = Reader::new(&[0x00, 0x01, 0x02]);
        assert!(reader.read_u16().is_ok());
        assert!(reader.read_u32().is_err());
    }

    #[test]
    fn finish_rejects_trailing_bytes() {
        let mut reader = Reader::new(&[0x00, 0x01]);
        assert_eq!(reader.read_u8(), Ok(0x00));
        assert!(reader.finish().is_err());
    }
}
