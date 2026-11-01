// SPDX-License-Identifier: MIT
//! 16 KB page alignment for the Android JNI product (plan P2a, DSV F5).
//!
//! Android 15+ can run on a 16 KB-page kernel. A `.so` whose `PT_LOAD`
//! segments are aligned below 16 KB is rejected there with
//! `UnsatisfiedLinkError`, and the defect is invisible on a 4 KB emulator. The
//! NDK's default linker page size is not a contract we own (it changed once
//! between NDK releases), so the flag is pinned here.
//!
//! Why a build script and not `shell/.cargo/config.toml`
//! ------------------------------------------------------
//! A workspace-level Cargo config applies to every target the workspace can
//! build, so a link flag there is one `cfg` mistake away from the host dylib
//! (whose `ld` rejects `-z max-page-size`) or the wasm products. It is also
//! hashed as a whole by `plugins/wasi-toolbox/jq/source-fingerprint.ts`
//! (deliberately: a Cargo config *can* change any artifact), so adding it
//! invalidates the jq wasi artifact that another lane built, even though these
//! target-scoped flags cannot affect a wasm link. A build script scopes the flag
//! to exactly this crate and exactly the Android targets, and it cannot be
//! overridden by a `RUSTFLAGS` environment variable the way config rustflags
//! can.
//!
//! The value is machine-checked in two layers, both in
//! `android/tools/structure_check.py`:
//!   * `android-16k-link-arg` — this file still carries the flag **and** the
//!     `CARGO_CFG_TARGET_OS == "android"` gate;
//!   * `android-16k-artifact` — every `PT_LOAD` of the built `.so` has
//!     `p_align >= 0x4000` (`android/tools/check-native-alignment.py`).

fn main() {
    // Host (macOS/iOS) and wasm links must never see this flag: `ld64` rejects
    // `-z max-page-size`, and the wasm targets do not produce an ELF at all.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("android") {
        return;
    }
    // `cargo:rustc-link-arg` reaches the final link of this cdylib, which is
    // exactly the libpdsh_jni.so the APK packages.
    println!("cargo:rustc-link-arg=-Wl,-z,max-page-size=16384");
    println!("cargo:rerun-if-changed=build.rs");
}
