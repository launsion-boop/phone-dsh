// SPDX-License-Identifier: MIT
//! **Experimental** I/O-free WAL kernel bridge (`pdsh-wal` → JSON).
//!
//! The WAL ABI is **not frozen** before the R1 conclusion (Android adaptation
//! plan §8.2-2). These functions project the pure half of `spec/v1/wal.md`
//! — the §2 header, §3 records, §4 epoch close, §10/D19 tail classification,
//! §7 manifest and §7.2/D11 recovery plan — onto the JSON dialect the Kotlin
//! `:core` log package consumes. They may change with WAL semantics.
//!
//! Nothing here performs I/O. Every input is a byte slice or a JSON string and
//! every output is JSON or bytes; the caller reads and writes files. In
//! particular this module does **not** fsync, truncate, rename, unlink, write a
//! manifest or close an epoch. Those are the per-OS half of `wal.md` §5.2,
//! §7.1 and §9 (see [`pdsh_wal`](../../pdsh_wal/index.html)).
//!
//! # CRC32C
//!
//! The WAL fixes CRC32C (Castagnoli) in `README.md` and `wal.md` §2–§3, so the
//! production [`Checksum`] injection is the wire codec's
//! [`pdsh_wire::crc32c`]. There is **no checksum seed** in the format; an entry
//! point that accepted one would let a caller verify against a checksum the
//! format does not define.
//!
//! # JSON shapes
//!
//! The shapes are a tagged projection of the Rust types. Member order is
//! stable but not semantically meaningful, and a decoder must ignore unknown
//! members (`spec/v1/README.md` §2). `null` is the absent `Option` value.
//!
//! * [`classify_tail`] — `{"verdict":"clean"}`, or
//!   `{"verdict":"truncate","keep":N,"dropped":N}`, or
//!   `{"verdict":"corrupt","at":N}`. The input is a **whole segment file**
//!   (header included) and the offsets are file offsets: `keep` is the file
//!   length to truncate to (`pdsh_wal::Truncation::keep_len`), `at` is the file
//!   offset of the failing record. Subtract [`HEADER_BYTES`] for the
//!   record-region offsets of [`pdsh_wal::TailVerdict`].
//! * [`scan_segment`] — the [`pdsh_wal::SegmentFacts`] fields plus
//!   `chain_error`, `header_error` and `valid_len` (see the function docs).
//! * [`plan_recovery`] — the complete [`pdsh_wal::RecoveryPlan`].
//! * [`parse_manifest`] / [`emit_manifest`] — canonical `manifest.json`
//!   (`wal.md` §7.1), unknown members ignored per `README.md` §2.
//! * [`verify_record`] — `{"ok":true}`, or an object with `code`, `detail` and
//!   `tail_eligible` (whether D19 may truncate it at the tail).
//! * [`records`] — a JSON array of the segment's complete, CRC-verified
//!   records, each in the shape of [`decode_record`]; the D19 torn tail is
//!   omitted (call [`classify_tail`] for the verdict), while a non-tail failure
//!   or a §3–§4 chain violation throws.
//! * [`decode_record`] — one exactly-one-record input in that same shape:
//!   `{"mseq":N,"len":N,"crc_ok":true,"kind":"mutation",…}` or
//!   `{…,"kind":"epoch_close","op":255,"wall_ms":N,"durable_upto":N}`. Body
//!   members are the `channel.md` §3.1 / `wal.md` §3 names: `op`, `mode`,
//!   `mflags`, `append_from`, `path`, `data_len` and `data_hex` (the lowercase
//!   hex form `golden/README.md` §3 fixes for the raw `data` bytes).
//! * [`appended_replay`] — `{"verdict":"applied"}`, `{"verdict":"skip"}` or
//!   `{"verdict":"resync"}` (D9, §6.2); the caller supplies the materialized
//!   file's bytes at `append_from` (`null` when the path is absent, a directory
//!   or not a regular file).
//!
//! # Error codes
//!
//! `WAL_CORRUPT` is the only §10 state code; it closes admission and moves the
//! host to `Failed`. The other codes below are **JNI diagnostics** that name
//! which pure-kernel rule failed; `WAL_MANIFEST_INVALID` is special because
//! `wal.md` §7.2 sends a schema-invalid manifest to the missing-manifest rule
//! rather than to `Failed`. The bridge hands out `"<CODE>: <detail>"` strings;
//! [`BridgeError`] keeps the two apart for a caller that wants to branch.
//!
//! | Code | Meaning |
//! | --- | --- |
//! | [`CODE_WAL_CORRUPT`] | `WAL_CORRUPT` of `wal.md` §10 |
//! | [`CODE_WAL_MANIFEST_INVALID`] | `manifest.json` is not the §7 schema — treat it as missing |
//! | [`CODE_WAL_TRUNCATED`] | fewer bytes than the header or a record needs |
//! | [`CODE_WAL_HEADER_INVALID`] | magic, format, reserved, `first_mseq` or header CRC is wrong |
//! | [`CODE_WAL_BAD_SEGMENT_NAME`] | not `wal/<epoch:08d>.<segment:06d>.xlwal` |
//! | [`CODE_WAL_MSEQ_EXHAUSTED`] | mseq reached `u64::MAX` (D17 forbids reuse) |
//! | [`CODE_WAL_EPOCH_EXHAUSTED`] | the next epoch does not fit 8 digits |
//! | [`CODE_WAL_INPUT_INVALID`] | the JSON argument does not have the documented shape |

use core::fmt;

use pdsh_wal::epoch::EPOCH_CLOSE_BODY_BYTES;
use pdsh_wal::json::{self, Json};
use pdsh_wal::{
    appended_replay as replay_decision, classify_tail as classify_region_tail,
    retained_supersession as replay_supersession, scan_segment as scan_segment_bytes, Checksum,
    CoverKind, Manifest, Record, RecordParseError, RecoveryInput, RecoveryPlan, ReplayDecision,
    RetainedRecord, SegmentFacts, SegmentName, TailVerdict, Truncation, WalError,
    BODY_HEADER_BYTES, HEADER_BYTES, OP_BLOB_WRITE, OP_EPOCH_CLOSE, RECORD_PREFIX_BYTES,
};

/// `WAL_CORRUPT`, the only `wal.md` §10 state code.
pub const CODE_WAL_CORRUPT: &str = "WAL_CORRUPT";
/// A `manifest.json` that is not the §7 schema; §7.2 treats it as missing.
pub const CODE_WAL_MANIFEST_INVALID: &str = "WAL_MANIFEST_INVALID";
/// Fewer bytes than a header or a record needs.
pub const CODE_WAL_TRUNCATED: &str = "WAL_TRUNCATED";
/// A segment header whose magic, format, reserved, `first_mseq` or CRC is bad.
pub const CODE_WAL_HEADER_INVALID: &str = "WAL_HEADER_INVALID";
/// A segment name that is not `wal/<epoch:08d>.<segment:06d>.xlwal`.
pub const CODE_WAL_BAD_SEGMENT_NAME: &str = "WAL_BAD_SEGMENT_NAME";
/// `mseq` reached `u64::MAX`; D17 forbids reusing a number.
pub const CODE_WAL_MSEQ_EXHAUSTED: &str = "WAL_MSEQ_EXHAUSTED";
/// The next epoch number does not fit the 8-digit segment-name form.
pub const CODE_WAL_EPOCH_EXHAUSTED: &str = "WAL_EPOCH_EXHAUSTED";
/// A bridge argument that is not the documented JSON shape.
pub const CODE_WAL_INPUT_INVALID: &str = "WAL_INPUT_INVALID";

/// The WAL checksum: the wire codec's Castagnoli CRC32C.
///
/// `pdsh-wal` owns no CRC implementation on purpose; production wiring injects
/// the same function the wire codec uses (`wal.md` §2–§3).
struct WireChecksum;

impl Checksum for WireChecksum {
    fn crc32c(&self, bytes: &[u8]) -> u32 {
        pdsh_wire::crc32c(bytes)
    }
}

/// The one checksum instance every entry point injects.
const CHECKSUM: WireChecksum = WireChecksum;

/// The JNI code for a `WalError`.
///
/// The mapping lives in [`pdsh_wal::WalError::code`] — this function is only
/// the JNI-side name for it, so `pdsh-jni` carries no second copy that could
/// drift. `WAL_CORRUPT` is the §10 state class; the other strings are
/// diagnostics (see the module docs). `ManifestInvalid` maps to
/// [`CODE_WAL_MANIFEST_INVALID`] because `wal.md` §7.2 turns it into the
/// missing-manifest rule, not into `Failed`.
pub fn error_code(error: &WalError) -> &'static str {
    error.code()
}

/// The human-readable detail of a `WalError`, without its code prefix.
///
/// `WalError::Corrupt`'s `Display` already starts with `WAL_CORRUPT: `; the
/// prefix is removed here so `code` and `detail` stay orthogonal in the JSON
/// and in the Java exception message.
pub fn error_detail(error: &WalError) -> String {
    match error {
        WalError::Corrupt(reason) => reason.clone(),
        other => other.to_string(),
    }
}

/// `"<CODE>: <detail>"`, the message of the Java `RuntimeException`.
pub fn error_message(error: &WalError) -> String {
    format!("{}: {}", error_code(error), error_detail(error))
}

/// A bridge call that failed before (or instead of) producing JSON.
///
/// `Input` is a malformed argument to the entry point; `Wal` is a `pdsh-wal`
/// failure. The JNI layer turns both into a Java `RuntimeException` whose
/// message is [`BridgeError::message`].
#[derive(Debug)]
pub enum BridgeError {
    /// The JSON argument does not have the documented shape.
    Input(String),
    /// A WAL format, manifest or plan failure.
    Wal(WalError),
}

impl BridgeError {
    /// The JNI code of the failure.
    pub fn code(&self) -> &'static str {
        match self {
            Self::Input(_) => CODE_WAL_INPUT_INVALID,
            Self::Wal(error) => error_code(error),
        }
    }

    /// The human-readable detail, without the code prefix.
    pub fn detail(&self) -> String {
        match self {
            Self::Input(detail) => detail.clone(),
            Self::Wal(error) => error_detail(error),
        }
    }

    /// `"<CODE>: <detail>"`.
    pub fn message(&self) -> String {
        format!("{}: {}", self.code(), self.detail())
    }
}

impl From<WalError> for BridgeError {
    fn from(error: WalError) -> Self {
        Self::Wal(error)
    }
}

impl fmt::Display for BridgeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message())
    }
}

impl std::error::Error for BridgeError {}

/// D19 tail classification for one whole segment file.
///
/// `segment` includes the 40-byte header of `wal.md` §2. The input is rejected
/// when it is shorter than the header ([`CODE_WAL_TRUNCATED`]); a header that
/// does not verify is `scan_segment`'s business (`header_ok`), because D19 only
/// classifies the record region of a readable segment.
///
/// The result is a tagged projection of [`pdsh_wal::TailVerdict`]:
///
/// | Verdict | JSON |
/// | --- | --- |
/// | `Clean` | `{"verdict":"clean"}` |
/// | `Truncate { keep, dropped }` | `{"verdict":"truncate","keep":N,"dropped":N}` |
/// | `Corrupt { at }` | `{"verdict":"corrupt","at":N}` |
///
/// `keep` is the file length to truncate to (`HEADER_BYTES + keep` of the
/// region verdict) and `at` is the failing record's file offset; both are what
/// the §10 step 2 log names.
pub fn classify_tail(segment: &[u8]) -> Result<String, WalError> {
    if segment.len() < HEADER_BYTES {
        return Err(WalError::Truncated {
            need: HEADER_BYTES,
            have: segment.len(),
        });
    }
    let region = &segment[HEADER_BYTES..];
    Ok(match classify_region_tail(region, &CHECKSUM) {
        TailVerdict::Clean => "{\"verdict\":\"clean\"}".to_string(),
        TailVerdict::Truncate { keep, dropped } => format!(
            "{{\"verdict\":\"truncate\",\"keep\":{},\"dropped\":{}}}",
            HEADER_BYTES + keep,
            dropped
        ),
        TailVerdict::Corrupt { at } => {
            format!("{{\"verdict\":\"corrupt\",\"at\":{}}}", HEADER_BYTES + at)
        }
    })
}

/// The facts of one whole segment file, as `pdsh_wal::SegmentFacts` plus the
/// two scan-level diagnostics.
///
/// ```json
/// {"header_ok":true,"corrupt":false,"first_mseq":42,
///  "first_mutation_mseq":42,"last_mutation_mseq":46,"epoch_close":46,
///  "torn_tail":null,"chain_error":null,"header_error":null,"valid_len":377}
/// ```
///
/// * `header_ok`, `corrupt`, `first_mseq`, `first_mutation_mseq`,
///   `last_mutation_mseq`, `epoch_close` and `torn_tail` are exactly the
///   [`pdsh_wal::SegmentFacts`] fields (`name` is the caller's; it is not an
///   input here).
/// * `torn_tail` is `null` or `{"keep_len":N,"dropped_bytes":N}` — the
///   [`pdsh_wal::Truncation`] without its file name; `keep_len` is a file
///   length (`HEADER_BYTES` included).
/// * `chain_error` is the §3–§4 record-order violation (`null` when the prefix
///   is legal) and `header_error` is why the header did not verify (`null` when
///   it did). Both are `{"code":"...","detail":"..."}`.
/// * `valid_len` is the scan's trusted file length: the length to keep after a
///   truncation. For a non-tail record failure (`corrupt:true` without a
///   `chain_error`) it is `HEADER_BYTES + at`, i.e. the failing record's file
///   offset; for a chain error it is the whole verified file length.
///
/// A header failure and a non-tail record failure are different conditions:
/// `header_ok:false` follows `wal.md` §10 step 1 (listed segments use the
/// missing-segment rule, unlisted ones are `WAL_CORRUPT`), while `corrupt:true`
/// is the D19 non-tail failure or a chain violation.
pub fn scan_segment(segment: &[u8]) -> String {
    let scan = scan_segment_bytes(segment, &CHECKSUM);
    let mut out = String::with_capacity(320);
    out.push_str("{\"header_ok\":");
    push_bool(&mut out, scan.header_ok());
    out.push_str(",\"corrupt\":");
    push_bool(&mut out, scan.is_corrupt());
    out.push_str(",\"first_mseq\":");
    let first_mseq = scan.header.map(|header| header.first_mseq).unwrap_or(0);
    out.push_str(&first_mseq.to_string());
    out.push_str(",\"first_mutation_mseq\":");
    push_optional_u64(&mut out, scan.first_mutation_mseq());
    out.push_str(",\"last_mutation_mseq\":");
    out.push_str(&scan.last_mutation_mseq().to_string());
    out.push_str(",\"epoch_close\":");
    push_optional_u64(&mut out, scan.epoch_close());
    out.push_str(",\"torn_tail\":");
    match scan.verdict {
        TailVerdict::Truncate { keep, dropped } => {
            out.push_str("{\"keep_len\":");
            out.push_str(&(HEADER_BYTES + keep).to_string());
            out.push_str(",\"dropped_bytes\":");
            out.push_str(&dropped.to_string());
            out.push('}');
        }
        TailVerdict::Clean | TailVerdict::Corrupt { .. } => out.push_str("null"),
    }
    out.push_str(",\"chain_error\":");
    match &scan.chain_error {
        Some(error) => push_error_object(&mut out, error),
        None => out.push_str("null"),
    }
    out.push_str(",\"header_error\":");
    match &scan.header_error {
        Some(error) => push_error_object(&mut out, error),
        None => out.push_str("null"),
    }
    out.push_str(",\"valid_len\":");
    out.push_str(&scan.valid_len.to_string());
    out.push('}');
    out
}

/// The D11 recovery plan for one `wal/` directory.
///
/// The input is one JSON object:
///
/// ```json
/// {"wal_dir":[{"name":"wal/00000001.000000.xlwal","header_ok":true,
///              "corrupt":false,"first_mseq":1,"first_mutation_mseq":1,
///              "last_mutation_mseq":12,"epoch_close":12,"torn_tail":null}],
///  "manifest":{...} | null,
///  "reconcile_marker":false}
/// ```
///
/// A `wal_dir[]` entry is [`scan_segment`]'s output plus the `name` the caller
/// read from the directory (manifest form `wal/...` or bare). `first_mseq`,
/// `last_mutation_mseq`, `header_ok` and `corrupt` are required;
/// `first_mutation_mseq`, `epoch_close` and `torn_tail` default to `null`, and
/// `torn_tail` is `{"keep_len":N,"dropped_bytes":N}`. Unknown members are
/// ignored (`README.md` §2).
///
/// `manifest` is the §7 checkpoint object, or `null` (or absent) when the file
/// is missing, unreadable or schema-invalid — exactly the `Option<Manifest>`
/// contract of [`pdsh_wal::RecoveryInput`]. `reconcile_marker` defaults to
/// `false` when absent. The caller performs the file read; an object that fails
/// validation is a caller bug and is reported as
/// [`CODE_WAL_MANIFEST_INVALID`] or [`CODE_WAL_CORRUPT`], not silently treated
/// as `null` (a `Corrupt` manifest must fail loud, `wal.md` §7.2).
///
/// The output is the complete [`pdsh_wal::RecoveryPlan`]:
///
/// ```json
/// {"replay_segments":["wal/..."],"truncate":[{"name":"wal/...",
///  "keep_len":344,"dropped_bytes":23}],"drop_missing":[],"adopt":[],
///  "stale":[],"rebuild_manifest":true,"full_reconcile":false,
///  "clear_reconcile_marker":false,"manifest_tail_disagreement":false,
///  "effective_tail":46,"next_mseq":47,"next_epoch":2,"fail":null}
/// ```
///
/// `fail` is `null` or `{"code":"...","detail":"..."}`; when it is set every
/// other field is the empty plan. The caller applies the I/O in the order
/// `wal.md` fixes: truncations, replay, manifest replace, stale unlinks,
/// staging exchange.
pub fn plan_recovery(input: &str) -> Result<String, BridgeError> {
    let value = json::parse(input)
        .map_err(|error| BridgeError::Input(format!("planRecovery input is not JSON: {error}")))?;
    let object = value.as_object().ok_or_else(|| {
        BridgeError::Input("planRecovery input must be a JSON object".to_string())
    })?;
    let wal_dir = required_member(object, "wal_dir", "planRecovery input")?
        .as_array()
        .ok_or_else(|| {
            BridgeError::Input("planRecovery input wal_dir must be an array".to_string())
        })?;
    let mut facts = Vec::with_capacity(wal_dir.len());
    for (index, entry) in wal_dir.iter().enumerate() {
        facts.push(fact_from_json(index, entry)?);
    }
    let manifest = match member(object, "manifest") {
        None | Some(Json::Null) => None,
        Some(value) => Some(Manifest::parse(&json_to_text(value))?),
    };
    let reconcile_marker = match member(object, "reconcile_marker") {
        None => false,
        Some(Json::Bool(value)) => *value,
        Some(_) => {
            return Err(BridgeError::Input(
                "planRecovery input reconcile_marker must be a boolean".to_string(),
            ))
        }
    };
    let plan = RecoveryPlan::plan(RecoveryInput::new(facts, manifest, reconcile_marker));
    Ok(plan_json(&plan))
}

/// Parses `manifest.json` bytes and returns its canonical JSON string.
///
/// The bytes must be UTF-8. Unknown members are ignored (`README.md` §2) and
/// the output is canonical in the D5 sense (`pdsh_wal::Manifest::to_json`), so
/// [`emit_manifest`] on the result reproduces the same bytes. A schema-invalid
/// file is [`CODE_WAL_MANIFEST_INVALID`] (the caller passes `null` to
/// [`plan_recovery`]); an impossible checkpoint is [`CODE_WAL_CORRUPT`].
pub fn parse_manifest(bytes: &[u8]) -> Result<String, WalError> {
    let text = core::str::from_utf8(bytes).map_err(|error| {
        WalError::ManifestInvalid(format!("manifest.json is not UTF-8: {error}"))
    })?;
    Ok(Manifest::parse(text)?.to_json())
}

/// Parses a `manifest.json` JSON object and returns the canonical file bytes.
///
/// This is the §7.1 writer's encoder: it validates like
/// [`parse_manifest`] and ignores unknown members, so a manifest read from an
/// older or newer build round-trips through the canonical form.
pub fn emit_manifest(text: &str) -> Result<Vec<u8>, WalError> {
    Ok(Manifest::parse(text)?.to_json().into_bytes())
}

/// Verifies one complete record frame (`len ‖ crc32c ‖ mseq ‖ body`).
///
/// The input must be exactly one record; trailing bytes are a caller error
/// ([`CODE_WAL_INPUT_INVALID`]). Success is `{"ok":true}`. A failure is
///
/// ```json
/// {"ok":false,"code":"WAL_CORRUPT","detail":"...","tail_eligible":true}
/// ```
///
/// where `tail_eligible` is `pdsh_wal::RecordParseError::is_tail_eligible`:
/// only those failures may be the D19 torn tail, and only when no complete
/// record follows them (which this entry point cannot know). A malformed but
/// CRC-verified body is always `false`.
pub fn verify_record(record: &[u8]) -> String {
    match Record::parse(record, &CHECKSUM) {
        Ok(parsed) if parsed.byte_len == record.len() => "{\"ok\":true}".to_string(),
        Ok(parsed) => record_failure(
            CODE_WAL_INPUT_INVALID,
            &format!(
                "the record ends at byte {} but {} bytes were passed",
                parsed.byte_len,
                record.len()
            ),
            false,
        ),
        Err(error) => {
            let code = match &error {
                RecordParseError::ShortHeader { .. } | RecordParseError::ShortRecord { .. } => {
                    CODE_WAL_TRUNCATED
                }
                RecordParseError::BadLength(_) | RecordParseError::CrcMismatch { .. } => {
                    CODE_WAL_CORRUPT
                }
                RecordParseError::Malformed(inner) => error_code(inner),
            };
            record_failure(code, &error.to_string(), error.is_tail_eligible())
        }
    }
}

/// Every complete, CRC-verified record of one whole segment file, as JSON.
///
/// The input is a whole segment (the 40-byte header included), like
/// [`scan_segment`] and [`classify_tail`]. The output is an array of the
/// records in file order:
///
/// ```json
/// [{"mseq":42,"len":58,"crc_ok":true,"kind":"mutation","op":1,"mode":420,
///   "mflags":1,"append_from":0,"path":"/dsh/workspace/notes.txt",
///   "data_len":6,"data_hex":"68656c6c6f0a"},
///  {"mseq":46,"len":25,"crc_ok":true,"kind":"epoch_close","op":255,
///   "wall_ms":1792800000123,"durable_upto":46}]
/// ```
///
/// * `mseq` is the wire `mseq` of `wal.md` §3; for an epoch close it **is**
///   `durable_upto` (§4), exactly as on the wire.
/// * `len` is the §3 `len` field (`8 + body length`), not the total frame size.
/// * `crc_ok` is `true` for every emitted record: only complete, CRC-verified
///   frames are decoded (use [`verify_record`] to explain a failing frame).
/// * `kind` is `"mutation"` or `"epoch_close"`; a mutation carries the
///   `channel.md` §3.1 body members and an epoch close carries §4's `wall_ms`
///   and `durable_upto`.
///
/// A D19 torn tail is **omitted**, not an error: those bytes are not a record
/// and the caller's next step is [`classify_tail`] plus a truncation. A header
/// that does not verify, a non-tail record failure and a §3–§4 chain violation
/// are errors (`WAL_HEADER_INVALID`/`WAL_TRUNCATED`, `WAL_CORRUPT`), because a
/// partial record sequence with a hole must not be replayed. A header-only
/// segment is `[]`.
pub fn records(segment: &[u8]) -> Result<String, BridgeError> {
    let scan = scan_segment_bytes(segment, &CHECKSUM);
    if let Some(error) = &scan.header_error {
        return Err(BridgeError::Wal(error.clone()));
    }
    if let Some(error) = &scan.chain_error {
        return Err(BridgeError::Wal(error.clone()));
    }
    if let TailVerdict::Corrupt { at } = scan.verdict {
        return Err(BridgeError::Wal(WalError::corrupt(format!(
            "a record at file offset {} is not a complete, CRC-verified frame",
            HEADER_BYTES + at
        ))));
    }
    Ok(records_json(&scan.records))
}

/// Decodes exactly one complete record frame to the object [`records`] emits.
///
/// ```json
/// {"mseq":42,"len":58,"crc_ok":true,"kind":"mutation","op":1,"mode":420,
///  "mflags":1,"append_from":0,"path":"/dsh/workspace/notes.txt",
///  "data_len":6,"data_hex":"68656c6c6f0a"}
/// ```
///
/// The input must be one record and nothing else: trailing bytes are
/// [`CODE_WAL_INPUT_INVALID`]. A short or CRC-failing frame is
/// `WAL_TRUNCATED`/`WAL_CORRUPT` like [`verify_record`], but this entry point
/// throws instead of returning `{"ok":false}` because it produces content, not
/// a verdict.
pub fn decode_record(record: &[u8]) -> Result<String, BridgeError> {
    let parsed = Record::parse(record, &CHECKSUM)
        .map_err(|error| BridgeError::Wal(error.into_wal_error()))?;
    if parsed.byte_len != record.len() {
        return Err(BridgeError::Input(format!(
            "the record ends at byte {} but {} bytes were passed",
            parsed.byte_len,
            record.len()
        )));
    }
    Ok(record_json(&parsed.record))
}

/// The D9 idempotent appended-replay decision for one appended record.
///
/// `existing_at_offset` is the materialized file's bytes starting at
/// `append_from`, or `None` when the path is absent, is a directory or is not a
/// regular file — all of which are a base mismatch. The caller reads those
/// bytes; this entry point performs no I/O.
///
/// The output is a single verdict of `wal.md` §6.2:
///
/// | Decision | JSON |
/// | --- | --- |
/// | `Applied` (`S == A`) | `{"verdict":"applied"}` |
/// | `Skip` (already present) | `{"verdict":"skip"}` |
/// | `Resync` (base mismatch) | `{"verdict":"resync"}` |
pub fn appended_replay(
    current_size: u64,
    append_from: u64,
    data: &[u8],
    existing_at_offset: Option<&[u8]>,
) -> String {
    let verdict = match replay_decision(current_size, append_from, data, existing_at_offset) {
        ReplayDecision::Applied => "applied",
        ReplayDecision::Skip => "skip",
        ReplayDecision::Resync => "resync",
    };
    format!("{{\"verdict\":\"{verdict}\"}}")
}

/// The D9 retained-sequence supersession predicate (`wal.md` §6.2).
///
/// The input is a JSON array of retained records in ascending `mseq` order:
/// `{"mseq":N,"op":1|3,"appended":bool,"path":"/dsh/..."}`. Unknown members are
/// ignored (`spec/v1/README.md` §2); the output has one object per input record:
///
/// * `{"mseq":N,"verdict":"settled-superseded","cover":"complete-write|remove|ancestor-remove","superseded_by_mseq":M}`
///   for an appended record a later retained record covers;
/// * `{"mseq":N,"verdict":"not-superseded"}` otherwise.
///
/// The verdict alone must not advance a watermark: the caller uses
/// `superseded_by_mseq` and only counts the settled record when that cover is
/// inside the same contiguous prefix. `appended_replay` remains the one-record
/// three-way base check; this entry point is the fourth D9 decision.
pub fn retained_supersession(records_json: &str) -> Result<String, BridgeError> {
    let value = json::parse(records_json)
        .map_err(|error| BridgeError::Input(format!("retained records are not JSON: {error}")))?;
    let records = value
        .as_array()
        .ok_or_else(|| BridgeError::Input("retained records must be a JSON array".to_string()))?;
    let mut parsed: Vec<(u64, u8, bool, String)> = Vec::with_capacity(records.len());
    for (index, record) in records.iter().enumerate() {
        let at = format!("retained records[{index}]");
        let object = record
            .as_object()
            .ok_or_else(|| BridgeError::Input(format!("{at} is not an object")))?;
        let mseq = required_member(object, "mseq", &at)?
            .as_u64()
            .ok_or_else(|| BridgeError::Input(format!("{at}.mseq is not an integer")))?;
        if mseq == 0 {
            return Err(BridgeError::Input(format!("{at}.mseq must be at least 1")));
        }
        let op = required_member(object, "op", &at)?
            .as_u64()
            .ok_or_else(|| BridgeError::Input(format!("{at}.op is not an integer")))?;
        let op = u8::try_from(op)
            .map_err(|_| BridgeError::Input(format!("{at}.op does not fit a byte")))?;
        let appended = match required_member(object, "appended", &at)? {
            Json::Bool(value) => *value,
            _ => {
                return Err(BridgeError::Input(format!(
                    "{at}.appended is not a boolean"
                )))
            }
        };
        let path = required_member(object, "path", &at)?
            .as_str()
            .ok_or_else(|| BridgeError::Input(format!("{at}.path is not a string")))?;
        if path.is_empty() {
            return Err(BridgeError::Input(format!("{at}.path is empty")));
        }
        parsed.push((mseq, op, appended, path.to_string()));
    }
    for pair in parsed.windows(2) {
        if pair[1].0 <= pair[0].0 {
            return Err(BridgeError::Input(
                "retained records must be in strictly ascending mseq order".to_string(),
            ));
        }
    }
    let paths: Vec<String> = parsed.iter().map(|record| record.3.clone()).collect();
    let retained: Vec<RetainedRecord<'_>> = parsed
        .iter()
        .zip(paths.iter())
        .map(|(record, path)| RetainedRecord::new(record.0, record.1, record.2, path))
        .collect();
    let mut out = String::with_capacity(records.len() * 64 + 2);
    out.push('[');
    for (index, record) in retained.iter().enumerate() {
        if index > 0 {
            out.push(',');
        }
        out.push_str("{\"mseq\":");
        out.push_str(&record.mseq.to_string());
        match replay_supersession(&retained, index) {
            Some(supersession) => {
                out.push_str(",\"verdict\":\"settled-superseded\",\"cover\":\"");
                out.push_str(match supersession.kind {
                    CoverKind::CompleteWrite => "complete-write",
                    CoverKind::Remove => "remove",
                    CoverKind::AncestorRemove => "ancestor-remove",
                });
                out.push_str("\",\"superseded_by_mseq\":");
                out.push_str(&supersession.cover_mseq.to_string());
            }
            None => out.push_str(",\"verdict\":\"not-superseded\""),
        }
        out.push('}');
    }
    out.push(']');
    Ok(out)
}

/// The record array of [`records`].
fn records_json(records: &[Record]) -> String {
    let mut out = String::with_capacity(records.len() * 160 + 2);
    out.push('[');
    for (index, record) in records.iter().enumerate() {
        if index > 0 {
            out.push(',');
        }
        push_record(&mut out, record);
    }
    out.push(']');
    out
}

/// One record object of [`records`] / [`decode_record`].
///
/// Member order is stable (`records` and `decode_record` share this renderer),
/// but a decoder must ignore unknown members (`spec/v1/README.md` §2).
fn record_json(record: &Record) -> String {
    let mut out = String::with_capacity(192);
    push_record(&mut out, record);
    out
}

fn push_record(out: &mut String, record: &Record) {
    out.push_str("{\"mseq\":");
    out.push_str(&record.wire_mseq().to_string());
    out.push_str(",\"len\":");
    out.push_str(&record_len(record).to_string());
    out.push_str(",\"crc_ok\":true,\"kind\":");
    match record {
        Record::Mutation(mutation) => {
            let body = &mutation.body;
            out.push_str("\"mutation\",\"op\":");
            out.push_str(&body.op.to_string());
            out.push_str(",\"mode\":");
            out.push_str(&body.mode.to_string());
            out.push_str(",\"mflags\":");
            out.push_str(&body.mflags.to_string());
            out.push_str(",\"append_from\":");
            out.push_str(&body.append_from.to_string());
            out.push_str(",\"path\":");
            push_json_string(out, &body.path);
            out.push_str(",\"data_len\":");
            out.push_str(&body.data.len().to_string());
            out.push_str(",\"data_hex\":");
            push_hex_string(out, &body.data);
        }
        // W6 `wal.md` §14.2 write-by-reference. This is a codec rendering only:
        // the Kotlin/Android host store still does not implement W6 and its own
        // `WalSegmentReader` keeps failing loud on `op = 0xFE`; serialising the
        // fields here does not make Android read a W6 workspace.
        Record::BlobWrite(blob) => {
            out.push_str("\"blob_write\",\"op\":");
            out.push_str(&OP_BLOB_WRITE.to_string());
            out.push_str(",\"mode\":");
            out.push_str(&blob.mode.to_string());
            out.push_str(",\"mflags\":");
            out.push_str(&blob.mflags.to_string());
            out.push_str(",\"append_from\":");
            out.push_str(&blob.append_from.to_string());
            out.push_str(",\"blob_len\":");
            out.push_str(&blob.blob_len.to_string());
            out.push_str(",\"blob_sha256\":");
            push_hex_string(out, &blob.blob_sha256);
            out.push_str(",\"path\":");
            push_json_string(out, &blob.path);
        }
        Record::EpochClose(close) => {
            out.push_str("\"epoch_close\",\"op\":");
            out.push_str(&OP_EPOCH_CLOSE.to_string());
            out.push_str(",\"wall_ms\":");
            out.push_str(&close.wall_ms.to_string());
            out.push_str(",\"durable_upto\":");
            out.push_str(&close.durable_upto.to_string());
        }
    }
    out.push('}');
}

/// The §3 `len` field of a parsed record: `8 + body length`.
///
/// It is arithmetic on the parsed body instead of `Record::emit` so a large
/// write body is not copied just to learn its length.
fn record_len(record: &Record) -> usize {
    match record {
        Record::Mutation(mutation) => {
            RECORD_PREFIX_BYTES
                + BODY_HEADER_BYTES
                + mutation.body.path.len()
                + 4
                + mutation.body.data.len()
        }
        Record::BlobWrite(blob) => {
            // §14.2 fixed body: op(1) + mode(4) + mflags(1) + append_from(8) +
            // blob_len(4) + sha256(32) + path_len(2) = 52, then the path.
            RECORD_PREFIX_BYTES + 52 + blob.path.len()
        }
        Record::EpochClose(_) => RECORD_PREFIX_BYTES + EPOCH_CLOSE_BODY_BYTES,
    }
}

/// Appends lowercase hex as a JSON string (`golden/README.md` §3's form for raw
/// bytes).
fn push_hex_string(out: &mut String, bytes: &[u8]) {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    out.push('"');
    for &byte in bytes {
        out.push(char::from(DIGITS[usize::from(byte >> 4)]));
        out.push(char::from(DIGITS[usize::from(byte & 0x0F)]));
    }
    out.push('"');
}

fn record_failure(code: &str, detail: &str, tail_eligible: bool) -> String {
    let mut out = String::with_capacity(192);
    out.push_str("{\"ok\":false,\"code\":");
    push_json_string(&mut out, code);
    out.push_str(",\"detail\":");
    push_json_string(&mut out, detail);
    out.push_str(",\"tail_eligible\":");
    push_bool(&mut out, tail_eligible);
    out.push('}');
    out
}

fn fact_from_json(index: usize, value: &Json) -> Result<SegmentFacts, BridgeError> {
    let context = format!("wal_dir[{index}]");
    let object = value
        .as_object()
        .ok_or_else(|| BridgeError::Input(format!("{context} must be an object")))?;
    let name = SegmentName::parse(required_string(object, "name", &context)?)?;
    let header_ok = required_bool(object, "header_ok", &context)?;
    let corrupt = required_bool(object, "corrupt", &context)?;
    let first_mseq = required_uint(object, "first_mseq", &context)?;
    let last_mutation_mseq = required_uint(object, "last_mutation_mseq", &context)?;
    let first_mutation_mseq = optional_uint(object, "first_mutation_mseq", &context)?;
    let epoch_close = optional_uint(object, "epoch_close", &context)?;
    let torn_tail = match member(object, "torn_tail") {
        None | Some(Json::Null) => None,
        Some(value) => {
            let tail_context = format!("{context}.torn_tail");
            let tail = value.as_object().ok_or_else(|| {
                BridgeError::Input(format!("{tail_context} must be an object or null"))
            })?;
            let keep_len = required_uint(tail, "keep_len", &tail_context)?;
            let dropped_bytes = required_uint(tail, "dropped_bytes", &tail_context)?;
            let keep_len = usize::try_from(keep_len).map_err(|_| {
                BridgeError::Input(format!("{tail_context}.keep_len does not fit usize"))
            })?;
            let dropped_bytes = usize::try_from(dropped_bytes).map_err(|_| {
                BridgeError::Input(format!("{tail_context}.dropped_bytes does not fit usize"))
            })?;
            Some(Truncation {
                name,
                keep_len,
                dropped_bytes,
            })
        }
    };
    Ok(SegmentFacts {
        name,
        header_ok,
        corrupt,
        first_mseq,
        first_mutation_mseq,
        last_mutation_mseq,
        epoch_close,
        torn_tail,
    })
}

fn plan_json(plan: &RecoveryPlan) -> String {
    let mut out = String::with_capacity(640);
    out.push_str("{\"replay_segments\":");
    push_segment_array(&mut out, &plan.replay_segments);
    out.push_str(",\"truncate\":");
    push_truncation_array(&mut out, &plan.truncate);
    out.push_str(",\"drop_missing\":");
    push_segment_array(&mut out, &plan.drop_missing);
    out.push_str(",\"adopt\":");
    push_segment_array(&mut out, &plan.adopt);
    out.push_str(",\"stale\":");
    push_segment_array(&mut out, &plan.stale);
    out.push_str(",\"rebuild_manifest\":");
    push_bool(&mut out, plan.rebuild_manifest);
    out.push_str(",\"full_reconcile\":");
    push_bool(&mut out, plan.full_reconcile);
    out.push_str(",\"clear_reconcile_marker\":");
    push_bool(&mut out, plan.clear_reconcile_marker);
    out.push_str(",\"manifest_tail_disagreement\":");
    push_bool(&mut out, plan.manifest_tail_disagreement);
    out.push_str(",\"effective_tail\":");
    out.push_str(&plan.effective_tail.to_string());
    out.push_str(",\"next_mseq\":");
    out.push_str(&plan.next_mseq.to_string());
    out.push_str(",\"next_epoch\":");
    out.push_str(&plan.next_epoch.to_string());
    out.push_str(",\"fail\":");
    match &plan.fail {
        Some(error) => push_error_object(&mut out, error),
        None => out.push_str("null"),
    }
    out.push('}');
    out
}

fn push_segment_array(out: &mut String, segments: &[SegmentName]) {
    out.push('[');
    for (index, segment) in segments.iter().enumerate() {
        if index > 0 {
            out.push(',');
        }
        push_json_string(out, &segment.file());
    }
    out.push(']');
}

fn push_truncation_array(out: &mut String, truncations: &[Truncation]) {
    out.push('[');
    for (index, truncation) in truncations.iter().enumerate() {
        if index > 0 {
            out.push(',');
        }
        out.push_str("{\"name\":");
        push_json_string(out, &truncation.name.file());
        out.push_str(",\"keep_len\":");
        out.push_str(&truncation.keep_len.to_string());
        out.push_str(",\"dropped_bytes\":");
        out.push_str(&truncation.dropped_bytes.to_string());
        out.push('}');
    }
    out.push(']');
}

fn push_error_object(out: &mut String, error: &WalError) {
    out.push_str("{\"code\":");
    push_json_string(out, error_code(error));
    out.push_str(",\"detail\":");
    push_json_string(out, &error_detail(error));
    out.push('}');
}

fn push_optional_u64(out: &mut String, value: Option<u64>) {
    match value {
        Some(value) => out.push_str(&value.to_string()),
        None => out.push_str("null"),
    }
}

fn push_bool(out: &mut String, value: bool) {
    out.push_str(if value { "true" } else { "false" });
}

/// Appends `text` as a JSON string. The manifest's own writer escapes too; the
/// bridge details can contain quotes and newlines from a `WalError`.
fn push_json_string(out: &mut String, text: &str) {
    out.push('"');
    for character in text.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            character if (character as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", character as u32));
            }
            character => out.push(character),
        }
    }
    out.push('"');
}

fn member<'a>(object: &'a [(String, Json)], name: &str) -> Option<&'a Json> {
    object
        .iter()
        .find_map(|(key, value)| (key == name).then_some(value))
}

fn required_member<'a>(
    object: &'a [(String, Json)],
    name: &str,
    context: &str,
) -> Result<&'a Json, BridgeError> {
    member(object, name)
        .ok_or_else(|| BridgeError::Input(format!("{context} has no {name:?} member")))
}

fn required_string<'a>(
    object: &'a [(String, Json)],
    name: &str,
    context: &str,
) -> Result<&'a str, BridgeError> {
    required_member(object, name, context)?
        .as_str()
        .ok_or_else(|| BridgeError::Input(format!("{context} {name:?} must be a string")))
}

fn required_bool(
    object: &[(String, Json)],
    name: &str,
    context: &str,
) -> Result<bool, BridgeError> {
    match required_member(object, name, context)? {
        Json::Bool(value) => Ok(*value),
        _ => Err(BridgeError::Input(format!(
            "{context} {name:?} must be a boolean"
        ))),
    }
}

fn required_uint(object: &[(String, Json)], name: &str, context: &str) -> Result<u64, BridgeError> {
    required_member(object, name, context)?
        .as_u64()
        .ok_or_else(|| {
            BridgeError::Input(format!("{context} {name:?} must be a non-negative integer"))
        })
}

fn optional_uint(
    object: &[(String, Json)],
    name: &str,
    context: &str,
) -> Result<Option<u64>, BridgeError> {
    match member(object, name) {
        None | Some(Json::Null) => Ok(None),
        Some(value) => value.as_u64().map(Some).ok_or_else(|| {
            BridgeError::Input(format!(
                "{context} {name:?} must be a non-negative integer or null"
            ))
        }),
    }
}

/// The supported JSON subset as text, for feeding an embedded manifest object
/// to the one manifest parser (`pdsh_wal::Manifest::parse`).
///
/// `pdsh_wal::json` has no writer on purpose; this keeps the parser as the
/// single schema gate instead of duplicating the member checks here. Unknown
/// members survive the round trip and are ignored by the parser
/// (`README.md` §2).
fn json_to_text(value: &Json) -> String {
    let mut out = String::new();
    push_json_value(&mut out, value);
    out
}

fn push_json_value(out: &mut String, value: &Json) {
    match value {
        Json::Null => out.push_str("null"),
        Json::Bool(true) => out.push_str("true"),
        Json::Bool(false) => out.push_str("false"),
        Json::Uint(number) => out.push_str(&number.to_string()),
        Json::String(text) => push_json_string(out, text),
        Json::Array(values) => {
            out.push('[');
            for (index, value) in values.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                push_json_value(out, value);
            }
            out.push(']');
        }
        Json::Object(members) => {
            out.push('{');
            for (index, (name, value)) in members.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                push_json_string(out, name);
                out.push(':');
                push_json_value(out, value);
            }
            out.push('}');
        }
    }
}
