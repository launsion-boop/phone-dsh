// SPDX-License-Identifier: MIT
//! WAL format errors.
//!
//! Every failure is a value: no `panic!` is used for a malformed input, a torn
//! tail or a recovery plan that must fail loud. [`WalError::Corrupt`] is the
//! `WAL_CORRUPT` of `spec/v1/wal.md` §10, the only variant that must close
//! admission and move the host to `Failed`.

use core::fmt;

/// Result alias of this crate.
pub type WalResult<T> = core::result::Result<T, WalError>;

/// A WAL format, recovery-planning or corruption error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WalError {
    /// Fewer bytes than the structure needs.
    Truncated {
        /// Bytes required.
        need: usize,
        /// Bytes available.
        have: usize,
    },
    /// The segment header magic is not `XLWAL1\0\0`.
    BadMagic,
    /// The segment header `format` is not 1.
    UnsupportedFormat(u16),
    /// The segment header `reserved` field is not zero.
    NonZeroReserved(u16),
    /// The segment header `first_mseq` is zero.
    InvalidFirstMseq(u64),
    /// The segment header CRC32C does not cover bytes 0–35.
    HeaderCrcMismatch {
        /// CRC stored in the header.
        stored: u32,
        /// CRC computed over bytes 0–35.
        computed: u32,
    },
    /// A record `len` is smaller than the 8-byte `mseq`.
    BadLength(u32),
    /// A record CRC32C does not cover `mseq ‖ body`.
    RecordCrcMismatch {
        /// CRC stored in the record.
        stored: u32,
        /// CRC computed over `mseq ‖ body`.
        computed: u32,
    },
    /// A record is complete and CRC-verified but violates `wal.md` §3.
    MalformedRecord(String),
    /// A record follows the epoch-close record of its segment.
    RecordAfterEpochClose,
    /// A segment holds more than one epoch-close record.
    DuplicateEpochClose,
    /// A mutation `mseq` is not the expected consecutive value.
    MseqNotConsecutive {
        /// The consecutive value the chain required.
        expected: u64,
        /// The value in the record.
        found: u64,
    },
    /// A mutation record carries `mseq = 0`; mutations start at 1.
    ZeroMseq,
    /// A segment name is not `wal/<epoch:08d>.<segment:06d>.xlwal`.
    BadSegmentName(String),
    /// `manifest.json` is not the JSON of `wal.md` §7.
    ManifestInvalid(String),
    /// `mseq` reached `u64::MAX`; D17 forbids reusing a number.
    MseqExhausted,
    /// The next epoch number does not fit the 8-digit segment-name form.
    EpochExhausted,
    /// `WAL_CORRUPT` (`wal.md` §10): recovery must fail and admission close.
    Corrupt(String),
}

impl WalError {
    /// The stable diagnostic code of this error, as a `&'static str`.
    ///
    /// This is the **single** `WalError` → code mapping: the FFI layers
    /// (`pdsh-jni`, and through it the Kotlin `NativeWal`) call this method
    /// instead of carrying their own copy, so the table cannot drift from the
    /// type. The strings are a JNI/FFI diagnostic vocabulary, not a second
    /// state machine: `WAL_CORRUPT` is the only `wal.md` §10 state code, while
    /// the other strings name which pure-kernel rule failed. Two groups share
    /// a code because the recovery consequence is the same:
    ///
    /// | Code | Variants |
    /// | --- | --- |
    /// | `WAL_CORRUPT` | [`WalError::Corrupt`], [`WalError::BadLength`], [`WalError::RecordCrcMismatch`], [`WalError::MalformedRecord`], [`WalError::RecordAfterEpochClose`], [`WalError::DuplicateEpochClose`], [`WalError::MseqNotConsecutive`], [`WalError::ZeroMseq`] |
    /// | `WAL_MANIFEST_INVALID` | [`WalError::ManifestInvalid`] — `wal.md` §7.2 treats it as a missing manifest, not as `Failed` |
    /// | `WAL_TRUNCATED` | [`WalError::Truncated`] |
    /// | `WAL_HEADER_INVALID` | [`WalError::BadMagic`], [`WalError::UnsupportedFormat`], [`WalError::NonZeroReserved`], [`WalError::InvalidFirstMseq`], [`WalError::HeaderCrcMismatch`] |
    /// | `WAL_BAD_SEGMENT_NAME` | [`WalError::BadSegmentName`] |
    /// | `WAL_MSEQ_EXHAUSTED` | [`WalError::MseqExhausted`] |
    /// | `WAL_EPOCH_EXHAUSTED` | [`WalError::EpochExhausted`] |
    ///
    /// The mapping is stable: these strings are part of the Android JNI ABI
    /// (`pdsh-jni` exception messages are `"<CODE>: <detail>"`), so a new
    /// variant must pick an existing code or add a code in the same commit as
    /// its Kotlin binding.
    pub fn code(&self) -> &'static str {
        match self {
            WalError::Corrupt(_) => "WAL_CORRUPT",
            WalError::ManifestInvalid(_) => "WAL_MANIFEST_INVALID",
            WalError::Truncated { .. } => "WAL_TRUNCATED",
            WalError::BadMagic
            | WalError::UnsupportedFormat(_)
            | WalError::NonZeroReserved(_)
            | WalError::InvalidFirstMseq(_)
            | WalError::HeaderCrcMismatch { .. } => "WAL_HEADER_INVALID",
            WalError::BadLength(_)
            | WalError::RecordCrcMismatch { .. }
            | WalError::MalformedRecord(_)
            | WalError::RecordAfterEpochClose
            | WalError::DuplicateEpochClose
            | WalError::MseqNotConsecutive { .. }
            | WalError::ZeroMseq => "WAL_CORRUPT",
            WalError::BadSegmentName(_) => "WAL_BAD_SEGMENT_NAME",
            WalError::MseqExhausted => "WAL_MSEQ_EXHAUSTED",
            WalError::EpochExhausted => "WAL_EPOCH_EXHAUSTED",
        }
    }

    /// `true` for the `WAL_CORRUPT` class: a listed segment missing above the
    /// materialized watermark, a non-tail CRC failure, an mseq hole, or an
    /// impossible manifest.
    pub fn is_corrupt(&self) -> bool {
        matches!(self, WalError::Corrupt(_))
    }

    /// Shorthand for the `WAL_CORRUPT` variant.
    pub fn corrupt(reason: impl Into<String>) -> WalError {
        WalError::Corrupt(reason.into())
    }

    /// Shorthand for [`WalError::MalformedRecord`].
    pub fn malformed(reason: impl Into<String>) -> WalError {
        WalError::MalformedRecord(reason.into())
    }
}

impl fmt::Display for WalError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            WalError::Truncated { need, have } => {
                write!(f, "truncated WAL data: need {need} bytes, have {have}")
            }
            WalError::BadMagic => write!(f, "WAL segment magic is not XLWAL1"),
            WalError::UnsupportedFormat(format) => {
                write!(f, "unsupported WAL segment format {format}")
            }
            WalError::NonZeroReserved(value) => {
                write!(f, "WAL segment reserved field is {value}, expected 0")
            }
            WalError::InvalidFirstMseq(value) => {
                write!(f, "WAL segment first_mseq {value} is invalid, expected at least 1")
            }
            WalError::HeaderCrcMismatch { stored, computed } => write!(
                f,
                "WAL segment header CRC32C mismatch: stored {stored:#010x}, computed {computed:#010x}"
            ),
            WalError::BadLength(length) => {
                write!(f, "WAL record len {length} is smaller than the 8-byte mseq")
            }
            WalError::RecordCrcMismatch { stored, computed } => write!(
                f,
                "WAL record CRC32C mismatch: stored {stored:#010x}, computed {computed:#010x}"
            ),
            WalError::MalformedRecord(reason) => write!(f, "malformed WAL record: {reason}"),
            WalError::RecordAfterEpochClose => {
                write!(f, "a record follows the epoch-close record of its segment")
            }
            WalError::DuplicateEpochClose => {
                write!(f, "a segment holds more than one epoch-close record")
            }
            WalError::MseqNotConsecutive { expected, found } => {
                write!(f, "WAL mseq {found} does not continue {expected}")
            }
            WalError::ZeroMseq => write!(f, "a mutation record carries mseq 0"),
            WalError::BadSegmentName(name) => write!(f, "bad WAL segment name {name:?}"),
            WalError::ManifestInvalid(reason) => write!(f, "invalid manifest.json: {reason}"),
            WalError::MseqExhausted => write!(f, "WAL mseq reached the u64 maximum"),
            WalError::EpochExhausted => {
                write!(f, "the next WAL epoch does not fit the 8-digit segment name")
            }
            WalError::Corrupt(reason) => write!(f, "WAL_CORRUPT: {reason}"),
        }
    }
}

impl std::error::Error for WalError {}

#[cfg(test)]
mod tests {
    use super::WalError;

    /// Every variant with a distinct payload, so a forgotten match arm cannot
    /// hide behind a wildcard.
    fn all_variants() -> Vec<WalError> {
        vec![
            WalError::Truncated { need: 40, have: 39 },
            WalError::BadMagic,
            WalError::UnsupportedFormat(2),
            WalError::NonZeroReserved(1),
            WalError::InvalidFirstMseq(0),
            WalError::HeaderCrcMismatch {
                stored: 0x0b0f_9536,
                computed: 0xdead_beef,
            },
            WalError::BadLength(3),
            WalError::RecordCrcMismatch {
                stored: 1,
                computed: 2,
            },
            WalError::MalformedRecord("unknown VFS op 9".to_string()),
            WalError::RecordAfterEpochClose,
            WalError::DuplicateEpochClose,
            WalError::MseqNotConsecutive {
                expected: 43,
                found: 44,
            },
            WalError::ZeroMseq,
            WalError::BadSegmentName("nope".to_string()),
            WalError::ManifestInvalid("not JSON".to_string()),
            WalError::MseqExhausted,
            WalError::EpochExhausted,
            WalError::Corrupt("mseq hole".to_string()),
        ]
    }

    /// The FFI code of every variant, pinned. `pdsh-jni` throws these strings
    /// and the Kotlin `NativeWal` binding branches on them, so a change here is
    /// an ABI change and must be deliberate.
    #[test]
    fn every_variant_has_a_stable_code() {
        let expected = [
            ("WAL_TRUNCATED", WalError::Truncated { need: 40, have: 39 }),
            ("WAL_HEADER_INVALID", WalError::BadMagic),
            ("WAL_HEADER_INVALID", WalError::UnsupportedFormat(2)),
            ("WAL_HEADER_INVALID", WalError::NonZeroReserved(1)),
            ("WAL_HEADER_INVALID", WalError::InvalidFirstMseq(0)),
            (
                "WAL_HEADER_INVALID",
                WalError::HeaderCrcMismatch {
                    stored: 0x0b0f_9536,
                    computed: 0xdead_beef,
                },
            ),
            ("WAL_CORRUPT", WalError::BadLength(3)),
            (
                "WAL_CORRUPT",
                WalError::RecordCrcMismatch {
                    stored: 1,
                    computed: 2,
                },
            ),
            (
                "WAL_CORRUPT",
                WalError::MalformedRecord("unknown VFS op 9".to_string()),
            ),
            ("WAL_CORRUPT", WalError::RecordAfterEpochClose),
            ("WAL_CORRUPT", WalError::DuplicateEpochClose),
            (
                "WAL_CORRUPT",
                WalError::MseqNotConsecutive {
                    expected: 43,
                    found: 44,
                },
            ),
            ("WAL_CORRUPT", WalError::ZeroMseq),
            ("WAL_BAD_SEGMENT_NAME", WalError::BadSegmentName("nope".to_string())),
            ("WAL_MANIFEST_INVALID", WalError::ManifestInvalid("not JSON".to_string())),
            ("WAL_MSEQ_EXHAUSTED", WalError::MseqExhausted),
            ("WAL_EPOCH_EXHAUSTED", WalError::EpochExhausted),
            ("WAL_CORRUPT", WalError::Corrupt("mseq hole".to_string())),
        ];

        // The table above must see every variant: a new `WalError` without a
        // row fails here instead of silently inheriting a wildcard code.
        assert_eq!(expected.len(), all_variants().len());
        for (index, (code, error)) in expected.iter().enumerate() {
            assert_eq!(&error.code(), code, "variant {index} ({error:?})");
            assert_eq!(error.code(), all_variants()[index].code(), "variant {index}");
        }
    }

    /// The vocabulary is exactly the seven FFI codes, all `WAL_`-prefixed and
    /// uppercase. `WAL_INPUT_INVALID` is a bridge argument code, not a
    /// `WalError` code, so it must not appear here.
    #[test]
    fn the_code_vocabulary_is_the_seven_ffi_codes() {
        let mut codes: Vec<&'static str> = all_variants().iter().map(WalError::code).collect();
        codes.sort_unstable();
        codes.dedup();
        assert_eq!(
            codes,
            vec![
                "WAL_BAD_SEGMENT_NAME",
                "WAL_CORRUPT",
                "WAL_EPOCH_EXHAUSTED",
                "WAL_HEADER_INVALID",
                "WAL_MANIFEST_INVALID",
                "WAL_MSEQ_EXHAUSTED",
                "WAL_TRUNCATED",
            ]
        );
        for code in codes {
            assert!(code.starts_with("WAL_"), "{code}");
            assert!(
                code.bytes().all(|byte| byte.is_ascii_uppercase() || byte == b'_'),
                "{code} is not a stable uppercase code"
            );
        }
    }

    /// The code is a property of the variant, not of its payload: the same
    /// variant with a different reason keeps its code.
    #[test]
    fn the_code_ignores_the_error_payload() {
        assert_eq!(
            WalError::Corrupt("first".to_string()).code(),
            WalError::Corrupt("second".to_string()).code()
        );
        assert_eq!(
            WalError::MalformedRecord("a".to_string()).code(),
            WalError::MalformedRecord("b".to_string()).code()
        );
        assert_eq!(
            WalError::Truncated { need: 8, have: 0 }.code(),
            WalError::Truncated { need: 40, have: 39 }.code()
        );
    }
}
