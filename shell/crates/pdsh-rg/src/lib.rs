// SPDX-License-Identifier: MIT
//! `rg`: a read-only, ripgrep-compatible search accelerator.
//!
//! The command is exposed as [`RgCommand`] under the accelerator name `rg` and
//! through the free function [`run_rg`]. It is a *library* accelerator: it
//! never spawns a process and never writes anything. Every file is opened
//! through the [`pdsh_core::Vfs`] sandbox and every result byte is emitted through
//! [`pdsh_core::Ctx::emit_stdout`], so the core's file, size and output budgets
//! and its cancel token apply.
//!
//! Supported argv (superset of what the DSH `grep` / `glob` tools emit):
//!
//! ```text
//! rg [OPTIONS] PATTERN [PATH ...]
//! rg [OPTIONS] -e PATTERN ... [PATH ...]
//! rg --files [OPTIONS] [PATH ...]
//! ```
//!
//! `--json` prints ripgrep's JSON lines: `begin`, `match` (with byte offsets
//! and submatches), `context` (with `-A`/`-B`/`-C`), `end` (with per-file
//! stats) and the final `summary`. `--files` lists matching paths. Without
//! `--json` the text form is printed (`path:line:text` with `-n`/`-H`/
//! `--column`).
//!
//! Exit codes follow ripgrep: 0 when something matched, 1 when nothing matched,
//! 2 on error; cancellation maps to the pdsh-core 130.

pub mod args;
pub mod emit;
pub mod walk;

use std::path::Path;
use std::time::Instant;

use grep_printer::{JSONBuilder, Stats};
use grep_regex::{RegexMatcher, RegexMatcherBuilder};
use grep_searcher::{BinaryDetection, Searcher, SearcherBuilder};
use pdsh_core::{Command, Ctx, Error, EXIT_CANCELLED};

use crate::emit::{write_json_summary, CancelReader, CtxWriter, TextSink};
use crate::walk::{Finder, Found};

/// Exit code when at least one match was found.
pub const EXIT_MATCH: i32 = 0;
/// Exit code when nothing matched.
pub const EXIT_NO_MATCH: i32 = 1;
/// Exit code for a usage or search error.
pub const EXIT_ERROR: i32 = 2;

/// The registered `rg` accelerator.
#[derive(Debug, Default, Clone, Copy)]
pub struct RgCommand;

impl Command for RgCommand {
    fn name(&self) -> &str {
        "rg"
    }

    fn run(&self, argv: &[String], ctx: &mut Ctx<'_>) -> i32 {
        run_rg(argv, ctx)
    }
}

/// Run one `rg` invocation against the sandboxed context.
pub fn run_rg(argv: &[String], ctx: &mut Ctx<'_>) -> i32 {
    match execute(argv, ctx) {
        Ok(code) => code,
        Err(Error::Cancelled) => EXIT_CANCELLED,
        Err(error) => {
            let _ = ctx.emit_stderr_str(&format!("rg: {error}\n"));
            EXIT_ERROR
        }
    }
}

fn execute(argv: &[String], ctx: &mut Ctx<'_>) -> Result<i32, Error> {
    let invocation = match args::parse(argv) {
        Ok(invocation) => invocation,
        Err(message) => {
            ctx.emit_stderr_str(&format!("rg: {message}\n"))?;
            return Ok(EXIT_ERROR);
        }
    };
    let options = invocation.options.clone();
    if options.help {
        ctx.emit_stdout_str(HELP)?;
        return Ok(EXIT_MATCH);
    }
    if options.version {
        ctx.emit_stdout_str(&format!("rg {} (pdsh-shell)\n", pdsh_core::VERSION))?;
        return Ok(EXIT_MATCH);
    }
    let patterns: Vec<String> = if options.patterns.is_empty() {
        match &invocation.pattern {
            Some(pattern) => vec![pattern.clone()],
            None if options.files => Vec::new(),
            None => {
                ctx.emit_stderr_str("rg: no pattern given\n")?;
                return Ok(EXIT_ERROR);
            }
        }
    } else {
        options.patterns.clone()
    };
    let matcher = if options.files {
        None
    } else {
        match build_matcher(&patterns, &options) {
            Ok(matcher) => Some(matcher),
            Err(message) => {
                ctx.emit_stderr_str(&format!("rg: {message}\n"))?;
                return Ok(EXIT_ERROR);
            }
        }
    };

    let finder = match Finder::new(ctx, &options) {
        Ok(finder) => finder,
        Err(message) => {
            ctx.emit_stderr_str(&format!("rg: {message}\n"))?;
            return Ok(EXIT_ERROR);
        }
    };
    let mut document = finder.walk()?;
    sort_files(&mut document.files, &options);

    if options.files {
        for found in &document.files {
            ctx.check_cancel()?;
            ctx.emit_stdout_str(&format!("{}\n", found.display))?;
        }
        return Ok(if document.had_error {
            EXIT_ERROR
        } else if document.files.is_empty() {
            EXIT_NO_MATCH
        } else {
            EXIT_MATCH
        });
    }

    let mut searcher = build_searcher(&options);
    let matcher = match &matcher {
        Some(matcher) => matcher,
        None => return Ok(EXIT_NO_MATCH),
    };
    let with_filename =
        options.with_filename || document.files.len() > 1 || document.directory_roots > 0;
    let token = ctx.cancel_token().clone();
    let started = Instant::now();
    let mut total = Stats::new();
    let mut matched_any = false;
    let mut had_error = document.had_error;
    for found in &document.files {
        token.check()?;
        let outcome = if options.json {
            search_json_file(ctx, &mut searcher, matcher, found, &token)
        } else {
            search_text_file(
                ctx,
                &mut searcher,
                matcher,
                found,
                &token,
                with_filename,
                options.line_number || options.column,
                options.column,
            )
        };
        match outcome {
            Ok(outcome) => {
                matched_any |= outcome.matched;
                total += outcome.stats;
                if let Some(message) = outcome.error {
                    had_error = true;
                    if !options.no_messages {
                        ctx.emit_stderr_str(&format!("rg: {}: {message}\n", found.display))?;
                    }
                }
            }
            Err(Error::Cancelled) => return Err(Error::Cancelled),
            Err(error) => {
                had_error = true;
                if !options.no_messages {
                    ctx.emit_stderr_str(&format!("rg: {}: {error}\n", found.display))?;
                }
            }
        }
    }
    if options.json {
        write_json_summary(ctx, &total, started.elapsed())?;
    }
    Ok(if had_error {
        EXIT_ERROR
    } else if matched_any {
        EXIT_MATCH
    } else {
        EXIT_NO_MATCH
    })
}

fn build_matcher(patterns: &[String], options: &args::Options) -> Result<RegexMatcher, String> {
    let mut builder = RegexMatcherBuilder::new();
    builder
        .case_insensitive(options.case == args::Case::Insensitive)
        .case_smart(options.case == args::Case::Smart)
        .fixed_strings(options.fixed)
        .word(options.word);
    builder
        .build_many(patterns)
        .map_err(|error| error.to_string())
}

fn build_searcher(options: &args::Options) -> Searcher {
    let mut builder = SearcherBuilder::new();
    builder
        .line_number(true)
        .before_context(options.before)
        .after_context(options.after)
        .max_matches(options.max_count);
    if options.binary_text {
        builder.binary_detection(BinaryDetection::none());
    } else {
        builder.binary_detection(BinaryDetection::quit(b'\x00'));
    }
    builder.build()
}

fn sort_files(files: &mut [Found], options: &args::Options) {
    match options.sort {
        args::Sort::None => {}
        args::Sort::Path => files.sort_by(|left, right| left.display.cmp(&right.display)),
        args::Sort::Modified => files.sort_by(|left, right| {
            left.modified_ms
                .cmp(&right.modified_ms)
                .then_with(|| left.display.cmp(&right.display))
        }),
    }
}

struct FileOutcome {
    stats: Stats,
    matched: bool,
    error: Option<String>,
}

fn open_reader(
    ctx: &mut Ctx<'_>,
    found: &Found,
) -> Result<Box<dyn std::io::Read + Send>, Error> {
    ctx.open_read(Path::new(&found.guest))
}

fn search_json_file(
    ctx: &mut Ctx<'_>,
    searcher: &mut Searcher,
    matcher: &RegexMatcher,
    found: &Found,
    token: &pdsh_core::CancelToken,
) -> Result<FileOutcome, Error> {
    token.check()?;
    let reader = match open_reader(ctx, found) {
        Ok(reader) => reader,
        Err(Error::Cancelled) => return Err(Error::Cancelled),
        Err(error) => {
            return Ok(FileOutcome {
                stats: Stats::new(),
                matched: false,
                error: Some(error.to_string()),
            })
        }
    };
    let reader = CancelReader::new(reader, token.clone());
    let path = Path::new(&found.display).to_path_buf();
    let mut writer = CtxWriter::new(ctx);
    let mut search_error = None;
    let (stats, matched) = {
        let mut printer = JSONBuilder::new().build(&mut writer);
        let mut sink = printer.sink_with_path(matcher, &path);
        let result = searcher.search_reader(matcher, reader, &mut sink);
        let stats = sink.stats().clone();
        let matched = sink.has_match();
        if let Err(error) = result {
            search_error = Some(error.to_string());
        }
        (stats, matched)
    };
    if writer.cancelled() {
        return Err(Error::Cancelled);
    }
    Ok(FileOutcome {
        stats,
        matched,
        error: search_error,
    })
}

#[allow(clippy::too_many_arguments)]
fn search_text_file(
    ctx: &mut Ctx<'_>,
    searcher: &mut Searcher,
    matcher: &RegexMatcher,
    found: &Found,
    token: &pdsh_core::CancelToken,
    with_filename: bool,
    line_number: bool,
    column: bool,
) -> Result<FileOutcome, Error> {
    token.check()?;
    let reader = match open_reader(ctx, found) {
        Ok(reader) => reader,
        Err(Error::Cancelled) => return Err(Error::Cancelled),
        Err(error) => {
            return Ok(FileOutcome {
                stats: Stats::new(),
                matched: false,
                error: Some(error.to_string()),
            })
        }
    };
    let reader = CancelReader::new(reader, token.clone());
    let mut writer = CtxWriter::new(ctx);
    let mut search_error = None;
    let matched_flag = std::rc::Rc::new(std::cell::Cell::new(false));
    {
        let sink = TextSink::new(
            &mut writer,
            matcher.clone(),
            found.display.clone(),
            with_filename,
            line_number,
            column,
            matched_flag.clone(),
        );
        if let Err(error) = searcher.search_reader(matcher, reader, sink) {
            search_error = Some(error.to_string());
        }
    }
    if writer.cancelled() {
        return Err(Error::Cancelled);
    }
    Ok(FileOutcome {
        stats: Stats::new(),
        matched: matched_flag.get(),
        error: search_error,
    })
}

const HELP: &str = "\
rg (pdsh-shell read-only accelerator)

USAGE:
    rg [OPTIONS] PATTERN [PATH ...]
    rg [OPTIONS] -e PATTERN ... [PATH ...]
    rg --files [OPTIONS] [PATH ...]

OPTIONS:
        --json               print ripgrep-compatible JSON lines
        --files              list files instead of searching contents
        --sort=SORTBY        none, path or modified
        --no-ignore          do not read .gitignore / .ignore files
        --hidden             search hidden files and directories
        --no-config          accepted and ignored (no config file is read)
    -g, --glob GLOB          include/exclude files; repeatable, ! negates
    -e, --regexp PATTERN     pattern; repeatable
    -i, --ignore-case        case insensitive search
    -s, --case-sensitive     case sensitive search
    -S, --smart-case         case insensitive unless the pattern has uppercase
    -F, --fixed-strings      treat the pattern as a literal string
    -w, --word-regexp        match whole words only
    -n, --line-number        show line numbers in text output
    -H, --with-filename      always show the file name in text output
        --column             show the first match column in text output
    -m, --max-count NUM      stop after NUM matches per file
        --max-filesize SIZE  skip files larger than SIZE (K/M/G suffixes)
        --max-depth NUM      limit directory traversal depth
    -t, --type TYPE          only search files of TYPE; repeatable
    -T, --type-not TYPE      skip files of TYPE; repeatable
    -B, --before-context N   show N lines before each match
    -A, --after-context N    show N lines after each match
    -C, --context N          show N lines before and after each match
        --no-messages        suppress error messages
    -h, --help               print this help
        --version            print the version
";
