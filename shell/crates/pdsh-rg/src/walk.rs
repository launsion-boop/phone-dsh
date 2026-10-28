// SPDX-License-Identifier: MIT
//! The sandboxed directory walk behind `rg`.
//!
//! Every path is read through the [`pdsh_core::Vfs`] sandbox: directory listings
//! with [`Ctx::read_dir`], metadata with [`Ctx::metadata`] and ignore files with
//! [`Ctx::read_file`]. The walker reproduces ripgrep's filtering order:
//!
//! 1. hidden entries are skipped unless `--hidden` (an explicitly given root is
//!    always visited);
//! 2. `-t` / `-T` file-type filters apply to files;
//! 3. `-g` / `--glob` overrides apply, and a whitelisted file bypasses the
//!    ignore files below;
//! 4. `.rgignore`, `.ignore` and `.gitignore` files apply from the current
//!    directory upwards (`.gitignore` only inside a git repository), deepest
//!    first, and a negated glob prunes a directory.
//!
//! The semantics of steps 3 and 4 come from the `ignore` crate
//! ([`ignore::overrides::Override`] and [`ignore::gitignore::Gitignore`]), the
//! same implementation ripgrep uses. A negated glob does not prune a symlinked
//! directory that points back into the tree: directories are canonicalized and
//! visited at most once.

use std::collections::HashSet;
use std::path::{Path, PathBuf};

use globset::{GlobBuilder, GlobSet, GlobSetBuilder};
use ignore::gitignore::{Gitignore, GitignoreBuilder};
use ignore::overrides::{Override, OverrideBuilder};
use ignore::Match;
use pdsh_core::{Ctx, Error, FileKind, HOME_GUEST, WORKSPACE_GUEST};

use crate::args::Options;

/// File types understood by `-t` / `-T`.
///
/// This is a deliberately small built-in table: the accelerators are read-only
/// and the DSH tools do not pass `--type`, so only the common source types are
/// recognised. An unknown type is a usage error (exit 2), like ripgrep.
pub const TYPE_TABLE: &[(&str, &[&str])] = &[
    ("c", &["*.c", "*.h", "*.H"]),
    (
        "cpp",
        &["*.cc", "*.cpp", "*.cxx", "*.C", "*.hpp", "*.hh", "*.hxx", "*.H"],
    ),
    ("css", &["*.css", "*.scss"]),
    ("go", &["*.go"]),
    ("html", &["*.html", "*.htm", "*.ejs"]),
    ("java", &["*.java"]),
    ("js", &["*.js", "*.mjs", "*.cjs", "*.jsx", "*.vue"]),
    ("json", &["*.json"]),
    (
        "md",
        &["*.md", "*.markdown", "*.mdown", "*.mdwn", "*.mdx", "*.mkd"],
    ),
    ("py", &["*.py", "*.pyi"]),
    ("python", &["*.py", "*.pyi"]),
    ("ruby", &["*.rb", "*.rake", "*.gemspec"]),
    ("rust", &["*.rs"]),
    ("sh", &["*.sh", "*.bash", "*.zsh"]),
    ("swift", &["*.swift"]),
    ("toml", &["*.toml"]),
    ("ts", &["*.ts", "*.tsx", "*.mts", "*.cts"]),
    ("typescript", &["*.ts", "*.tsx", "*.mts", "*.cts"]),
    ("txt", &["*.txt"]),
    ("xml", &["*.xml", "*.xsd", "*.xsl", "*.xslt", "*.xhtml"]),
    ("yaml", &["*.yml", "*.yaml"]),
];

/// One regular file discovered by the walk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Found {
    /// Absolute guest path used for VFS access.
    pub guest: PathBuf,
    /// Path as ripgrep would print it (relative to the argument as written).
    pub display: String,
    /// Modification time in Unix epoch milliseconds, when available.
    pub modified_ms: Option<u64>,
}

/// The result of a walk: the discovered files plus whether any path failed.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct WalkResult {
    /// Discovered files, before ordering.
    pub files: Vec<Found>,
    /// True when at least one path could not be read.
    pub had_error: bool,
    /// Number of explicitly named directory roots (used to decide whether the
    /// text output needs a file-name prefix).
    pub directory_roots: usize,
}

struct IgnoreDir {
    matchers: Vec<Gitignore>,
}

#[derive(Debug)]
struct Types {
    positive: GlobSet,
    negative: GlobSet,
    has_positive: bool,
}

impl Types {
    fn build(options: &Options) -> Result<Types, String> {
        let positive = build_type_set(&options.types)?;
        let negative = build_type_set(&options.types_not)?;
        Ok(Types {
            positive,
            negative,
            has_positive: !options.types.is_empty(),
        })
    }

    fn allows(&self, name: &str, relative: &str) -> bool {
        if self.negative.is_match(name) || self.negative.is_match(relative) {
            return false;
        }
        if !self.has_positive {
            return true;
        }
        self.positive.is_match(name) || self.positive.is_match(relative)
    }
}

fn build_type_set(types: &[String]) -> Result<GlobSet, String> {
    let mut builder = GlobSetBuilder::new();
    for name in types {
        let patterns = TYPE_TABLE
            .iter()
            .find(|(known, _)| known == name)
            .map(|(_, patterns)| *patterns)
            .ok_or_else(|| format!("unrecognized file type: {name}"))?;
        for pattern in patterns {
            let glob = GlobBuilder::new(pattern)
                .literal_separator(true)
                .build()
                .map_err(|error| format!("invalid type glob {pattern:?}: {error}"))?;
            builder.add(glob);
        }
    }
    builder
        .build()
        .map_err(|error| format!("invalid type glob set: {error}"))
}

/// A walker bound to one [`Ctx`].
pub struct Finder<'a, 'b> {
    ctx: &'a mut Ctx<'b>,
    options: &'a Options,
    overrides: Override,
    types: Types,
    found: Vec<Found>,
    had_error: bool,
    directory_roots: usize,
    visited: HashSet<PathBuf>,
}

impl<'a, 'b> Finder<'a, 'b> {
    /// Create a walker for the given options.
    pub fn new(
        ctx: &'a mut Ctx<'b>,
        options: &'a Options,
    ) -> Result<Finder<'a, 'b>, String> {
        let overrides = build_overrides(ctx.cwd(), &options.globs)?;
        let types = Types::build(options)?;
        Ok(Finder {
            ctx,
            options,
            overrides,
            types,
            found: Vec::new(),
            had_error: false,
            directory_roots: 0,
            visited: HashSet::new(),
        })
    }

    /// Walk every search root and return the discovered files.
    pub fn walk(mut self) -> Result<WalkResult, Error> {
        let cwd = self.ctx.cwd().to_path_buf();
        let roots: Vec<(String, PathBuf)> = if self.options.paths.is_empty() {
            vec![(String::new(), cwd.clone())]
        } else {
            self.options
                .paths
                .iter()
                .map(|argument| (argument.clone(), resolve(&cwd, argument)))
                .collect()
        };
        for (display, guest) in roots {
            self.ctx.check_cancel()?;
            let metadata = match self.ctx.metadata(&guest) {
                Ok(metadata) => metadata,
                Err(error) => {
                    self.report(&display_path(&display, &guest), &error);
                    continue;
                }
            };
            if metadata.is_file() {
                // An explicitly named file is always searched, regardless of
                // hidden/ignore/glob filters (ripgrep's documented behaviour).
                self.found.push(Found {
                    guest: guest.clone(),
                    display: if display.is_empty() {
                        guest.display().to_string()
                    } else {
                        display
                    },
                    modified_ms: metadata.modified_ms,
                });
            } else if metadata.is_dir() {
                self.directory_roots += 1;
                let mut stack = Vec::new();
                let in_git = self.load_ancestors(&guest, &mut stack)?;
                let display_base = PathBuf::from(&display);
                self.walk_dir(&guest, &display_base, 0, &mut stack, in_git)?;
            } else {
                self.report(&guest.display().to_string(), &Error::InvalidRequest(
                    "not a regular file or directory".to_string(),
                ));
            }
        }
        Ok(WalkResult {
            files: self.found,
            had_error: self.had_error,
            directory_roots: self.directory_roots,
        })
    }

    /// Load the ignore files of the directories between the mount root and the
    /// search root, so a `.gitignore` above an explicitly named subdirectory
    /// still applies (ripgrep reads parent ignores by default).
    ///
    /// Returns whether a git repository was already found above the root; the
    /// walker keeps that flag while descending.
    fn load_ancestors(
        &mut self,
        root: &Path,
        stack: &mut Vec<IgnoreDir>,
    ) -> Result<bool, Error> {
        if self.options.no_ignore {
            return Ok(false);
        }
        let mount = match mount_root(root) {
            Some(mount) => mount,
            None => return Ok(false),
        };
        if root == mount {
            return Ok(self.has_git(root));
        }
        let mut in_git = false;
        let mut chain: Vec<PathBuf> = Vec::new();
        let mut current = root.parent();
        while let Some(directory) = current {
            chain.push(directory.to_path_buf());
            if directory == mount {
                break;
            }
            current = directory.parent();
        }
        chain.reverse();
        for directory in chain {
            in_git = in_git || self.has_git(&directory);
            if let Some(matchers) = self.read_ignore_files(&directory, in_git) {
                stack.push(IgnoreDir { matchers });
            }
        }
        Ok(in_git)
    }

    fn walk_dir(
        &mut self,
        guest: &Path,
        display: &Path,
        depth: usize,
        stack: &mut Vec<IgnoreDir>,
        in_git: bool,
    ) -> Result<(), Error> {
        self.ctx.check_cancel()?;
        let canonical = match self.ctx.canonicalize(guest) {
            Ok(canonical) => canonical,
            Err(error) => {
                self.report(&display.display().to_string(), &error);
                return Ok(());
            }
        };
        if !self.visited.insert(canonical) {
            return Ok(());
        }
        let entries = match self.ctx.read_dir(guest) {
            Ok(entries) => entries,
            Err(error) => {
                self.report(&display.display().to_string(), &error);
                return Ok(());
            }
        };
        let in_git = in_git || self.has_git(guest);
        let matchers = if self.options.no_ignore {
            Vec::new()
        } else {
            self.read_ignore_files(guest, in_git).unwrap_or_default()
        };
        stack.push(IgnoreDir { matchers });
        for entry in entries {
            self.ctx.check_cancel()?;
            let child = guest.join(&entry.name);
            let child_display = display.join(&entry.name);
            let is_dir = entry.kind == FileKind::Dir;
            let entry_depth = depth + 1;
            if let Some(max) = self.options.max_depth {
                if entry_depth > max {
                    continue;
                }
            }
            if !self.options.hidden && entry.name.starts_with('.') {
                continue;
            }
            let relative = path_relative_to(guest, &child);
            if !is_dir
                && !self
                    .types
                    .allows(&entry.name, relative.as_deref().unwrap_or(&entry.name))
            {
                continue;
            }
            let overridden = self.overrides.matched(&child, is_dir);
            if matches!(overridden, Match::Ignore(_)) {
                continue;
            }
            if !matches!(overridden, Match::Whitelist(_))
                && self.ignored(stack, &child, is_dir)
            {
                continue;
            }
            if is_dir {
                // `entry_depth <= max` was checked above; descend only when a
                // further level is still allowed.
                let deeper = self
                    .options
                    .max_depth
                    .map(|max| entry_depth < max)
                    .unwrap_or(true);
                if deeper {
                    self.walk_dir(&child, &child_display, entry_depth, stack, in_git)?;
                }
                continue;
            }
            if entry.kind != FileKind::File {
                // Symlinks and special files are not followed by ripgrep's
                // default walk.
                continue;
            }
            let metadata = match self.ctx.metadata(&child) {
                Ok(metadata) => metadata,
                Err(error) => {
                    self.report(&child_display.display().to_string(), &error);
                    continue;
                }
            };
            if let Some(max) = self.options.max_filesize {
                if metadata.len > max {
                    continue;
                }
            }
            self.found.push(Found {
                guest: child,
                display: child_display.display().to_string(),
                modified_ms: metadata.modified_ms,
            });
        }
        stack.pop();
        Ok(())
    }

    fn ignored(&self, stack: &[IgnoreDir], path: &Path, is_dir: bool) -> bool {
        for directory in stack.iter().rev() {
            for matcher in &directory.matchers {
                match matcher.matched(path, is_dir) {
                    Match::Ignore(_) => return true,
                    Match::Whitelist(_) => return false,
                    Match::None => {}
                }
            }
        }
        false
    }

    fn has_git(&mut self, directory: &Path) -> bool {
        matches!(self.ctx.metadata(&directory.join(".git")), Ok(_))
    }

    fn read_ignore_files(&mut self, directory: &Path, in_git: bool) -> Option<Vec<Gitignore>> {
        let mut matchers = Vec::new();
        for name in [".rgignore", ".ignore", ".gitignore"] {
            if name == ".gitignore" && !in_git {
                // A `.gitignore` outside a git repository is inert, exactly as
                // in the `ignore` crate's default `require_git` mode.
                continue;
            }
            let path = directory.join(name);
            let bytes = match self.ctx.read_file(&path) {
                Ok(bytes) => bytes,
                Err(_) => continue,
            };
            let text = String::from_utf8_lossy(&bytes);
            let mut builder = GitignoreBuilder::new(directory);
            for line in text.lines() {
                let _ = builder.add_line(None, line);
            }
            if let Ok(matcher) = builder.build() {
                matchers.push(matcher);
            }
        }
        Some(matchers)
    }

    fn report(&mut self, path: &str, error: &Error) {
        self.had_error = true;
        if self.options.no_messages {
            return;
        }
        let message = format!("rg: {path}: {error}\n");
        let _ = self.ctx.emit_stderr_str(&message);
    }
}

/// Build the `-g` / `--glob` override matcher rooted at the guest cwd.
fn build_overrides(cwd: &Path, globs: &[String]) -> Result<Override, String> {
    if globs.is_empty() {
        return Ok(Override::empty());
    }
    let mut builder = OverrideBuilder::new(cwd);
    for glob in globs {
        builder
            .add(glob)
            .map_err(|error| format!("invalid glob {glob:?}: {error}"))?;
    }
    builder
        .build()
        .map_err(|error| format!("invalid glob set: {error}"))
}

/// Resolve a command-line path against the guest cwd.
pub fn resolve(cwd: &Path, argument: &str) -> PathBuf {
    let path = Path::new(argument);
    let joined = if path.is_absolute() {
        path.to_path_buf()
    } else {
        cwd.join(path)
    };
    normalize(&joined)
}

fn normalize(path: &Path) -> PathBuf {
    use std::path::Component;
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    normalized
}

/// The guest mount containing `path` (`/dsh/workspace` or `/dsh/home`).
fn mount_root(path: &Path) -> Option<PathBuf> {
    for mount in [WORKSPACE_GUEST, HOME_GUEST] {
        let mount = Path::new(mount);
        if path.starts_with(mount) {
            return Some(mount.to_path_buf());
        }
    }
    None
}

/// The path of `child` relative to `parent`, when it is a descendant.
fn path_relative_to(parent: &Path, child: &Path) -> Option<String> {
    let relative = child.strip_prefix(parent).ok()?;
    Some(relative.to_string_lossy().replace('\\', "/"))
}

fn display_path(display: &str, guest: &Path) -> String {
    if display.is_empty() {
        guest.display().to_string()
    } else {
        display.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_type_table_matches_basename_globs() {
        let types = Types::build(&Options {
            types: vec!["rust".to_string()],
            ..Options::default()
        })
        .unwrap();
        assert!(types.allows("main.rs", "src/main.rs"));
        assert!(!types.allows("main.ts", "src/main.ts"));
        assert!(!types.allows("main.rs.bak", "main.rs.bak"));
    }

    #[test]
    fn negative_types_exclude_even_a_positive_match() {
        let types = Types::build(&Options {
            types: vec!["ts".to_string()],
            types_not: vec!["json".to_string()],
            ..Options::default()
        })
        .unwrap();
        assert!(types.allows("a.ts", "a.ts"));
        assert!(!types.allows("a.json", "a.json"));
    }

    #[test]
    fn unknown_types_are_usage_errors() {
        let error = Types::build(&Options {
            types: vec!["nonesuch".to_string()],
            ..Options::default()
        })
        .unwrap_err();
        assert!(error.contains("unrecognized file type"));
    }

    #[test]
    fn mount_roots_are_the_two_guest_mounts() {
        assert_eq!(
            mount_root(Path::new("/dsh/workspace/src")).as_deref(),
            Some(Path::new("/dsh/workspace"))
        );
        assert_eq!(
            mount_root(Path::new("/dsh/home")).as_deref(),
            Some(Path::new("/dsh/home"))
        );
        assert!(mount_root(Path::new("/etc")).is_none());
    }

    #[test]
    fn paths_normalize_dot_and_parent_components() {
        assert_eq!(
            resolve(Path::new("/dsh/workspace"), "./a/../b"),
            PathBuf::from("/dsh/workspace/b")
        );
        assert_eq!(
            resolve(Path::new("/dsh/workspace"), "a.txt"),
            PathBuf::from("/dsh/workspace/a.txt")
        );
        assert_eq!(
            resolve(Path::new("/dsh/workspace"), "/dsh/home/x"),
            PathBuf::from("/dsh/home/x")
        );
    }
}
