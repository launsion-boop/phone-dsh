// SPDX-License-Identifier: MIT
//! Capability object advertised to the host.
//!
//! The JSON shape is fixed by the work-package contract:
//!
//! ```json
//! {"accelerators":["rg"],"version":"0.1.0",
//!  "limits":{"timeout":30000,"max_output_bytes":1048576,
//!            "max_files":10000,"max_file_bytes":15728640}}
//! ```
//!
//! Only read-only accelerators are listed. Test commands (`echo`, `pdsh-caps`)
//! are registered but never advertised, so the host never forwards them.

use std::fmt::Write as _;

use crate::limits::Limits;

/// Advertised accelerator names plus the pdsh-shell version.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Caps {
    /// Read-only accelerator names, sorted and unique.
    pub accelerators: Vec<String>,
    /// pdsh-shell version string.
    pub version: String,
}

impl Caps {
    /// Build a capability object; names are sorted and deduplicated.
    pub fn new<I, S>(accelerators: I, version: impl Into<String>) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let mut accelerators: Vec<String> = accelerators.into_iter().map(Into::into).collect();
        accelerators.sort();
        accelerators.dedup();
        Caps {
            accelerators,
            version: version.into(),
        }
    }

    /// An empty accelerator set.
    pub fn empty(version: impl Into<String>) -> Self {
        Caps::new(std::iter::empty::<String>(), version)
    }

    /// Render the capabilities JSON with the limits of this invocation.
    pub fn json(&self, limits: &Limits) -> String {
        let mut out = String::with_capacity(160);
        out.push_str("{\"accelerators\":[");
        for (index, accelerator) in self.accelerators.iter().enumerate() {
            if index > 0 {
                out.push(',');
            }
            out.push('"');
            escape_json(accelerator, &mut out);
            out.push('"');
        }
        out.push_str("],\"version\":\"");
        escape_json(&self.version, &mut out);
        out.push_str("\",\"limits\":");
        out.push_str(&limits.to_json());
        out.push('}');
        out
    }
}

fn escape_json(text: &str, out: &mut String) {
    for character in text.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            control if (control as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", control as u32);
            }
            other => out.push(other),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn caps_json_is_stable_sorted_and_escaped() {
        let limits = Limits::new(Duration::from_millis(250), 64, 3, 4096);
        let caps = Caps::new(["rg", "jaq", "rg"], "0.1.0");
        assert_eq!(
            caps.json(&limits),
            "{\"accelerators\":[\"jaq\",\"rg\"],\"version\":\"0.1.0\",\
             \"limits\":{\"timeout\":250,\"max_output_bytes\":64,\"max_files\":3,\
             \"max_file_bytes\":4096}}"
        );
    }

    #[test]
    fn caps_json_escapes_quotes_and_controls() {
        let caps = Caps::new(["a\"b"], "1\\2");
        let json = caps.json(&Limits::default());
        assert!(json.contains("a\\\"b"));
        assert!(json.contains("1\\\\2"));
    }

    #[test]
    fn empty_caps_has_an_empty_accelerator_array() {
        let caps = Caps::empty("x");
        let json = caps.json(&Limits::default());
        assert!(json.starts_with("{\"accelerators\":[],"));
    }
}
