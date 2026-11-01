// SPDX-License-Identifier: MIT
//! The execution-surface read policy.
//!
//! `channel.md` §6 makes `/dsh/home/{sessions,storages,tool-journal}/**`
//! DSH-internal: an execution surface (`bash`, `python3`, `git`, and every
//! accelerator) receives `EACCES` with one remediation sentence and never sees
//! the bytes.
//!
//! This module owns the Rust half of that policy. It is applied by
//! [`crate::vfs::StdFsVfs`], the one read interface an accelerator has, so a
//! command cannot opt out of it: `rg`, `jaq`, `jq` and every future accelerator
//! reach host files only through the [`crate::vfs::Vfs`] methods that check
//! here. The Worker enforces the same policy one layer up; this is the
//! authoritative answer because the bytes live on this side of the channel.
//!
//! The sentence is byte-identical to the Worker's
//! `execReadDeniedMessage` (`plugins/wasi-toolbox/src/vfs-namespace.ts`); the
//! contract allows exactly one wording, so neither side may invent a second.

use std::path::{Component, Path, PathBuf};

/// The DSH-internal subtrees no execution surface may read.
pub const EXEC_INTERNAL_ROOTS: [&str; 3] = [
    "/dsh/home/sessions",
    "/dsh/home/storages",
    "/dsh/home/tool-journal",
];

/// The one remediation sentence every surface prints, without the `EACCES: `
/// prefix.
///
/// Matches the Worker's `execReadDeniedMessage` character for character: the
/// root, the semicolon, the two spaces of indentation-free continuation and the
/// trailing parenthesised path are all part of the contract.
///
/// @param path - the canonical guest path that was refused.
/// @param root - the DSH-internal root that contains it.
/// @returns the sentence, without a trailing newline.
pub fn exec_read_denied_message(path: &Path, root: &str) -> String {
    format!(
        "session-internal state under {root} is not readable from an execution surface; \
         read it through the session API or copy what you need into /dsh/workspace first ({})",
        path.display()
    )
}

/// The denial for a guest path, when it names DSH-internal state.
///
/// Every `.` and `..` component is folded before the comparison, so
/// `/dsh/home/../home/sessions` is the same refusal as `/dsh/home/sessions`.
/// The path is not resolved against the host filesystem: callers hand in the
/// path the mount table already canonicalised, which also covers a symlink
/// whose host target lands inside an internal root.
///
/// @param path - an absolute guest path.
/// @returns the containing root and the canonical guest path, or `None`.
pub fn exec_read_denial(path: &Path) -> Option<(&'static str, PathBuf)> {
    let normalized = normalize_absolute(path)?;
    for root in EXEC_INTERNAL_ROOTS {
        if normalized.starts_with(root) {
            return Some((root, normalized));
        }
    }
    None
}

/// Whether an execution surface may read `path`.
///
/// @param path - an absolute guest path.
/// @returns true unless the path lies in a DSH-internal subtree.
pub fn exec_readable(path: &Path) -> bool {
    exec_read_denial(path).is_none()
}

/// Fold `.`/`..` and duplicate separators of an absolute guest path.
///
/// A relative path, a Windows prefix or a `..` above `/` yields `None`: the
/// mount table rejects those before a read and this predicate must not guess.
fn normalize_absolute(path: &Path) -> Option<PathBuf> {
    if !path.is_absolute() {
        return None;
    }
    let mut normalized = PathBuf::from("/");
    for component in path.components() {
        match component {
            Component::RootDir => normalized = PathBuf::from("/"),
            Component::CurDir => {}
            Component::ParentDir => {
                if !normalized.pop() {
                    return None;
                }
            }
            Component::Normal(part) => normalized.push(part),
            Component::Prefix(_) => return None,
        }
    }
    Some(normalized)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn denial(path: &str) -> Option<(&'static str, String)> {
        exec_read_denial(Path::new(path)).map(|(root, path)| (root, path.display().to_string()))
    }

    #[test]
    fn the_internal_root_table_is_the_contract_table() {
        assert_eq!(
            EXEC_INTERNAL_ROOTS,
            [
                "/dsh/home/sessions",
                "/dsh/home/storages",
                "/dsh/home/tool-journal"
            ]
        );
    }

    #[test]
    fn every_internal_root_and_its_descendants_are_refused() {
        for root in EXEC_INTERNAL_ROOTS {
            assert_eq!(
                denial(root),
                Some((root, root.to_string())),
                "the root itself must be refused"
            );
            let child = format!("{root}/project/session.v4.jsonl");
            assert_eq!(
                denial(&child),
                Some((root, child.clone())),
                "a descendant must be refused"
            );
        }
    }

    #[test]
    fn the_sentence_is_the_worker_sentence() {
        let path = "/dsh/home/sessions/project/session.v4.jsonl";
        assert_eq!(
            exec_read_denied_message(Path::new(path), "/dsh/home/sessions"),
            "session-internal state under /dsh/home/sessions is not readable from an execution \
             surface; read it through the session API or copy what you need into /dsh/workspace \
             first (/dsh/home/sessions/project/session.v4.jsonl)"
        );
    }

    #[test]
    fn siblings_and_lookalikes_are_readable() {
        for path in [
            "/dsh/home",
            "/dsh/home/capabilities.json",
            "/dsh/home/AGENTS.md",
            "/dsh/home/notes/public.md",
            // A sibling whose name shares the root's prefix is not the root.
            "/dsh/home/sessions-archive/old.jsonl",
            "/dsh/home/storage",
            // The workspace is never DSH-internal, even with a matching name.
            "/dsh/workspace/sessions/session.v4.jsonl",
            "/dsh/home/tool-journal-notes.md",
        ] {
            assert_eq!(denial(path), None, "{path} must be readable");
            assert!(exec_readable(Path::new(path)), "{path} must be readable");
        }
    }

    #[test]
    fn dot_segments_fold_before_the_comparison() {
        assert_eq!(
            denial("/dsh/home/./sessions/./x"),
            Some((
                "/dsh/home/sessions",
                "/dsh/home/sessions/x".to_string()
            ))
        );
        assert_eq!(
            denial("/dsh/home/notes/../sessions"),
            Some((
                "/dsh/home/sessions",
                "/dsh/home/sessions".to_string()
            ))
        );
        // A `..` that would leave the guest root is not a path this predicate
        // can classify; the mount table rejects it with its own error.
        assert_eq!(denial("/dsh/home/../../sessions"), None);
        assert_eq!(denial("dsh/home/sessions"), None);
    }

    #[test]
    fn the_check_is_component_wise_not_a_string_prefix() {
        assert_eq!(denial("/dsh/home/sessionsx"), None);
        assert_eq!(denial("/dsh/home/sessions.bak"), None);
    }
}
