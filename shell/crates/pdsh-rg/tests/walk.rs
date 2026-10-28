// SPDX-License-Identifier: MIT
//! `rg --files` and the walk filters: hidden entries, ignore files, globs,
//! types, depth, size and ordering.

mod common;

use common::{matches, run, Fixture};

#[test]
fn files_lists_paths_relative_to_the_implicit_cwd() {
    let fixture = Fixture::new("files-basic");
    fixture.write("a.txt", "a");
    fixture.write("sub/b.txt", "b");
    let output = run(&fixture, "/dsh/workspace", &["--files"]);
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert_eq!(output.stdout, "a.txt\nsub/b.txt\n");
}

#[test]
fn an_explicit_dot_root_prefixes_the_listing() {
    let fixture = Fixture::new("files-dot");
    fixture.write("a.txt", "a");
    let output = run(&fixture, "/dsh/workspace", &["--files", "."]);
    assert_eq!(output.stdout, "./a.txt\n");
}

#[test]
fn an_explicit_directory_root_keeps_its_prefix() {
    let fixture = Fixture::new("files-subdir");
    fixture.write("sub/a.txt", "a");
    let output = run(&fixture, "/dsh/workspace", &["--files", "sub"]);
    assert_eq!(output.stdout, "sub/a.txt\n");
}

#[test]
fn files_reports_no_match_with_exit_1_for_an_empty_tree() {
    let fixture = Fixture::new("files-empty");
    fixture.mkdir("empty");
    let output = run(&fixture, "/dsh/workspace", &["--files"]);
    assert_eq!(output.code, 1);
    assert!(output.stdout.is_empty());
}

#[test]
fn hidden_entries_are_skipped_by_default() {
    let fixture = Fixture::new("hidden-default");
    fixture.write("visible.txt", "x");
    fixture.write(".dot", "x");
    fixture.write(".hid/inner.txt", "x");
    let output = run(&fixture, "/dsh/workspace", &["--files"]);
    assert_eq!(output.stdout, "visible.txt\n");
}

#[test]
fn hidden_entries_are_included_with_hidden() {
    let fixture = Fixture::new("hidden-flag");
    fixture.write("visible.txt", "x");
    fixture.write(".dot", "x");
    fixture.write(".hid/inner.txt", "x");
    let output = run(&fixture, "/dsh/workspace", &["--files", "--hidden"]);
    assert_eq!(output.stdout, ".dot\n.hid/inner.txt\nvisible.txt\n");
}

#[test]
fn an_explicit_hidden_root_is_always_searched() {
    let fixture = Fixture::new("hidden-explicit");
    fixture.write(".hid/inner.txt", "x");
    let output = run(&fixture, "/dsh/workspace", &["--files", ".hid"]);
    assert_eq!(output.stdout, ".hid/inner.txt\n");
}

#[test]
fn gitignore_is_respected_inside_a_git_repository() {
    let fixture = Fixture::new("gitignore");
    fixture.mkdir(".git");
    fixture.write(".gitignore", "*.log\nbuild/\n!keep.log\n");
    fixture.write("a.log", "x");
    fixture.write("keep.log", "x");
    fixture.write("build/b.txt", "x");
    fixture.write("src/x.txt", "x");
    let output = run(&fixture, "/dsh/workspace", &["--files"]);
    assert_eq!(output.stdout, "keep.log\nsrc/x.txt\n");
}

#[test]
fn gitignore_without_a_git_repository_is_inert() {
    // ripgrep's `ignore` crate defaults to `require_git(true)`; the accelerator
    // must reproduce that (a `.gitignore` outside a repo is not consulted).
    let fixture = Fixture::new("gitignore-no-git");
    fixture.write(".gitignore", "*.log\n");
    fixture.write("a.log", "x");
    let output = run(&fixture, "/dsh/workspace", &["--files"]);
    assert_eq!(output.stdout, "a.log\n");
}

#[test]
fn no_ignore_disables_gitignore_and_ignore_files() {
    let fixture = Fixture::new("no-ignore");
    fixture.mkdir(".git");
    fixture.write(".gitignore", "*.log\n");
    fixture.write(".ignore", "*.tmp\n");
    fixture.write("a.log", "x");
    fixture.write("b.tmp", "x");
    fixture.write("c.txt", "x");
    let output = run(&fixture, "/dsh/workspace", &["--files", "--no-ignore"]);
    assert_eq!(output.stdout, "a.log\nb.tmp\nc.txt\n");
}

#[test]
fn nested_gitignore_files_apply_to_their_subtree() {
    let fixture = Fixture::new("gitignore-nested");
    fixture.mkdir(".git");
    fixture.write(".gitignore", "*.log\n");
    fixture.write("src/.gitignore", "*.tmp\n");
    fixture.write("src/a.tmp", "x");
    fixture.write("src/b.rs", "x");
    fixture.write("root.log", "x");
    let output = run(&fixture, "/dsh/workspace", &["--files"]);
    assert_eq!(output.stdout, "src/b.rs\n");
}

#[test]
fn a_parent_gitignore_applies_to_an_explicit_subdirectory_root() {
    let fixture = Fixture::new("gitignore-parent");
    fixture.mkdir(".git");
    fixture.write(".gitignore", "*.log\n");
    fixture.write("src/a.log", "x");
    fixture.write("src/b.rs", "x");
    let output = run(&fixture, "/dsh/workspace", &["--files", "src"]);
    assert_eq!(output.stdout, "src/b.rs\n");
}

#[test]
fn glob_filters_by_basename_at_any_depth() {
    let fixture = Fixture::new("glob-basename");
    fixture.write("a.ts", "x");
    fixture.write("sub/b.ts", "x");
    fixture.write("sub/c.js", "x");
    let output = run(&fixture, "/dsh/workspace", &["--files", "--glob=*.ts"]);
    assert_eq!(output.stdout, "a.ts\nsub/b.ts\n");
}

#[test]
fn a_negated_glob_prunes_a_directory_tree() {
    let fixture = Fixture::new("glob-negated");
    fixture.write("keep/a.txt", "x");
    fixture.write("drop/b.txt", "x");
    let output = run(
        &fixture,
        "/dsh/workspace",
        &["--files", "--glob=!**/drop", "--glob=!**/drop/**"],
    );
    assert_eq!(output.stdout, "keep/a.txt\n");
}

#[test]
fn a_glob_whitelist_overrides_gitignore() {
    let fixture = Fixture::new("glob-over-ignore");
    fixture.mkdir(".git");
    fixture.write(".gitignore", "*.log\n");
    fixture.write("a.log", "x");
    fixture.write("b.txt", "x");
    let output = run(&fixture, "/dsh/workspace", &["--files", "--glob=*.log"]);
    assert_eq!(output.stdout, "a.log\n");
}

#[test]
fn globs_do_not_override_hidden_filtering() {
    let fixture = Fixture::new("glob-hidden");
    fixture.write(".hid/a.txt", "x");
    fixture.write("b.txt", "x");
    let output = run(&fixture, "/dsh/workspace", &["--files", "--glob=*.txt"]);
    assert_eq!(output.stdout, "b.txt\n");
}

#[test]
fn dsh_glob_command_vector_is_accepted_and_excludes_vcs_directories() {
    // Ported from DSH's `tool-fs-search` tests (`glob.ts`
    // `buildGlobCommand`: `--files --glob=PATTERN --sort=modified --no-ignore
    // --hidden` plus the paired VCS excludes).
    let fixture = Fixture::new("dsh-glob-vector");
    fixture.write(".git/config", "x");
    fixture.write("a.ts", "x");
    fixture.write("sub/b.ts", "x");
    fixture.write("sub/c.txt", "x");
    let output = run(
        &fixture,
        "/dsh/workspace",
        &[
            "--files",
            "--glob=**/*.ts",
            "--sort=modified",
            "--no-ignore",
            "--hidden",
            "--glob=!**/.git",
            "--glob=!**/.git/**",
            "--glob=!**/.svn",
            "--glob=!**/.svn/**",
            "--glob=!**/.hg",
            "--glob=!**/.hg/**",
        ],
    );
    assert_eq!(output.code, 0, "stderr: {}", output.stderr);
    assert_eq!(output.stdout, "a.ts\nsub/b.ts\n");
}

#[test]
fn sort_modified_orders_oldest_first_then_by_path() {
    let fixture = Fixture::new("sort-modified");
    fixture.write("z.txt", "x");
    fixture.write("m.txt", "x");
    fixture.write("a.txt", "x");
    fixture.set_modified("z.txt", 1_600_000_000);
    fixture.set_modified("a.txt", 1_700_000_000);
    fixture.set_modified("m.txt", 1_650_000_000);
    let output = run(&fixture, "/dsh/workspace", &["--files", "--sort=modified"]);
    assert_eq!(output.stdout, "z.txt\nm.txt\na.txt\n");
}

#[test]
fn sort_path_is_lexicographic() {
    let fixture = Fixture::new("sort-path");
    fixture.write("b.txt", "x");
    fixture.write("a/z.txt", "x");
    fixture.write("a.txt", "x");
    let output = run(&fixture, "/dsh/workspace", &["--files", "--sort=path"]);
    assert_eq!(output.stdout, "a.txt\na/z.txt\nb.txt\n");
}

#[test]
fn max_depth_limits_directory_traversal() {
    let fixture = Fixture::new("max-depth");
    fixture.write("top.txt", "x");
    fixture.write("one/inside.txt", "x");
    fixture.write("one/two/deep.txt", "x");
    let output = run(&fixture, "/dsh/workspace", &["--files", "--max-depth", "0"]);
    assert_eq!(output.code, 1);
    assert!(output.stdout.is_empty());
    let output = run(&fixture, "/dsh/workspace", &["--files", "--max-depth", "1"]);
    assert_eq!(output.stdout, "top.txt\n");
    let output = run(&fixture, "/dsh/workspace", &["--files", "--max-depth", "2"]);
    assert_eq!(output.stdout, "one/inside.txt\ntop.txt\n");
}

#[test]
fn max_filesize_skips_large_files() {
    let fixture = Fixture::new("max-filesize");
    fixture.write("small.txt", "x");
    fixture.write("large.txt", &"x".repeat(2048));
    let output = run(
        &fixture,
        "/dsh/workspace",
        &["--files", "--max-filesize", "1K"],
    );
    assert_eq!(output.stdout, "small.txt\n");
}

#[test]
fn type_filters_keep_only_the_named_language() {
    let fixture = Fixture::new("types");
    fixture.write("a.rs", "fn main() {}");
    fixture.write("b.py", "print(1)");
    let output = run(&fixture, "/dsh/workspace", &["--files", "-t", "rust"]);
    assert_eq!(output.stdout, "a.rs\n");
    let output = run(&fixture, "/dsh/workspace", &["--files", "-T", "rust"]);
    assert_eq!(output.stdout, "b.py\n");
    let output = run(&fixture, "/dsh/workspace", &["--files", "-t", "nonesuch"]);
    assert_eq!(output.code, 2);
    assert!(output.stderr.contains("unrecognized file type"));
}

#[test]
fn an_explicit_file_root_bypasses_filters() {
    let fixture = Fixture::new("explicit-file");
    fixture.mkdir(".git");
    fixture.write(".gitignore", "*.log\n");
    fixture.write("a.log", "x");
    let output = run(
        &fixture,
        "/dsh/workspace",
        &["--files", "--glob=*.rs", "a.log"],
    );
    assert_eq!(output.code, 0);
    assert_eq!(output.stdout, "a.log\n");
}

#[test]
fn a_missing_path_is_an_error_with_exit_2() {
    let fixture = Fixture::new("missing");
    let output = run(&fixture, "/dsh/workspace", &["needle", "nope"]);
    assert_eq!(output.code, 2);
    assert!(output.stderr.contains("nope"), "stderr: {}", output.stderr);
}

#[test]
fn no_messages_suppresses_the_error_text_but_keeps_the_exit_code() {
    let fixture = Fixture::new("no-messages");
    let output = run(
        &fixture,
        "/dsh/workspace",
        &["--no-messages", "needle", "nope"],
    );
    assert_eq!(output.code, 2);
    assert!(output.stderr.is_empty());
}

#[test]
fn files_from_the_home_mount_are_reachable() {
    let fixture = Fixture::new("home-mount");
    fixture.write_home("notes.txt", "needle\n");
    let output = run(&fixture, "/dsh/home", &["--files"]);
    assert_eq!(output.stdout, "notes.txt\n");
    let output = run(&fixture, "/dsh/home", &["--json", "-e", "needle"]);
    assert_eq!(matches(&output).len(), 1);
}

#[test]
fn a_relative_path_outside_the_mounts_is_rejected_by_the_sandbox() {
    let fixture = Fixture::new("sandbox");
    let output = run(&fixture, "/dsh/workspace", &["needle", "../../etc"]);
    // Normalization keeps the guest path inside /dsh; the mount table then
    // reports it missing rather than reading the host filesystem.
    assert_eq!(output.code, 2);
    assert!(output.stderr.contains("outside every guest mount"), "stderr: {}", output.stderr);
}
