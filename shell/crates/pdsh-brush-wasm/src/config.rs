// SPDX-License-Identifier: MIT
//! Shell configuration: guest paths, environment and the WASI fs-only policy.
//!
//! The spike deliberately exposes a single capability class to the guest: the
//! WASI filesystem. There is no network import, no process spawn import and no
//! ambient environment inheritance. The only non-WASI imports are the `xl`
//! dispatch and output hooks the Worker host provides.

use std::path::{Path, PathBuf};

/// Guest mount points the shell is allowed to see.
pub const WORKSPACE_GUEST: &str = "/dsh/workspace";
/// Guest home directory.
pub const HOME_GUEST: &str = "/dsh/home";
/// Guest scratch directory used by the pipeline workaround.
pub const TMP_GUEST: &str = "/dsh/tmp";

/// Configuration of one brush shell instance.
#[derive(Clone, Debug)]
pub struct ShellConfig {
    /// Guest working directory (normally [`WORKSPACE_GUEST`]).
    pub working_dir: PathBuf,
    /// Exported environment variables, in addition to the fixed batch below.
    pub env: Vec<(String, String)>,
}

impl Default for ShellConfig {
    fn default() -> Self {
        Self {
            working_dir: PathBuf::from(WORKSPACE_GUEST),
            env: Vec::new(),
        }
    }
}

impl ShellConfig {
    /// The fixed environment of the Worker shell.
    ///
    /// `TERM=dumb NO_COLOR=1 LANG=C.UTF-8` follows the pdsh-shell output
    /// discipline; `PATH` is fixed because command resolution is the dispatch
    /// hook's job, not the host filesystem's.
    #[must_use]
    pub fn base_env() -> Vec<(String, String)> {
        vec![
            ("HOME".to_string(), HOME_GUEST.to_string()),
            ("PWD".to_string(), WORKSPACE_GUEST.to_string()),
            ("PATH".to_string(), "/usr/local/bin:/usr/bin:/bin".to_string()),
            ("LANG".to_string(), "C.UTF-8".to_string()),
            ("LC_ALL".to_string(), "C.UTF-8".to_string()),
            ("TERM".to_string(), "dumb".to_string()),
            ("NO_COLOR".to_string(), "1".to_string()),
            ("SHELL".to_string(), "/bin/bash".to_string()),
        ]
    }

    /// The full environment: [`Self::base_env`] plus the caller's overrides.
    #[must_use]
    pub fn environment(&self) -> Vec<(String, String)> {
        let mut env = Self::base_env();
        for (name, value) in &self.env {
            if let Some(entry) = env.iter_mut().find(|(key, _)| key == name) {
                entry.1.clone_from(value);
            } else {
                env.push((name.clone(), value.clone()));
            }
        }
        env
    }

    /// True when `path` is inside one of the three guest mounts.
    #[must_use]
    pub fn is_guest_path(path: &Path) -> bool {
        [WORKSPACE_GUEST, HOME_GUEST, TMP_GUEST]
            .iter()
            .any(|mount| path == Path::new(mount) || path.starts_with(mount))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base_env_is_fixed() {
        let env = ShellConfig::base_env();
        assert!(env.contains(&("TERM".to_string(), "dumb".to_string())));
        assert!(env.contains(&("NO_COLOR".to_string(), "1".to_string())));
        assert!(env.contains(&("LANG".to_string(), "C.UTF-8".to_string())));
    }

    #[test]
    fn caller_overrides_replace_base_entries() {
        let config = ShellConfig {
            working_dir: PathBuf::from(WORKSPACE_GUEST),
            env: vec![("TERM".to_string(), "xterm".to_string())],
        };
        let env = config.environment();
        assert_eq!(
            env.iter().filter(|(name, _)| name == "TERM").count(),
            1,
            "TERM must appear once"
        );
        assert!(env.contains(&("TERM".to_string(), "xterm".to_string())));
    }

    #[test]
    fn guest_paths_are_bounded() {
        assert!(ShellConfig::is_guest_path(Path::new("/dsh/workspace")));
        assert!(ShellConfig::is_guest_path(Path::new("/dsh/home/notes.txt")));
        assert!(!ShellConfig::is_guest_path(Path::new("/dsh/workspacex")));
        assert!(!ShellConfig::is_guest_path(Path::new("/etc/passwd")));
    }
}
