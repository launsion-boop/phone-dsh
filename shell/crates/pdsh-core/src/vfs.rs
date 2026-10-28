// SPDX-License-Identifier: MIT
//! The read-only virtual filesystem interface and its host implementation.
//!
//! Accelerators only ever read. [`Vfs`] therefore exposes no write, create,
//! remove, rename or chmod operation. Guest paths are absolute (`/dsh/...`);
//! relative paths are resolved against [`crate::ctx::Ctx::cwd`] before they
//! reach the VFS, and every path is confined by the [`MountTable`].

use std::fs::{self, File};
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use crate::error::VfsError;
use crate::mount::MountTable;

/// The kind of a directory entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileKind {
    /// A regular file.
    File,
    /// A directory.
    Dir,
    /// Anything else (socket, FIFO, block device, ...).
    Other,
}

/// Metadata of one guest path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Metadata {
    /// Entry kind.
    pub kind: FileKind,
    /// Size in bytes (zero for directories).
    pub len: u64,
    /// The host file is not writable.
    pub readonly: bool,
    /// Modification time as Unix epoch milliseconds, when available.
    pub modified_ms: Option<u64>,
}

impl Metadata {
    /// True for a regular file.
    pub fn is_file(&self) -> bool {
        self.kind == FileKind::File
    }

    /// True for a directory.
    pub fn is_dir(&self) -> bool {
        self.kind == FileKind::Dir
    }
}

/// One directory entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirEntry {
    /// Base name of the entry.
    pub name: String,
    /// Entry kind.
    pub kind: FileKind,
}

/// Read-only file access used by accelerators.
///
/// Implementations must be safe to share across threads (`Send + Sync`); the
/// FFI runs one command per worker thread but a host may reuse a VFS.
pub trait Vfs: Send + Sync {
    /// Open a guest path for reading.
    fn open_read(&self, path: &Path) -> Result<Box<dyn Read + Send>, VfsError>;
    /// Metadata of a guest path.
    fn metadata(&self, path: &Path) -> Result<Metadata, VfsError>;
    /// Directory entries of a guest path, sorted by name.
    fn read_dir(&self, path: &Path) -> Result<Vec<DirEntry>, VfsError>;
    /// Canonical guest path: `..`, `.` and symlinks resolved, still under a mount.
    fn canonicalize(&self, path: &Path) -> Result<PathBuf, VfsError>;
}

/// A [`Vfs`] over one [`MountTable`].
#[derive(Debug, Clone)]
pub struct StdFsVfs {
    mounts: MountTable,
}

impl StdFsVfs {
    /// Create a VFS from a validated mount table.
    pub fn new(mounts: MountTable) -> Self {
        StdFsVfs { mounts }
    }

    /// Create a VFS with the two standard mounts under one host root.
    pub fn for_root(root: impl AsRef<Path>) -> Result<Self, VfsError> {
        MountTable::for_root(root)
            .map(StdFsVfs::new)
            .map_err(VfsError::Sandbox)
    }

    /// The mount table behind this VFS.
    pub fn mounts(&self) -> &MountTable {
        &self.mounts
    }

    fn host(&self, path: &Path) -> Result<PathBuf, VfsError> {
        self.mounts.resolve(path).map_err(VfsError::Sandbox)
    }
}

impl Vfs for StdFsVfs {
    fn open_read(&self, path: &Path) -> Result<Box<dyn Read + Send>, VfsError> {
        let host = self.host(path)?;
        let file = File::open(&host).map_err(|error| io_error(path, error))?;
        let metadata = file.metadata().map_err(|error| io_error(path, error))?;
        if !metadata.is_file() {
            return Err(VfsError::NotAFile {
                path: path.display().to_string(),
            });
        }
        Ok(Box::new(file))
    }

    fn metadata(&self, path: &Path) -> Result<Metadata, VfsError> {
        let host = self.host(path)?;
        let metadata = fs::metadata(&host).map_err(|error| io_error(path, error))?;
        Ok(metadata_from(&metadata))
    }

    fn read_dir(&self, path: &Path) -> Result<Vec<DirEntry>, VfsError> {
        let host = self.host(path)?;
        let metadata = fs::metadata(&host).map_err(|error| io_error(path, error))?;
        if !metadata.is_dir() {
            return Err(VfsError::NotADirectory {
                path: path.display().to_string(),
            });
        }
        let mut entries = Vec::new();
        let iter = fs::read_dir(&host).map_err(|error| io_error(path, error))?;
        for entry in iter {
            let entry = entry.map_err(|error| io_error(path, error))?;
            let file_type = entry.file_type().map_err(|error| io_error(path, error))?;
            entries.push(DirEntry {
                name: entry.file_name().to_string_lossy().into_owned(),
                kind: if file_type.is_file() {
                    FileKind::File
                } else if file_type.is_dir() {
                    FileKind::Dir
                } else {
                    FileKind::Other
                },
            });
        }
        entries.sort_by(|left, right| left.name.cmp(&right.name));
        Ok(entries)
    }

    fn canonicalize(&self, path: &Path) -> Result<PathBuf, VfsError> {
        self.mounts
            .canonical_guest(path)
            .map_err(VfsError::Sandbox)
    }
}

fn metadata_from(metadata: &fs::Metadata) -> Metadata {
    let kind = if metadata.is_file() {
        FileKind::File
    } else if metadata.is_dir() {
        FileKind::Dir
    } else {
        FileKind::Other
    };
    let modified_ms = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| u64::try_from(duration.as_millis()).unwrap_or(u64::MAX));
    Metadata {
        kind,
        len: metadata.len(),
        readonly: metadata.permissions().readonly(),
        modified_ms,
    }
}

fn io_error(path: &Path, error: io::Error) -> VfsError {
    if error.kind() == io::ErrorKind::NotFound {
        VfsError::NotFound {
            path: path.display().to_string(),
        }
    } else {
        VfsError::Io {
            path: path.display().to_string(),
            error,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mount::tests::TestTree;
    use std::io::Read;

    #[test]
    fn reads_a_file_and_reports_metadata() {
        let tree = TestTree::new("vfs-read");
        fs::write(tree.workspace().join("a.txt"), b"hello").unwrap();
        let vfs = StdFsVfs::for_root(&tree.root).unwrap();
        let mut file = vfs.open_read(Path::new("/dsh/workspace/a.txt")).unwrap();
        let mut text = String::new();
        file.read_to_string(&mut text).unwrap();
        assert_eq!(text, "hello");
        let metadata = vfs.metadata(Path::new("/dsh/workspace/a.txt")).unwrap();
        assert_eq!(metadata.kind, FileKind::File);
        assert_eq!(metadata.len, 5);
    }

    #[test]
    fn lists_a_directory_sorted_by_name() {
        let tree = TestTree::new("vfs-dir");
        fs::write(tree.home().join("b.txt"), b"b").unwrap();
        fs::write(tree.home().join("a.txt"), b"a").unwrap();
        fs::create_dir(tree.home().join("sub")).unwrap();
        let vfs = StdFsVfs::for_root(&tree.root).unwrap();
        let entries = vfs.read_dir(Path::new("/dsh/home")).unwrap();
        assert_eq!(
            entries
                .iter()
                .map(|entry| (entry.name.as_str(), entry.kind))
                .collect::<Vec<_>>(),
            vec![
                ("a.txt", FileKind::File),
                ("b.txt", FileKind::File),
                ("sub", FileKind::Dir)
            ]
        );
    }

    #[test]
    fn missing_paths_are_not_found() {
        let tree = TestTree::new("vfs-missing");
        let vfs = StdFsVfs::for_root(&tree.root).unwrap();
        assert!(matches!(
            vfs.metadata(Path::new("/dsh/workspace/nope")),
            Err(VfsError::NotFound { .. })
        ));
        assert!(matches!(
            vfs.open_read(Path::new("/dsh/workspace/nope")),
            Err(VfsError::NotFound { .. })
        ));
    }

    #[test]
    fn directories_are_not_files_and_files_are_not_directories() {
        let tree = TestTree::new("vfs-kinds");
        fs::write(tree.workspace().join("a.txt"), b"a").unwrap();
        let vfs = StdFsVfs::for_root(&tree.root).unwrap();
        assert!(matches!(
            vfs.open_read(Path::new("/dsh/workspace")),
            Err(VfsError::NotAFile { .. })
        ));
        assert!(matches!(
            vfs.read_dir(Path::new("/dsh/workspace/a.txt")),
            Err(VfsError::NotADirectory { .. })
        ));
    }

    #[test]
    fn the_vfs_surfaces_sandbox_rejections() {
        let tree = TestTree::new("vfs-sandbox");
        let vfs = StdFsVfs::for_root(&tree.root).unwrap();
        assert!(matches!(
            vfs.metadata(Path::new("/etc/passwd")),
            Err(VfsError::Sandbox(_))
        ));
    }
}
