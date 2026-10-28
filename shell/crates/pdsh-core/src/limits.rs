// SPDX-License-Identifier: MIT
//! Execution limits and the capability JSON that advertises them.

use std::time::Duration;

/// Default deadline for one accelerator run (milliseconds).
pub const DEFAULT_TIMEOUT_MS: u64 = 30_000;
/// Default captured bytes per output stream.
pub const DEFAULT_MAX_OUTPUT_BYTES: usize = 1_048_576;
/// Default number of files a single command may open.
pub const DEFAULT_MAX_FILES: usize = 10_000;
/// Default size of one file a command may read (the DSH single-file budget).
pub const DEFAULT_MAX_FILE_BYTES: u64 = 15 * 1024 * 1024;

/// Resource limits of one command run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Limits {
    /// Wall-clock deadline. A zero duration means "no deadline".
    pub timeout: Duration,
    /// Captured bytes per output stream (stdout and stderr are counted separately).
    pub max_output_bytes: usize,
    /// Maximum number of files one command may open.
    pub max_files: usize,
    /// Maximum size in bytes of one file a command may read.
    pub max_file_bytes: u64,
}

impl Default for Limits {
    fn default() -> Self {
        Limits {
            timeout: Duration::from_millis(DEFAULT_TIMEOUT_MS),
            max_output_bytes: DEFAULT_MAX_OUTPUT_BYTES,
            max_files: DEFAULT_MAX_FILES,
            max_file_bytes: DEFAULT_MAX_FILE_BYTES,
        }
    }
}

impl Limits {
    /// Build limits with all four fields explicit.
    pub fn new(
        timeout: Duration,
        max_output_bytes: usize,
        max_files: usize,
        max_file_bytes: u64,
    ) -> Self {
        Limits {
            timeout,
            max_output_bytes,
            max_files,
            max_file_bytes,
        }
    }

    /// Build limits with a timeout expressed in milliseconds (`0` = none).
    pub fn with_timeout_ms(mut self, milliseconds: u64) -> Self {
        self.timeout = Duration::from_millis(milliseconds);
        self
    }

    /// The timeout in whole milliseconds, rounded down.
    pub fn timeout_ms(&self) -> u64 {
        u64::try_from(self.timeout.as_millis()).unwrap_or(u64::MAX)
    }

    /// Render the `limits` object of the capabilities JSON.
    ///
    /// The field names are fixed by the work-package contract:
    /// `timeout` (milliseconds), `max_output_bytes`, `max_files`,
    /// `max_file_bytes`.
    pub fn to_json(&self) -> String {
        format!(
            "{{\"timeout\":{},\"max_output_bytes\":{},\"max_files\":{},\"max_file_bytes\":{}}}",
            self.timeout_ms(),
            self.max_output_bytes,
            self.max_files,
            self.max_file_bytes
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_limits_match_the_documented_budgets() {
        let limits = Limits::default();
        assert_eq!(limits.timeout_ms(), 30_000);
        assert_eq!(limits.max_output_bytes, 1_048_576);
        assert_eq!(limits.max_files, 10_000);
        assert_eq!(limits.max_file_bytes, 15 * 1024 * 1024);
    }

    #[test]
    fn limits_json_uses_the_contract_field_names() {
        let limits = Limits::new(Duration::from_millis(250), 64, 3, 4096);
        assert_eq!(
            limits.to_json(),
            "{\"timeout\":250,\"max_output_bytes\":64,\"max_files\":3,\"max_file_bytes\":4096}"
        );
        assert_eq!(
            limits.clone().with_timeout_ms(0).timeout_ms(),
            0,
            "zero means no deadline"
        );
    }
}
