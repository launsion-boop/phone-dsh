// SPDX-License-Identifier: MIT
//! Typed errors shared by the pdsh-shell core.
//!
//! The sandbox has its own type ([`SandboxError`]) so a caller can tell a path
//! rejection from an I/O failure without parsing messages; [`Error`] wraps it
//! for command execution.

use std::fmt;
use std::io;

/// A path that the [`crate::mount::MountTable`] refuses to map.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SandboxError {
    /// The empty path is never a valid guest path.
    EmptyPath,
    /// A relative cwd, or a mount guest path that is not absolute.
    NotAbsolute { path: String },
    /// The path is absolute but no guest mount covers it.
    OutsideMounts { path: String },
    /// A `..` component walked above the guest root.
    ParentEscape { path: String },
    /// A guest path contains a NUL byte.
    NulByte { path: String },
    /// Resolving the path through the host filesystem left the mount root.
    SymlinkEscape { path: String, resolved: String },
    /// A mount description is invalid (not absolute, not under `/dsh`, duplicate).
    InvalidMount { guest: String, reason: &'static str },
    /// The host directory of a mount is missing, not a directory, or unreadable.
    HostRootUnavailable { path: String, reason: String },
    /// The host filesystem failed while resolving a guest path.
    Io { path: String, reason: String },
}

impl fmt::Display for SandboxError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SandboxError::EmptyPath => write!(f, "empty path"),
            SandboxError::NotAbsolute { path } => {
                write!(f, "path is not absolute: {path}")
            }
            SandboxError::OutsideMounts { path } => {
                write!(f, "path is outside every guest mount: {path}")
            }
            SandboxError::ParentEscape { path } => {
                write!(f, "path escapes the guest root with '..': {path}")
            }
            SandboxError::NulByte { path } => write!(f, "path contains a NUL byte: {path:?}"),
            SandboxError::SymlinkEscape { path, resolved } => {
                write!(f, "path resolves outside its mount: {path} -> {resolved}")
            }
            SandboxError::InvalidMount { guest, reason } => {
                write!(f, "invalid mount {guest:?}: {reason}")
            }
            SandboxError::HostRootUnavailable { path, reason } => {
                write!(f, "mount host directory unavailable: {path}: {reason}")
            }
            SandboxError::Io { path, reason } => {
                write!(f, "cannot resolve host path for {path}: {reason}")
            }
        }
    }
}

impl std::error::Error for SandboxError {}

/// A filesystem operation failure below the sandbox.
#[derive(Debug)]
pub enum VfsError {
    /// The guest path does not exist.
    NotFound { path: String },
    /// The guest path is not a regular file.
    NotAFile { path: String },
    /// The guest path is not a directory.
    NotADirectory { path: String },
    /// The path was rejected by the mount table.
    Sandbox(SandboxError),
    /// The host filesystem reported an error.
    Io { path: String, error: io::Error },
}

impl fmt::Display for VfsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            VfsError::NotFound { path } => write!(f, "not found: {path}"),
            VfsError::NotAFile { path } => write!(f, "not a file: {path}"),
            VfsError::NotADirectory { path } => write!(f, "not a directory: {path}"),
            VfsError::Sandbox(error) => write!(f, "{error}"),
            VfsError::Io { path, error } => write!(f, "I/O error on {path}: {error}"),
        }
    }
}

impl std::error::Error for VfsError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            VfsError::Io { error, .. } => Some(error),
            VfsError::Sandbox(error) => Some(error),
            _ => None,
        }
    }
}

impl From<SandboxError> for VfsError {
    fn from(error: SandboxError) -> Self {
        VfsError::Sandbox(error)
    }
}

/// A command-execution failure.
#[derive(Debug)]
pub enum Error {
    /// The cancel token fired, or its deadline passed.
    Cancelled,
    /// A `Limits` field was exceeded.
    LimitExceeded {
        limit: &'static str,
        value: u64,
        max: u64,
    },
    /// A path was rejected by the sandbox.
    Sandbox(SandboxError),
    /// A filesystem read failed.
    Vfs(VfsError),
    /// The command name is not registered.
    UnknownCommand(String),
    /// The host bridge is absent or failed.
    Bridge(String),
    /// The request is malformed.
    InvalidRequest(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Cancelled => write!(f, "cancelled"),
            Error::LimitExceeded { limit, value, max } => {
                write!(f, "limit {limit} exceeded: {value} > {max}")
            }
            Error::Sandbox(error) => write!(f, "{error}"),
            Error::Vfs(error) => write!(f, "{error}"),
            Error::UnknownCommand(name) => write!(f, "unknown command: {name}"),
            Error::Bridge(message) => write!(f, "host bridge: {message}"),
            Error::InvalidRequest(message) => write!(f, "invalid request: {message}"),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Error::Sandbox(error) => Some(error),
            Error::Vfs(error) => Some(error),
            _ => None,
        }
    }
}

impl From<SandboxError> for Error {
    fn from(error: SandboxError) -> Self {
        Error::Sandbox(error)
    }
}

impl From<VfsError> for Error {
    fn from(error: VfsError) -> Self {
        Error::Vfs(error)
    }
}

impl From<io::Error> for Error {
    fn from(error: io::Error) -> Self {
        Error::Vfs(VfsError::Io {
            path: String::new(),
            error,
        })
    }
}

/// Result alias for command execution.
pub type Result<T> = std::result::Result<T, Error>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sandbox_errors_display_the_offending_path() {
        let error = SandboxError::OutsideMounts {
            path: "/etc/passwd".into(),
        };
        assert!(error.to_string().contains("/etc/passwd"));
        let error = SandboxError::SymlinkEscape {
            path: "/dsh/workspace/link".into(),
            resolved: "/private/tmp".into(),
        };
        assert!(error.to_string().contains("outside"));
    }

    #[test]
    fn vfs_errors_convert_into_command_errors() {
        let error: Error = VfsError::NotFound {
            path: "/dsh/workspace/missing".into(),
        }
        .into();
        assert!(matches!(error, Error::Vfs(VfsError::NotFound { .. })));
        let error: Error = SandboxError::EmptyPath.into();
        assert!(matches!(error, Error::Sandbox(SandboxError::EmptyPath)));
    }
}
