// SPDX-License-Identifier: MIT
//! JNI surface of `pdsh-wire`, the `pdsh-wal` kernel and the read-only
//! accelerator registry (`pdsh-ffi`) for the Android host.
//!
//! Three Java/Kotlin classes are fixed by the exported symbol names:
//!
//! * `com.phonedsh.wire.NativeWire` — the wire codec (`pdsh-wire`).
//! * `com.phonedsh.wire.NativeWal` — the I/O-free WAL kernel (`pdsh-wal`).
//! * `com.phonedsh.shell.NativeShell` — the read-only accelerators, through the
//!   one C ABI of `pdsh-ffi` (`shell/include/xzshell.h`).
//!
//! Every exported symbol is `Java_com_phonedsh_<package>_<Class>_<method>`. The
//! methods are the thin native half of the otherwise pure-Kotlin `:core` and
//! `:shell` modules.
//!
//! | Kotlin declaration | Exported symbol suffix | Contract |
//! | --- | --- | --- |
//! | `crc32cNative(ByteArray): Int` | `NativeWire.crc32cNative` | CRC-32C of the bytes |
//! | `encodeFrameNative(Long, String): ByteArray` | `NativeWire.encodeFrameNative` | golden `fields` JSON → `frame_hex` bytes |
//! | `decodeFrameNative(ByteArray): String` | `NativeWire.decodeFrameNative` | `frame_hex` bytes → canonical `fields` JSON |
//! | `canonicalJsonNative(String): String` | `NativeWire.canonicalJsonNative` | canonical JSON (`channel.md` §5) |
//! | `panicForTestNative(String): String` | `NativeWire.panicForTestNative` | test-only panic hook; proves the boundary |
//!
//! # WAL entries (`NativeWal`, experimental)
//!
//! **The WAL ABI is not frozen before the R1 conclusion** (Android adaptation
//! plan §8.2-2): these entry points are experimental and may change with the
//! WAL semantics. They expose only the pure half of `spec/v1/wal.md` — format
//! parsing, D19 tail classification, the §7 manifest model and the D11
//! recovery plan — and perform **no I/O**: no file is read, no fsync, no
//! truncate, no rename, no unlink. fsync order (§5.2), the epoch close, the
//! atomic manifest replace (§7.1) and the staged reconcile (§7.2) stay in the
//! Kotlin/per-OS layer.
//!
//! | Kotlin declaration | Exported symbol suffix | Contract |
//! | --- | --- | --- |
//! | `classifyTailNative(ByteArray): String` | `NativeWal.classifyTailNative` | D19 verdict for a whole segment (file offsets) |
//! | `scanSegmentNative(ByteArray): String` | `NativeWal.scanSegmentNative` | `SegmentFacts` + `chain_error` / `header_error` / `valid_len` |
//! | `planRecoveryNative(String): String` | `NativeWal.planRecoveryNative` | recovery facts + manifest → `RecoveryPlan` JSON |
//! | `parseManifestNative(ByteArray): String` | `NativeWal.parseManifestNative` | `manifest.json` bytes → canonical JSON |
//! | `emitManifestNative(String): ByteArray` | `NativeWal.emitManifestNative` | manifest JSON object → canonical `manifest.json` bytes |
//! | `verifyRecordNative(ByteArray): String` | `NativeWal.verifyRecordNative` | one record's CRC/structure → `{"ok":true}` or a coded error |
//! | `recordsNative(ByteArray): String` | `NativeWal.recordsNative` | one segment's verified records, decoded to a JSON array |
//! | `decodeRecordNative(ByteArray): String` | `NativeWal.decodeRecordNative` | exactly one record's decoded body as a JSON object |
//! | `appendedReplayNative(Long, Long, ByteArray, ByteArray?): String` | `NativeWal.appendedReplayNative` | D9 verdict: `applied` / `skip` / `resync` |
//! | `panicForTestNative(String): String` | `NativeWal.panicForTestNative` | test-only panic hook; proves the boundary |
//!
//! The exact JSON shapes and error codes are in [`wal`]; every entry point is
//! documented there and may change while the WAL ABI is experimental.
//!
//! # Accelerator entries (`NativeShell`)
//!
//! These three symbols do not implement an accelerator. They wrap the single
//! unified C ABI that already exists for the Swift host (`pdsh-ffi`): one
//! `pdsh_run` call with an `argv` whose `argv[0]` selects `rg` / `jaq` /
//! `ts-parse` / ... from the linked registry. There is no second registry, no
//! Kotlin argv parser and no per-accelerator symbol here; [`shell`] documents
//! the validation, the join and the result frame.
//!
//! | Kotlin declaration | Exported symbol suffix | Contract |
//! | --- | --- | --- |
//! | `capsJsonNative(Boolean): String` | `NativeShell.capsJsonNative` | capability JSON of the linked registry, host-bridge set on/off |
//! | `runNative(Array<String>, String, Array<String>, Array<String>, Array<String>, Array<String>, Long, Long, Long, Long): ByteArray` | `NativeShell.runNative` | one completed run: exit code + stdout + stderr frame |
//! | `jaqReadsStdinNative(Array<String>): Boolean` | `NativeShell.jaqReadsStdinNative` | whether a `jaq` argv would read the process stdin |
//! | `panicForTestNative(String): String` | `NativeShell.panicForTestNative` | test-only panic hook; proves the boundary |
//!
//! `runNative` passes `call_tool = NULL`, so the FFI registers neither `phone`
//! nor `ctx` and `capsJsonNative` always asks for the no-bridge set: the JSON
//! and the executable set describe the same registry.
//!
//! # Panic and error boundary
//!
//! Every entry point wraps its work in [`std::panic::catch_unwind`]. A panic
//! never crosses the FFI boundary: it is caught and rethrown as a Java
//! [`RUNTIME_EXCEPTION_CLASS`] whose message starts with `PDSH_JNI_PANIC`.
//! A [`pdsh_wire::WireError`] is rethrown as a `java.lang.RuntimeException`
//! whose message is `"<CODE>: <detail>"`, where `<CODE>` is the `channel.md`
//! §10 string; the Kotlin binding turns that into `WireException(code, detail)`.
//! A [`pdsh_wal::WalError`] or [`wal::BridgeError`] is rethrown the same way
//! with the code table of [`wal`]. A [`shell::ShellError`] follows the same
//! `"<CODE>: <detail>"` shape with the `SHELL_*` table of [`shell`]; the Kotlin
//! binding turns it into `AcceleratorException(code, detail)`.
//!
//! The crate is built with `panic = "unwind"` (the workspace default). A build
//! with `panic = "abort"` is rejected by the `compile_error!` below, because
//! `catch_unwind` cannot catch an abort and a panic across JNI is undefined
//! behaviour.
//!
//! The wire, WAL and capability entry points perform no I/O. `NativeShell.run`
//! is the one entry point that reads files: it runs the sandboxed read-only
//! accelerators through `pdsh-ffi`, which opens only the host directories the
//! caller mounted.

#[cfg(panic = "abort")]
compile_error!(
    "pdsh-jni requires `panic = \"unwind\"`: catch_unwind cannot stop an abort, and a panic across the JNI boundary is undefined behaviour"
);

pub mod bridge;
pub mod shell;
pub mod wal;

use std::any::Any;
use std::panic::{catch_unwind, AssertUnwindSafe};

use jni::objects::{JByteArray, JObject, JObjectArray, JString};
use jni::strings::JNIString;
use jni::sys::{jboolean, jbyteArray, jint, jlong, jstring};
use jni::{Env, EnvUnowned};
use pdsh_wal::WalError;
use pdsh_wire::WireError;

use bridge::{canonical_json, decode_frame, encode_frame};

/// The Java class thrown for every failure.
pub const RUNTIME_EXCEPTION_CLASS: &str = "java/lang/RuntimeException";

/// A failure of one native entry point.
///
/// `Wire` covers the codec's `channel.md` §10 errors, `Wal` and `Input` cover
/// the WAL kernel and its JSON arguments, `Shell` covers the accelerator bridge
/// and its arguments, and `Jni` covers a failed JNI interaction (for example a
/// null argument). All become Java exceptions.
enum Failure {
    /// A codec or JSON failure carrying a §10 code.
    Wire(WireError),
    /// A WAL failure carrying the code table of [`wal`].
    Wal(WalError),
    /// An accelerator bridge failure carrying the code table of [`shell`].
    Shell(shell::ShellError),
    /// A WAL bridge argument that is not the documented JSON shape.
    Input(String),
    /// A JNI call that could not be completed.
    Jni(jni::errors::Error),
}

impl Failure {
    /// The Java exception message. A `Wire` failure is `"<CODE>: <detail>"`.
    fn message(&self) -> String {
        match self {
            Self::Wire(error) => error.to_string(),
            Self::Wal(error) => wal::error_message(error),
            Self::Shell(error) => error.to_string(),
            Self::Input(detail) => format!("{}: {detail}", wal::CODE_WAL_INPUT_INVALID),
            Self::Jni(error) => format!("pdsh-jni call failed: {error}"),
        }
    }
}

impl From<shell::ShellError> for Failure {
    fn from(error: shell::ShellError) -> Self {
        Self::Shell(error)
    }
}

impl From<WireError> for Failure {
    fn from(error: WireError) -> Self {
        Self::Wire(error)
    }
}

impl From<WalError> for Failure {
    fn from(error: WalError) -> Self {
        Self::Wal(error)
    }
}

impl From<wal::BridgeError> for Failure {
    fn from(error: wal::BridgeError) -> Self {
        match error {
            wal::BridgeError::Input(detail) => Self::Input(detail),
            wal::BridgeError::Wal(error) => Self::Wal(error),
        }
    }
}

impl From<jni::errors::Error> for Failure {
    fn from(error: jni::errors::Error) -> Self {
        Self::Jni(error)
    }
}

/// Runs `body` under the panic boundary and formats a caught panic exactly as
/// the Java exception message.
///
/// This is the one implementation of the boundary; [`run_entry`] adds the Java
/// throw. It is public so an integration test can prove that a panic becomes a
/// message instead of escaping (the Java class is [`RUNTIME_EXCEPTION_CLASS`]).
#[doc(hidden)]
pub fn catch_panic<T>(operation: &'static str, body: impl FnOnce() -> T) -> Result<T, String> {
    // `AssertUnwindSafe` is sound here: the body only touches JNI references
    // owned by this call and Rust values that are dropped by the unwind; the
    // Java side sees either the returned value or the thrown exception.
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(value) => Ok(value),
        Err(payload) => Err(format!(
            "PDSH_JNI_PANIC: {operation}: {}",
            panic_message(payload.as_ref())
        )),
    }
}

/// Runs one entry point's body with the panic boundary and the exception
/// mapping of the module docs.
///
/// On failure the Java exception is thrown and the JVM's default value for the
/// native return type (`0` or `null`) is returned.
fn run_entry<'frame, T, F>(
    env: &mut Env<'frame>,
    operation: &'static str,
    body: F,
) -> jni::errors::Result<T>
where
    T: Default,
    F: FnOnce(&mut Env<'frame>) -> Result<T, Failure>,
{
    match catch_panic(operation, || body(env)) {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(failure)) => {
            throw_runtime(env, &failure.message());
            Ok(T::default())
        }
        Err(message) => {
            throw_runtime(env, &message);
            Ok(T::default())
        }
    }
}

/// Throws [`RUNTIME_EXCEPTION_CLASS`] with `message`.
///
/// A failed throw (for example a broken JVM) leaves no exception pending; the
/// entry point still returns the JVM default instead of unwinding.
fn throw_runtime(env: &mut Env<'_>, message: &str) {
    let class = JNIString::new(RUNTIME_EXCEPTION_CLASS);
    let text = JNIString::new(message);
    // `throw_new` reports `Err(JavaException)` once the exception is pending;
    // that is the success path here, so the result is ignored on purpose.
    let _ = env.throw_new(class, text);
}

/// Renders a panic payload for the Java exception message.
fn panic_message(payload: &(dyn Any + Send)) -> String {
    if let Some(message) = payload.downcast_ref::<&'static str>() {
        (*message).to_owned()
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message.clone()
    } else {
        "non-string panic payload".to_owned()
    }
}

fn read_bytes(env: &Env<'_>, array: &JByteArray<'_>) -> Result<Vec<u8>, Failure> {
    env.convert_byte_array(array).map_err(Failure::Jni)
}

fn read_string(env: &Env<'_>, value: &JString<'_>) -> Result<String, Failure> {
    value.try_to_string(env).map_err(Failure::Jni)
}

/// Reads one `String[]` argument; a null array or a null element is a JNI
/// failure, not an empty list.
fn read_strings<'frame>(
    env: &mut Env<'frame>,
    values: &JObjectArray<'frame, JString<'frame>>,
) -> Result<Vec<String>, Failure> {
    let length = values.len(env).map_err(Failure::Jni)?;
    let mut strings = Vec::with_capacity(length);
    for index in 0..length {
        let element = values.get_element(env, index).map_err(Failure::Jni)?;
        strings.push(read_string(env, &element)?);
    }
    Ok(strings)
}

/// An accelerator bridge argument that cannot describe a run.
fn shell_input(detail: impl Into<String>) -> Failure {
    Failure::Shell(shell::ShellError::Input(detail.into()))
}

/// Converts a Java `long` timeout/byte-count argument to `u64`; a negative value
/// is a caller bug ([`shell::CODE_INPUT_INVALID`]).
fn shell_u64(value: jlong, name: &str) -> Result<u64, Failure> {
    u64::try_from(value).map_err(|_| shell_input(format!("{name} must be a non-negative integer")))
}

/// Converts a Java `long` array count to this platform's `usize`.
fn shell_usize(value: jlong, name: &str) -> Result<usize, Failure> {
    usize::try_from(value).map_err(|_| {
        shell_input(format!(
            "{name} must be a non-negative integer that fits the platform's usize"
        ))
    })
}

/// Pairs two equally long string arrays; a length mismatch is a caller bug.
fn shell_pairs(
    names: Vec<String>,
    values: Vec<String>,
    what: &str,
) -> Result<Vec<(String, String)>, Failure> {
    if names.len() != values.len() {
        return Err(shell_input(format!(
            "{what} must be passed as two arrays of the same length"
        )));
    }
    Ok(names.into_iter().zip(values).collect())
}

/// Converts a Java `long` argument to the non-negative integer the WAL
/// decision needs; a negative value is a caller bug ([`wal::CODE_WAL_INPUT_INVALID`]).
fn non_negative(value: jlong, name: &str) -> Result<u64, Failure> {
    u64::try_from(value).map_err(|_| {
        Failure::Input(format!(
            "appendedReplay {name} must be a non-negative integer"
        ))
    })
}

fn frame_seq(seq: jlong) -> Result<u64, Failure> {
    u64::try_from(seq).map_err(|_| {
        Failure::Wire(WireError::bad_seq(
            "frame seq must be a non-negative integer",
        ))
    })
}

/// `NativeWire.crc32cNative(ByteArray): Int`
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_phonedsh_wire_NativeWire_crc32cNative<'frame>(
    mut unowned_env: EnvUnowned<'frame>,
    _this: JObject<'frame>,
    data: JByteArray<'frame>,
) -> jint {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jint> {
            run_entry(env, "crc32c", |env| {
                let bytes = read_bytes(env, &data)?;
                Ok(pdsh_wire::crc32c(&bytes) as jint)
            })
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `NativeWire.encodeFrameNative(Long, String): ByteArray`
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_phonedsh_wire_NativeWire_encodeFrameNative<'frame>(
    mut unowned_env: EnvUnowned<'frame>,
    _this: JObject<'frame>,
    seq: jlong,
    frame_json: JString<'frame>,
) -> jbyteArray {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jbyteArray> {
            run_entry(env, "encodeFrame", |env| {
                let seq = frame_seq(seq)?;
                let text = read_string(env, &frame_json)?;
                let bytes = encode_frame(&text, seq)?;
                let array = env.byte_array_from_slice(&bytes)?;
                Ok(array.as_raw() as jbyteArray)
            })
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `NativeWire.decodeFrameNative(ByteArray): String`
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_phonedsh_wire_NativeWire_decodeFrameNative<'frame>(
    mut unowned_env: EnvUnowned<'frame>,
    _this: JObject<'frame>,
    data: JByteArray<'frame>,
) -> jstring {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jstring> {
            run_entry(env, "decodeFrame", |env| {
                let bytes = read_bytes(env, &data)?;
                let fields = decode_frame(&bytes)?;
                let text = env.new_string(fields)?;
                Ok(text.as_raw() as jstring)
            })
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `NativeWire.canonicalJsonNative(String): String`
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_phonedsh_wire_NativeWire_canonicalJsonNative<'frame>(
    mut unowned_env: EnvUnowned<'frame>,
    _this: JObject<'frame>,
    json: JString<'frame>,
) -> jstring {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jstring> {
            run_entry(env, "canonicalJson", |env| {
                let text = read_string(env, &json)?;
                let canonical = canonical_json(&text)?;
                let out = env.new_string(canonical)?;
                Ok(out.as_raw() as jstring)
            })
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `NativeWire.panicForTestNative(String): String` — test-only panic hook.
///
/// Always panics. It exists so the Kotlin suite can prove that a Rust panic
/// arrives as a Java exception (and a message) instead of aborting the JVM.
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_phonedsh_wire_NativeWire_panicForTestNative<'frame>(
    mut unowned_env: EnvUnowned<'frame>,
    _this: JObject<'frame>,
    message: JString<'frame>,
) -> jstring {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jstring> {
            run_entry(env, "panicForTest", |env| -> Result<jstring, Failure> {
                let message = read_string(env, &message)?;
                panic!("intentional panic hook: {message}");
            })
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `NativeWal.classifyTailNative(ByteArray): String` — **experimental**.
///
/// D19 tail classification of one whole segment file; see
/// [`wal::classify_tail`]. The input includes the 40-byte header and the
/// returned offsets are file offsets.
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_phonedsh_wire_NativeWal_classifyTailNative<'frame>(
    mut unowned_env: EnvUnowned<'frame>,
    _this: JObject<'frame>,
    segment: JByteArray<'frame>,
) -> jstring {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jstring> {
            run_entry(env, "classifyTail", |env| {
                let bytes = read_bytes(env, &segment)?;
                let json = wal::classify_tail(&bytes)?;
                let text = env.new_string(json)?;
                Ok(text.as_raw() as jstring)
            })
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `NativeWal.scanSegmentNative(ByteArray): String` — **experimental**.
///
/// One segment's facts; see [`wal::scan_segment`].
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_phonedsh_wire_NativeWal_scanSegmentNative<'frame>(
    mut unowned_env: EnvUnowned<'frame>,
    _this: JObject<'frame>,
    segment: JByteArray<'frame>,
) -> jstring {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jstring> {
            run_entry(env, "scanSegment", |env| {
                let bytes = read_bytes(env, &segment)?;
                let json = wal::scan_segment(&bytes);
                let text = env.new_string(json)?;
                Ok(text.as_raw() as jstring)
            })
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `NativeWal.planRecoveryNative(String): String` — **experimental**.
///
/// The D11 recovery plan; see [`wal::plan_recovery`].
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_phonedsh_wire_NativeWal_planRecoveryNative<'frame>(
    mut unowned_env: EnvUnowned<'frame>,
    _this: JObject<'frame>,
    input: JString<'frame>,
) -> jstring {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jstring> {
            run_entry(env, "planRecovery", |env| {
                let text = read_string(env, &input)?;
                let json = wal::plan_recovery(&text)?;
                let out = env.new_string(json)?;
                Ok(out.as_raw() as jstring)
            })
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `NativeWal.parseManifestNative(ByteArray): String` — **experimental**.
///
/// `manifest.json` bytes to canonical JSON; see [`wal::parse_manifest`].
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_phonedsh_wire_NativeWal_parseManifestNative<'frame>(
    mut unowned_env: EnvUnowned<'frame>,
    _this: JObject<'frame>,
    manifest: JByteArray<'frame>,
) -> jstring {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jstring> {
            run_entry(env, "parseManifest", |env| {
                let bytes = read_bytes(env, &manifest)?;
                let json = wal::parse_manifest(&bytes)?;
                let text = env.new_string(json)?;
                Ok(text.as_raw() as jstring)
            })
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `NativeWal.emitManifestNative(String): ByteArray` — **experimental**.
///
/// A manifest JSON object to canonical `manifest.json` bytes; see
/// [`wal::emit_manifest`].
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_phonedsh_wire_NativeWal_emitManifestNative<'frame>(
    mut unowned_env: EnvUnowned<'frame>,
    _this: JObject<'frame>,
    manifest_json: JString<'frame>,
) -> jbyteArray {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jbyteArray> {
            run_entry(env, "emitManifest", |env| {
                let text = read_string(env, &manifest_json)?;
                let bytes = wal::emit_manifest(&text)?;
                let array = env.byte_array_from_slice(&bytes)?;
                Ok(array.as_raw() as jbyteArray)
            })
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `NativeWal.verifyRecordNative(ByteArray): String` — **experimental**.
///
/// One record frame's CRC and structure; see [`wal::verify_record`].
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_phonedsh_wire_NativeWal_verifyRecordNative<'frame>(
    mut unowned_env: EnvUnowned<'frame>,
    _this: JObject<'frame>,
    record: JByteArray<'frame>,
) -> jstring {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jstring> {
            run_entry(env, "verifyRecord", |env| {
                let bytes = read_bytes(env, &record)?;
                let json = wal::verify_record(&bytes);
                let text = env.new_string(json)?;
                Ok(text.as_raw() as jstring)
            })
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `NativeWal.recordsNative(ByteArray): String` — **experimental**.
///
/// One whole segment's complete, CRC-verified records, decoded to a JSON array;
/// see [`wal::records`].
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_phonedsh_wire_NativeWal_recordsNative<'frame>(
    mut unowned_env: EnvUnowned<'frame>,
    _this: JObject<'frame>,
    segment: JByteArray<'frame>,
) -> jstring {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jstring> {
            run_entry(env, "records", |env| {
                let bytes = read_bytes(env, &segment)?;
                let json = wal::records(&bytes)?;
                let text = env.new_string(json)?;
                Ok(text.as_raw() as jstring)
            })
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `NativeWal.decodeRecordNative(ByteArray): String` — **experimental**.
///
/// Exactly one record frame's decoded body; see [`wal::decode_record`].
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_phonedsh_wire_NativeWal_decodeRecordNative<'frame>(
    mut unowned_env: EnvUnowned<'frame>,
    _this: JObject<'frame>,
    record: JByteArray<'frame>,
) -> jstring {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jstring> {
            run_entry(env, "decodeRecord", |env| {
                let bytes = read_bytes(env, &record)?;
                let json = wal::decode_record(&bytes)?;
                let text = env.new_string(json)?;
                Ok(text.as_raw() as jstring)
            })
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `NativeWal.appendedReplayNative(Long, Long, ByteArray, ByteArray?): String`
/// — **experimental**.
///
/// The D9 decision of `wal.md` §6.2; see [`wal::appended_replay`]. A null
/// `existing_at_offset` means the materialized path is absent, is a directory
/// or is not a regular file, which is a base mismatch (`resync`).
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_phonedsh_wire_NativeWal_appendedReplayNative<'frame>(
    mut unowned_env: EnvUnowned<'frame>,
    _this: JObject<'frame>,
    current_size: jlong,
    append_from: jlong,
    data: JByteArray<'frame>,
    existing_at_offset: JByteArray<'frame>,
) -> jstring {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jstring> {
            run_entry(env, "appendedReplay", |env| {
                let current_size = non_negative(current_size, "currentSize")?;
                let append_from = non_negative(append_from, "appendFrom")?;
                let data = read_bytes(env, &data)?;
                let existing = if existing_at_offset.as_raw().is_null() {
                    None
                } else {
                    Some(read_bytes(env, &existing_at_offset)?)
                };
                let json =
                    wal::appended_replay(current_size, append_from, &data, existing.as_deref());
                let text = env.new_string(json)?;
                Ok(text.as_raw() as jstring)
            })
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `NativeWal.panicForTestNative(String): String` — test-only panic hook.
///
/// Always panics. It exists so the Kotlin suite can prove the panic boundary of
/// this class too; the WAL entry points otherwise return errors, never panic.
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_phonedsh_wire_NativeWal_panicForTestNative<'frame>(
    mut unowned_env: EnvUnowned<'frame>,
    _this: JObject<'frame>,
    message: JString<'frame>,
) -> jstring {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jstring> {
            run_entry(env, "walPanicForTest", |env| -> Result<jstring, Failure> {
                let message = read_string(env, &message)?;
                panic!("intentional WAL panic hook: {message}");
            })
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `NativeShell.capsJsonNative(Boolean): String`
///
/// The capability JSON of the linked accelerator registry. `hasToolBridge` is
/// honoured for diagnosis, but the run path of this crate never supplies a host
/// bridge, so the Kotlin binding always asks for `false`.
///
/// # Panics
/// Never: a panic is caught by [`run_entry`] and becomes a Java exception.
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_phonedsh_shell_NativeShell_capsJsonNative<'frame>(
    mut unowned_env: EnvUnowned<'frame>,
    _this: JObject<'frame>,
    has_tool_bridge: jboolean,
) -> jstring {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jstring> {
            run_entry(env, "shellCapsJson", |env| {
                let json = shell::caps_json(has_tool_bridge)?;
                let out = env.new_string(json)?;
                Ok(out.as_raw() as jstring)
            })
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `NativeShell.runNative(Array<String>, String, Array<String>, Array<String>,
/// Array<String>, Array<String>, Long, Long, Long, Long): ByteArray`
///
/// The first array is `argv` (`argv[0]` selects the accelerator), the second the
/// guest `cwd`; the following two pairs are the environment names/values and the
/// mount guests/hosts; the four longs are the timeout and the three output/file
/// limits. The returned frame is described in [`shell`]. The call blocks until
/// the FFI worker has finished and joined.
///
/// # Panics
/// Never: a panic is caught by [`run_entry`] and becomes a Java exception.
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_phonedsh_shell_NativeShell_runNative<'frame>(
    mut unowned_env: EnvUnowned<'frame>,
    _this: JObject<'frame>,
    argv: JObjectArray<'frame, JString<'frame>>,
    cwd: JString<'frame>,
    env_names: JObjectArray<'frame, JString<'frame>>,
    env_values: JObjectArray<'frame, JString<'frame>>,
    mount_guests: JObjectArray<'frame, JString<'frame>>,
    mount_hosts: JObjectArray<'frame, JString<'frame>>,
    timeout_ms: jlong,
    max_output_bytes: jlong,
    max_files: jlong,
    max_file_bytes: jlong,
) -> jbyteArray {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jbyteArray> {
            run_entry(env, "shellRun", |env| {
                let argv = read_strings(env, &argv)?;
                let cwd = read_string(env, &cwd)?;
                let env_names = read_strings(env, &env_names)?;
                let env_values = read_strings(env, &env_values)?;
                let mount_guests = read_strings(env, &mount_guests)?;
                let mount_hosts = read_strings(env, &mount_hosts)?;
                let environment = shell_pairs(env_names, env_values, "the environment")?;
                let mounts = shell_pairs(mount_guests, mount_hosts, "the mounts")?;
                let request = shell::ShellRequest {
                    argv: &argv,
                    cwd: &cwd,
                    env: &environment,
                    mounts: &mounts,
                    limits: shell::ShellLimits {
                        timeout_ms: shell_u64(timeout_ms, "timeoutMs")?,
                        max_output_bytes: shell_usize(max_output_bytes, "maxOutputBytes")?,
                        max_files: shell_usize(max_files, "maxFiles")?,
                        max_file_bytes: shell_u64(max_file_bytes, "maxFileBytes")?,
                    },
                };
                let result = shell::run(&request)?;
                let frame = shell::encode_frame(&result)?;
                let bytes = env.byte_array_from_slice(&frame)?;
                Ok(bytes.as_raw() as jbyteArray)
            })
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `NativeShell.jaqReadsStdinNative(Array<String>): Boolean`
///
/// Whether a `jaq` argv would read the process's standard input, i.e. whether
/// the exec adapter must refuse it (the C ABI has no stdin channel). The argv is
/// parsed by `pdsh-jaq` itself; see [`shell::jaq_reads_stdin`].
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_phonedsh_shell_NativeShell_jaqReadsStdinNative<'frame>(
    mut unowned_env: EnvUnowned<'frame>,
    _this: JObject<'frame>,
    argv: JObjectArray<'frame, JString<'frame>>,
) -> jboolean {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jboolean> {
            run_entry(env, "jaqReadsStdin", |env| {
                let argv = read_strings(env, &argv)?;
                Ok(shell::jaq_reads_stdin(&argv))
            })
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

/// `NativeShell.panicForTestNative(String): String` — test-only panic hook.
///
/// Always panics. It proves on the Android side that a Rust panic arrives as a
/// Java exception with the `PDSH_JNI_PANIC` prefix, not as an abort or a silent
/// default value.
#[unsafe(no_mangle)]
pub extern "system" fn Java_com_phonedsh_shell_NativeShell_panicForTestNative<'frame>(
    mut unowned_env: EnvUnowned<'frame>,
    _this: JObject<'frame>,
    message: JString<'frame>,
) -> jstring {
    unowned_env
        .with_env(|env| -> jni::errors::Result<jstring> {
            run_entry(
                env,
                "shellPanicForTest",
                |env| -> Result<jstring, Failure> {
                    let message = read_string(env, &message)?;
                    panic!("intentional shell panic hook: {message}");
                },
            )
        })
        .resolve::<jni::errors::ThrowRuntimeExAndDefault>()
}

#[cfg(test)]
mod tests {
    use super::{catch_panic, panic_message, RUNTIME_EXCEPTION_CLASS};

    #[test]
    fn panic_message_reads_str_and_string_payloads() {
        let payload: Box<dyn std::any::Any + Send> = Box::new("static text");
        assert_eq!(panic_message(payload.as_ref()), "static text");
        let payload: Box<dyn std::any::Any + Send> = Box::new(String::from("owned text"));
        assert_eq!(panic_message(payload.as_ref()), "owned text");
        let payload: Box<dyn std::any::Any + Send> = Box::new(42u8);
        assert_eq!(panic_message(payload.as_ref()), "non-string panic payload");
    }

    #[test]
    fn catch_panic_never_lets_a_panic_escape() {
        let caught = catch_panic("unitProbe", || -> i32 { panic!("unit boom") });
        assert_eq!(
            caught.expect_err("a panic must be caught"),
            "PDSH_JNI_PANIC: unitProbe: unit boom"
        );
        assert_eq!(RUNTIME_EXCEPTION_CLASS, "java/lang/RuntimeException");
    }
}
