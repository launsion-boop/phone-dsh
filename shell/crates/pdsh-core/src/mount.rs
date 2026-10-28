// SPDX-License-Identifier: MIT
//! Guest-to-host path mapping with a hard sandbox.
//!
//! Guest paths are absolute under `/dsh` (BRIEF-COMMON): `/dsh/workspace` and
//! `/dsh/home` are mapped onto host directories. The table rejects
//!
//! - relative guest paths at this layer (the caller resolves them against its
//!   cwd first),
//! - `..` components that would walk above `/`,
//! - absolute guest paths outside every mount,
//! - NUL bytes, and
//! - symlinks whose host target leaves the mount, checked with
//!   [`std::fs::canonicalize`].
//!
//! The sandbox is lexical plus `canonicalize`, so a path that does not exist
//! is still mapped for a later `NotFound`, while every existing ancestor is
//! checked. A race between the check and the subsequent open is out of scope
//! for read-only accelerators: they only read, and the host workspace is
//! written by the WAL applier, not by another process.

use std::path::{Component, Path, PathBuf};

use crate::error::SandboxError;

/// Guest root for phone-DSH VFS paths.
pub const GUEST_ROOT: &str = "/dsh";
/// Standard guest path of the workspace mount.
pub const WORKSPACE_GUEST: &str = "/dsh/workspace";
/// Standard guest path of the home mount.
pub const HOME_GUEST: &str = "/dsh/home";

/// One guest-to-host mapping, before validation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MountSpec {
    /// Absolute guest path, for example `/dsh/workspace`.
    pub guest: PathBuf,
    /// Existing host directory.
    pub host: PathBuf,
}

impl MountSpec {
    /// Create a mapping.
    pub fn new(guest: impl Into<PathBuf>, host: impl Into<PathBuf>) -> Self {
        MountSpec {
            guest: guest.into(),
            host: host.into(),
        }
    }
}

#[derive(Debug, Clone)]
struct Mount {
    guest: PathBuf,
    host: PathBuf,
}

/// A validated set of guest mounts.
#[derive(Debug, Clone)]
pub struct MountTable {
    /// Longest guest prefix first, so the first match is the most specific.
    mounts: Vec<Mount>,
}

impl MountTable {
    /// Validate and canonicalize a mount set.
    pub fn new(specs: impl IntoIterator<Item = MountSpec>) -> Result<Self, SandboxError> {
        let mut mounts = Vec::new();
        for spec in specs {
            let guest = normalize_guest_mount(&spec.guest)?;
            if mounts.iter().any(|mount: &Mount| mount.guest == guest) {
                return Err(SandboxError::InvalidMount {
                    guest: guest.display().to_string(),
                    reason: "duplicate guest path",
                });
            }
            let host = std::fs::canonicalize(&spec.host).map_err(|error| {
                SandboxError::HostRootUnavailable {
                    path: spec.host.display().to_string(),
                    reason: error.to_string(),
                }
            })?;
            if !host.is_dir() {
                return Err(SandboxError::HostRootUnavailable {
                    path: spec.host.display().to_string(),
                    reason: "not a directory".to_string(),
                });
            }
            mounts.push(Mount { guest, host });
        }
        if mounts.is_empty() {
            return Err(SandboxError::InvalidMount {
                guest: String::new(),
                reason: "at least one mount is required",
            });
        }
        mounts.sort_by(|left, right| {
            right
                .guest
                .components()
                .count()
                .cmp(&left.guest.components().count())
        });
        Ok(MountTable { mounts })
    }

    /// The two standard mounts: workspace and home under one host root.
    pub fn for_root(root: impl AsRef<Path>) -> Result<Self, SandboxError> {
        let root = root.as_ref();
        MountTable::standard(root.join("workspace"), root.join("home"))
    }

    /// The two standard mounts from explicit host directories.
    pub fn standard(
        workspace_host: impl Into<PathBuf>,
        home_host: impl Into<PathBuf>,
    ) -> Result<Self, SandboxError> {
        MountTable::new([
            MountSpec::new(WORKSPACE_GUEST, workspace_host),
            MountSpec::new(HOME_GUEST, home_host),
        ])
    }

    /// The validated mounts, guest and canonical host path.
    pub fn iter(&self) -> impl Iterator<Item = (&Path, &Path)> {
        self.mounts
            .iter()
            .map(|mount| (mount.guest.as_path(), mount.host.as_path()))
    }

    /// Resolve an absolute guest path to its canonical host path.
    pub fn resolve(&self, guest_path: &Path) -> Result<PathBuf, SandboxError> {
        if guest_path.as_os_str().is_empty() {
            return Err(SandboxError::EmptyPath);
        }
        if !guest_path.is_absolute() {
            return Err(SandboxError::NotAbsolute {
                path: guest_path.display().to_string(),
            });
        }
        self.resolve_at(Path::new("/"), guest_path)
    }

    /// Resolve `guest_path` relative to an absolute guest `cwd`.
    pub fn resolve_at(&self, cwd: &Path, guest_path: &Path) -> Result<PathBuf, SandboxError> {
        if guest_path.as_os_str().is_empty() {
            return Err(SandboxError::EmptyPath);
        }
        if has_nul(guest_path.as_os_str().as_encoded_bytes()) {
            return Err(SandboxError::NulByte {
                path: guest_path.display().to_string(),
            });
        }
        let absolute = if guest_path.is_absolute() {
            guest_path.to_path_buf()
        } else {
            if !cwd.is_absolute() {
                return Err(SandboxError::NotAbsolute {
                    path: cwd.display().to_string(),
                });
            }
            cwd.join(guest_path)
        };
        let normalized = normalize_absolute(&absolute)?;
        let (mount, relative) = self
            .match_mount(&normalized)
            .ok_or_else(|| SandboxError::OutsideMounts {
                path: normalized.display().to_string(),
            })?;
        let host_path = if relative.as_os_str().is_empty() {
            mount.host.clone()
        } else {
            mount.host.join(relative)
        };
        self.confine(mount, &host_path, &normalized)
    }

    /// Resolve a guest path and map the canonical host path back to a guest
    /// path. Used by `Vfs::canonicalize` so commands can report a stable path.
    pub fn canonical_guest(&self, guest_path: &Path) -> Result<PathBuf, SandboxError> {
        let host = self.resolve(guest_path)?;
        for mount in &self.mounts {
            if let Ok(relative) = host.strip_prefix(&mount.host) {
                if relative.as_os_str().is_empty() {
                    return Ok(mount.guest.clone());
                }
                return Ok(mount.guest.join(relative));
            }
        }
        Err(SandboxError::SymlinkEscape {
            path: guest_path.display().to_string(),
            resolved: host.display().to_string(),
        })
    }

    fn match_mount(&self, guest_path: &Path) -> Option<(&Mount, PathBuf)> {
        for mount in &self.mounts {
            if let Ok(relative) = guest_path.strip_prefix(&mount.guest) {
                return Some((mount, relative.to_path_buf()));
            }
        }
        None
    }

    fn confine(
        &self,
        mount: &Mount,
        host_path: &PathBuf,
        guest_path: &Path,
    ) -> Result<PathBuf, SandboxError> {
        let resolved = match std::fs::canonicalize(host_path) {
            Ok(resolved) => resolved,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                // The final path does not exist (a later open/stat will report
                // NotFound). Every existing ancestor must still be confined.
                let mut ancestor = host_path.parent();
                while let Some(candidate) = ancestor {
                    match std::fs::canonicalize(candidate) {
                        Ok(resolved) => {
                            if !resolved.starts_with(&mount.host) {
                                return Err(SandboxError::SymlinkEscape {
                                    path: guest_path.display().to_string(),
                                    resolved: resolved.display().to_string(),
                                });
                            }
                            return Ok(host_path.clone());
                        }
                        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                            ancestor = candidate.parent();
                        }
                        Err(error) => {
                            return Err(SandboxError::Io {
                                path: candidate.display().to_string(),
                                reason: error.to_string(),
                            })
                        }
                    }
                }
                return Err(SandboxError::HostRootUnavailable {
                    path: host_path.display().to_string(),
                    reason: "no existing ancestor".into(),
                });
            }
            Err(error) => {
                return Err(SandboxError::Io {
                    path: host_path.display().to_string(),
                    reason: error.to_string(),
                })
            }
        };
        if !resolved.starts_with(&mount.host) {
            return Err(SandboxError::SymlinkEscape {
                path: guest_path.display().to_string(),
                resolved: resolved.display().to_string(),
            });
        }
        Ok(resolved)
    }
}

fn normalize_guest_mount(guest: &Path) -> Result<PathBuf, SandboxError> {
    if !guest.is_absolute() {
        return Err(SandboxError::InvalidMount {
            guest: guest.display().to_string(),
            reason: "guest path must be absolute",
        });
    }
    if has_nul(guest.as_os_str().as_encoded_bytes()) {
        return Err(SandboxError::InvalidMount {
            guest: guest.display().to_string(),
            reason: "guest path contains a NUL byte",
        });
    }
    let normalized = normalize_absolute(guest).map_err(|_| SandboxError::InvalidMount {
        guest: guest.display().to_string(),
        reason: "guest path escapes with '..'",
    })?;
    if !normalized.starts_with(Path::new(GUEST_ROOT)) {
        return Err(SandboxError::InvalidMount {
            guest: guest.display().to_string(),
            reason: "guest path must be under /dsh",
        });
    }
    Ok(normalized)
}

fn normalize_absolute(path: &Path) -> Result<PathBuf, SandboxError> {
    let mut normalized = PathBuf::from("/");
    for component in path.components() {
        match component {
            Component::RootDir => normalized = PathBuf::from("/"),
            Component::CurDir => {}
            Component::ParentDir => {
                if !normalized.pop() {
                    return Err(SandboxError::ParentEscape {
                        path: path.display().to_string(),
                    });
                }
            }
            Component::Normal(part) => normalized.push(part),
            Component::Prefix(_) => {
                return Err(SandboxError::NotAbsolute {
                    path: path.display().to_string(),
                })
            }
        }
    }
    Ok(normalized)
}

fn has_nul(bytes: &[u8]) -> bool {
    bytes.contains(&0)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::fs;
    use std::sync::atomic::{AtomicU64, Ordering};

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    pub(crate) struct TestTree {
        pub root: PathBuf,
    }

    impl TestTree {
        pub(crate) fn new(tag: &str) -> Self {
            let unique = COUNTER.fetch_add(1, Ordering::SeqCst);
            let root = std::env::temp_dir().join(format!(
                "pdsh-core-{}-{}-{}",
                std::process::id(),
                unique,
                tag
            ));
            fs::create_dir_all(root.join("workspace")).expect("workspace");
            fs::create_dir_all(root.join("home")).expect("home");
            fs::create_dir_all(root.join("outside")).expect("outside");
            TestTree { root }
        }

        pub(crate) fn workspace(&self) -> PathBuf {
            self.root.join("workspace")
        }

        pub(crate) fn home(&self) -> PathBuf {
            self.root.join("home")
        }

        pub(crate) fn outside(&self) -> PathBuf {
            self.root.join("outside")
        }

        pub(crate) fn table(&self) -> MountTable {
            MountTable::for_root(&self.root).expect("mount table")
        }
    }

    impl Drop for TestTree {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn maps_workspace_and_home_paths() {
        let tree = TestTree::new("maps");
        let table = tree.table();
        assert_eq!(
            table.resolve(Path::new("/dsh/workspace/a.txt")).unwrap(),
            fs::canonicalize(tree.workspace()).unwrap().join("a.txt")
        );
        assert_eq!(
            table.resolve(Path::new("/dsh/home")).unwrap(),
            fs::canonicalize(tree.home()).unwrap()
        );
    }

    #[test]
    fn resolves_relative_paths_against_cwd() {
        let tree = TestTree::new("relative");
        let table = tree.table();
        let resolved = table
            .resolve_at(Path::new("/dsh/workspace/sub"), Path::new("../a.txt"))
            .unwrap();
        assert!(resolved.ends_with("workspace/a.txt"));
    }

    #[test]
    fn rejects_parent_escape_above_the_mount() {
        let tree = TestTree::new("parent");
        let table = tree.table();
        // Two levels up leaves the mount but stays at the guest root.
        let error = table
            .resolve(Path::new("/dsh/workspace/../../etc/passwd"))
            .unwrap_err();
        assert!(matches!(error, SandboxError::OutsideMounts { .. }));
        // Three levels up walks above the guest root and is rejected lexically.
        let error = table
            .resolve(Path::new("/dsh/workspace/../../../etc/passwd"))
            .unwrap_err();
        assert!(matches!(error, SandboxError::ParentEscape { .. }));
        let error = table
            .resolve_at(Path::new("/dsh/workspace"), Path::new("../../../etc/passwd"))
            .unwrap_err();
        assert!(matches!(error, SandboxError::ParentEscape { .. }));
    }

    #[test]
    fn rejects_absolute_paths_outside_the_mounts() {
        let tree = TestTree::new("absolute");
        let table = tree.table();
        let error = table.resolve(Path::new("/etc/passwd")).unwrap_err();
        assert!(matches!(error, SandboxError::OutsideMounts { .. }));
        let error = table.resolve(Path::new("/dsh/other/file")).unwrap_err();
        assert!(matches!(error, SandboxError::OutsideMounts { .. }));
    }

    #[test]
    fn rejects_nul_and_empty_paths() {
        let tree = TestTree::new("nul");
        let table = tree.table();
        assert!(matches!(
            table.resolve(Path::new("")).unwrap_err(),
            SandboxError::EmptyPath
        ));
        assert!(matches!(
            table.resolve(Path::new("/dsh/workspace/a\0b")).unwrap_err(),
            SandboxError::NulByte { .. }
        ));
    }

    #[test]
    fn normalizes_dot_segments_inside_a_mount() {
        let tree = TestTree::new("dots");
        fs::create_dir_all(tree.workspace().join("a")).unwrap();
        fs::create_dir_all(tree.workspace().join("b")).unwrap();
        let table = tree.table();
        assert_eq!(
            table.resolve(Path::new("/dsh/workspace/a/../b")).unwrap(),
            fs::canonicalize(tree.workspace()).unwrap().join("b")
        );
    }

    #[cfg(unix)]
    #[test]
    fn rejects_symlink_escape_with_an_existing_target() {
        use std::os::unix::fs::symlink;
        let tree = TestTree::new("symlink-out");
        fs::write(tree.outside().join("secret.txt"), b"secret").unwrap();
        symlink(tree.outside(), tree.workspace().join("link")).unwrap();
        let table = tree.table();
        let error = table
            .resolve(Path::new("/dsh/workspace/link/secret.txt"))
            .unwrap_err();
        assert!(matches!(error, SandboxError::SymlinkEscape { .. }));
    }

    #[cfg(unix)]
    #[test]
    fn rejects_symlink_escape_when_the_tail_does_not_exist() {
        use std::os::unix::fs::symlink;
        let tree = TestTree::new("symlink-tail");
        symlink(tree.outside(), tree.workspace().join("link")).unwrap();
        let table = tree.table();
        let error = table
            .resolve(Path::new("/dsh/workspace/link/missing.txt"))
            .unwrap_err();
        assert!(matches!(error, SandboxError::SymlinkEscape { .. }));
    }

    #[cfg(unix)]
    #[test]
    fn follows_symlinks_that_stay_inside_the_mount() {
        use std::os::unix::fs::symlink;
        let tree = TestTree::new("symlink-in");
        fs::create_dir_all(tree.workspace().join("real")).unwrap();
        fs::write(tree.workspace().join("real/ok.txt"), b"ok").unwrap();
        symlink("real", tree.workspace().join("alias")).unwrap();
        let table = tree.table();
        let resolved = table.resolve(Path::new("/dsh/workspace/alias/ok.txt")).unwrap();
        assert_eq!(
            resolved,
            fs::canonicalize(tree.workspace()).unwrap().join("real/ok.txt")
        );
        assert_eq!(
            table
                .canonical_guest(Path::new("/dsh/workspace/alias/ok.txt"))
                .unwrap(),
            PathBuf::from("/dsh/workspace/real/ok.txt")
        );
    }

    #[test]
    fn rejects_invalid_mount_descriptions() {
        let tree = TestTree::new("mounts");
        let error = MountTable::new([MountSpec::new("/tmp", tree.workspace())]).unwrap_err();
        assert!(matches!(error, SandboxError::InvalidMount { .. }));
        let error = MountTable::new([
            MountSpec::new("/dsh/workspace", tree.workspace()),
            MountSpec::new("/dsh/workspace", tree.home()),
        ])
        .unwrap_err();
        assert!(matches!(error, SandboxError::InvalidMount { .. }));
        let error = MountTable::new([MountSpec::new(
            "/dsh/workspace",
            tree.root.join("missing"),
        )])
        .unwrap_err();
        assert!(matches!(error, SandboxError::HostRootUnavailable { .. }));
        assert!(MountTable::new(std::iter::empty()).is_err());
    }
}
