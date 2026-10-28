// SPDX-License-Identifier: MIT
//! Output plumbing shared by the JSON and text printers.
//!
//! Every byte an accelerator prints goes through [`pdsh_core::Ctx::emit_stdout`],
//! so the per-stream budget and the 64 KiB cancellation cadence of the core are
//! enforced for the search output too. The JSON lines themselves are produced
//! by `grep-printer`, the same crate ripgrep's `--json` flag uses, and the
//! final `summary` line is formatted here with ripgrep's field order.

use std::cell::Cell;
use std::io::{self, Read};
use std::rc::Rc;

use grep_matcher::Matcher;
use grep_printer::Stats;
use grep_searcher::{Sink, SinkContext, SinkFinish, SinkMatch};
use pdsh_core::{CancelToken, Ctx, Error};

/// An `io::Write` adapter that feeds [`Ctx::emit_stdout`].
pub struct CtxWriter<'a, 'b> {
    ctx: &'a mut Ctx<'b>,
    cancelled: bool,
}

impl<'a, 'b> CtxWriter<'a, 'b> {
    /// Wrap one command context.
    pub fn new(ctx: &'a mut Ctx<'b>) -> Self {
        CtxWriter {
            ctx,
            cancelled: false,
        }
    }

    /// True once a write observed the cancel token.
    pub fn cancelled(&self) -> bool {
        self.cancelled
    }

    /// Emit raw bytes, mapping a cancelled write to an I/O error for the
    /// printer layer.
    fn emit(&mut self, bytes: &[u8]) -> io::Result<()> {
        match self.ctx.emit_stdout(bytes) {
            Ok(()) => Ok(()),
            Err(Error::Cancelled) => {
                self.cancelled = true;
                Err(io::Error::new(io::ErrorKind::Interrupted, "cancelled"))
            }
            Err(error) => Err(io::Error::other(error.to_string())),
        }
    }
}

impl io::Write for CtxWriter<'_, '_> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.emit(bytes)?;
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// A reader that checks the cancel token on every read.
///
/// The searcher reads in bounded chunks, so this keeps cancellation responsive
/// even for a large file with no matches (and therefore no output writes).
pub struct CancelReader<R> {
    inner: R,
    token: CancelToken,
}

impl<R: Read> CancelReader<R> {
    /// Wrap a VFS reader.
    pub fn new(inner: R, token: CancelToken) -> Self {
        CancelReader { inner, token }
    }
}

impl<R: Read> Read for CancelReader<R> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if self.token.is_cancelled() {
            return Err(io::Error::new(io::ErrorKind::Interrupted, "cancelled"));
        }
        self.inner.read(buffer)
    }
}

/// The text-mode sink: one line per match, `path:line:column:text`.
pub struct TextSink<'w, 'c, 'd> {
    writer: &'w mut CtxWriter<'c, 'd>,
    matcher: grep_regex::RegexMatcher,
    path: String,
    with_filename: bool,
    line_number: bool,
    column: bool,
    matched: Rc<Cell<bool>>,
}

impl<'w, 'c, 'd> TextSink<'w, 'c, 'd> {
    /// Build a text sink for one file.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        writer: &'w mut CtxWriter<'c, 'd>,
        matcher: grep_regex::RegexMatcher,
        path: String,
        with_filename: bool,
        line_number: bool,
        column: bool,
        matched: Rc<Cell<bool>>,
    ) -> Self {
        TextSink {
            writer,
            matcher,
            path,
            with_filename,
            line_number,
            column,
            matched,
        }
    }

    fn prefix(&mut self, line_number: Option<u64>, column: Option<usize>) -> io::Result<()> {
        let mut prefix = String::new();
        if self.with_filename {
            prefix.push_str(&self.path);
            prefix.push(':');
        }
        if self.line_number {
            if let Some(number) = line_number {
                prefix.push_str(&number.to_string());
                prefix.push(':');
            }
        }
        if self.column {
            if let Some(column) = column {
                prefix.push_str(&column.to_string());
                prefix.push(':');
            }
        }
        self.writer.emit(prefix.as_bytes())
    }
}

impl Sink for TextSink<'_, '_, '_> {
    type Error = io::Error;

    fn matched(
        &mut self,
        _searcher: &grep_searcher::Searcher,
        mat: &SinkMatch<'_>,
    ) -> Result<bool, io::Error> {
        self.matched.set(true);
        let column = match self.matcher.find(mat.bytes()) {
            Ok(Some(found)) => Some(found.start() + 1),
            _ => None,
        };
        self.prefix(mat.line_number(), column)?;
        self.writer.emit(mat.bytes())?;
        Ok(true)
    }

    fn context(
        &mut self,
        _searcher: &grep_searcher::Searcher,
        context: &SinkContext<'_>,
    ) -> Result<bool, io::Error> {
        self.prefix(context.line_number(), None)?;
        self.writer.emit(context.bytes())?;
        Ok(true)
    }

    fn binary_data(
        &mut self,
        _searcher: &grep_searcher::Searcher,
        _offset: u64,
    ) -> Result<bool, io::Error> {
        Ok(true)
    }

    fn begin(&mut self, _searcher: &grep_searcher::Searcher) -> Result<bool, io::Error> {
        Ok(true)
    }

    fn finish(
        &mut self,
        _searcher: &grep_searcher::Searcher,
        _finish: &SinkFinish,
    ) -> Result<(), io::Error> {
        Ok(())
    }
}

/// Render a duration in ripgrep's JSON timing shape.
pub fn duration_json(duration: std::time::Duration) -> String {
    let seconds = duration.as_secs();
    let nanos = duration.subsec_nanos();
    let human = seconds as f64 + f64::from(nanos) / 1_000_000_000.0;
    format!(
        "{{\"human\":\"{human:.6}s\",\"nanos\":{nanos},\"secs\":{seconds}}}"
    )
}

/// Render the aggregate statistics object with ripgrep's sorted key order.
pub fn stats_json(stats: &Stats, elapsed: std::time::Duration) -> String {
    format!(
        "{{\"bytes_printed\":{},\"bytes_searched\":{},\"elapsed\":{},\"matched_lines\":{},\"matches\":{},\"searches\":{},\"searches_with_match\":{}}}",
        stats.bytes_printed(),
        stats.bytes_searched(),
        duration_json(elapsed),
        stats.matched_lines(),
        stats.matches(),
        stats.searches(),
        stats.searches_with_match()
    )
}

/// Write ripgrep's final `summary` JSON line.
pub fn write_json_summary(
    ctx: &mut Ctx<'_>,
    stats: &Stats,
    elapsed: std::time::Duration,
) -> Result<(), Error> {
    let line = format!(
        "{{\"data\":{{\"elapsed_total\":{},\"stats\":{}}},\"type\":\"summary\"}}\n",
        duration_json(elapsed),
        stats_json(stats, stats.elapsed())
    );
    ctx.emit_stdout_str(&line)
}
