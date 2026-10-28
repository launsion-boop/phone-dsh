// SPDX-License-Identifier: MIT
//! Lazy JSON input stream for the Worker jq engine.
//!
//! jq's input layer is one continuous byte stream across the file operands on
//! the command line. This module keeps that contract while reading lazily: a
//! document is parsed only when the main loop or the `input`/`inputs` filters
//! ask for it, so `jq -n 1 missing.json` never opens the file and a parse error
//! after the values a filter already printed is reported at that point.
//!
//! The line accounting follows jq 1.6's `fgets(buf, 4096)` reads. That is why
//! `input_line_number` is not simply the physical line of the document: a
//! newline in the next 4095-byte read chunk is counted before the next
//! document. The algorithm is the same one the Worker's previous TypeScript
//! shim used, now on raw bytes in the real engine.

use std::cell::RefCell;
use std::io::Read;
use std::rc::Rc;

use jaq_json::Val;

/// One parsed top-level document and the facts jq reports about it.
#[derive(Clone, Debug)]
pub struct Doc {
    /// The parsed value.
    pub value: Val,
    /// Operand that supplied the document's final byte.
    pub source: String,
    /// jq 1.6 `input_line_number` for the document.
    pub input_line: usize,
}

/// The source/line pair jq prints for a runtime error.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Position {
    /// Last source read, when one has a usable name.
    pub source: Option<String>,
    /// Last line jq's reader counted for that source.
    pub line: usize,
}

impl Position {
    /// Render the `(at <source>:<line>)` fragment.
    pub fn render(&self) -> String {
        match (&self.source, self.line) {
            (Some(source), line) => format!("{source}:{line}"),
            (None, _) => "<unknown>".to_string(),
        }
    }
}

/// An input-layer failure: opening a file, reading it, or parsing JSON.
#[derive(Clone, Debug)]
pub enum InputError {
    /// An operand could not be opened or read.
    Open { path: String, message: String },
    /// The stream does not contain a valid JSON value at the current offset.
    Parse { message: String },
}

impl InputError {
    /// jq's exit status for this class of failure.
    pub fn exit_code(&self) -> i32 {
        match self {
            // jq 1.6 reports a missing/unreadable operand as a command error.
            Self::Open { .. } => 2,
            // A malformed input document is exit 4.
            Self::Parse { .. } => 4,
        }
    }
}

impl std::fmt::Display for InputError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Open { path, message } => {
                write!(f, "jq: error: Could not open file {path}: {message}")
            }
            Self::Parse { message } => write!(f, "jq: parse error: {message}"),
        }
    }
}

/// Where one input operand comes from.
#[derive(Clone, Debug)]
enum PendingSource {
    Stdin,
    File(String),
}

/// The loaded byte range of one operand plus its line lookup tables.
#[derive(Clone, Debug)]
struct SourceRange {
    name: String,
    start: usize,
    end: usize,
    /// jq 1.6's 4096-byte read checkpoints.
    checkpoints: Vec<(usize, usize)>,
    /// True when the source begins with a UTF-8 BOM and has no other bytes.
    bom_only: bool,
    /// True when the operand could not be opened; its range is only a marker.
    open_failed: bool,
}

/// A lazily loaded concatenation of the operands and the parse cursor.
pub struct InputCursor {
    pending: Vec<PendingSource>,
    loaded: usize,
    stdin: Option<Vec<u8>>,
    stdin_used: bool,
    buffer: Vec<u8>,
    ranges: Vec<SourceRange>,
    offset: usize,
    position: Rc<RefCell<Position>>,
    /// Operands jq could not open. jq prints them but keeps reading the rest
    /// of the command line, and the final status is 2 even if the filter
    /// otherwise succeeded.
    open_errors: Vec<InputError>,
    /// A parse error consumes the rest of the stream: later `input` calls see
    /// EOF (jq's `break`) instead of parsing the same broken bytes again.
    failed: bool,
}

impl InputCursor {
    /// Build a cursor over the operands. An empty list means standard input.
    pub fn new(files: &[String]) -> Self {
        let pending = if files.is_empty() {
            vec![PendingSource::Stdin]
        } else {
            files
                .iter()
                .map(|file| {
                    if file == "-" {
                        PendingSource::Stdin
                    } else {
                        PendingSource::File(file.clone())
                    }
                })
                .collect()
        };
        Self {
            pending,
            loaded: 0,
            stdin: None,
            stdin_used: false,
            buffer: Vec::new(),
            ranges: Vec::new(),
            offset: 0,
            position: Rc::new(RefCell::new(Position::default())),
            open_errors: Vec::new(),
            failed: false,
        }
    }

    /// Shared position cell the `input_line_number` filter and errors read.
    pub fn position(&self) -> Rc<RefCell<Position>> {
        Rc::clone(&self.position)
    }

    /// Load every source now (raw input and `-s` need the whole stream).
    ///
    /// Operands that cannot be opened are recorded and skipped, matching jq's
    /// behavior: a missing file does not hide the documents of later operands.
    pub fn load_all(&mut self) {
        while self.loaded < self.pending.len() {
            let _ = self.load_next();
        }
    }

    /// Operand-open failures collected while reading the stream.
    pub fn take_errors(&mut self) -> Vec<InputError> {
        std::mem::take(&mut self.open_errors)
    }

    fn load_next(&mut self) -> Result<bool, InputError> {
        let Some(pending) = self.pending.get(self.loaded).cloned() else {
            return Ok(false);
        };
        self.loaded += 1;
        let (name, bytes) = match pending {
            PendingSource::Stdin => {
                let bytes = if self.stdin_used {
                    Vec::new()
                } else {
                    self.stdin_used = true;
                    if self.stdin.is_none() {
                        let mut bytes = Vec::new();
                        if let Err(error) = std::io::stdin().read_to_end(&mut bytes) {
                            self.record_open("<stdin>".to_string(), error.to_string());
                            return Ok(true);
                        }
                        self.stdin = Some(bytes);
                    }
                    self.stdin.clone().unwrap_or_default()
                };
                ("<stdin>".to_string(), bytes)
            }
            PendingSource::File(path) => {
                // WASI preview1 has no process cwd: resolve a relative operand
                // against the toolbox-provided PWD before the preopen lookup,
                // matching jq's shell-relative file semantics.
                let resolved = resolve_guest_path(&path);
                match std::fs::read(&resolved) {
                    Ok(bytes) => (path, bytes),
                    Err(error) => {
                        self.record_open(path, error.to_string());
                        return Ok(true);
                    }
                }
            }
        };
        self.push_range(name, &bytes);
        Ok(true)
    }

    fn record_open(&mut self, path: String, message: String) {
        self.open_errors.push(InputError::Open {
            path: path.clone(),
            message,
        });
        // A zero-length range names the failed operand for jq's `(at
        // missing.json:0)` break position while leaving the byte stream alone.
        self.ranges.push(SourceRange {
            name: path,
            start: self.buffer.len(),
            end: self.buffer.len(),
            checkpoints: Vec::new(),
            bom_only: false,
            open_failed: true,
        });
    }

    fn push_range(&mut self, name: String, bytes: &[u8]) {
        let start = self.buffer.len();
        let end = start + bytes.len();
        let checkpoints = line_checkpoints(bytes);
        let bom_only = bytes.len() == 3
            && bytes[0] == 0xef
            && bytes[1] == 0xbb
            && bytes[2] == 0xbf;
        self.buffer.extend_from_slice(bytes);
        self.ranges.push(SourceRange {
            name,
            start,
            end,
            checkpoints,
            bom_only,
            open_failed: false,
        });
    }

    /// Name and line count of the last operand, which is what `-s` leaves in
    /// `input_line_number` after consuming the whole stream.
    fn final_position(&self) -> Position {
        match self.ranges.last() {
            Some(range) => Position {
                source: Some(range.name.clone()),
                line: range.checkpoints.last().map(|(_, line)| *line).unwrap_or(0),
            },
            None => Position {
                source: Some("<stdin>".to_string()),
                line: 0,
            },
        }
    }

    /// Make byte `index` available, loading the next operand when needed.
    fn ensure(&mut self, index: usize) -> Result<bool, InputError> {
        while self.buffer.len() <= index && self.loaded < self.pending.len() {
            self.load_next()?;
        }
        Ok(index < self.buffer.len())
    }

    fn skip_trivia(&mut self) -> Result<bool, InputError> {
        loop {
            if !self.ensure(self.offset)? {
                return Ok(false);
            }
            match self.buffer[self.offset] {
                b' ' | b'\t' | b'\n' | b'\r' => self.offset += 1,
                b'#' => {
                    while self.ensure(self.offset)? && self.buffer[self.offset] != b'\n' {
                        self.offset += 1;
                    }
                }
                _ => return Ok(true),
            }
        }
    }

    /// Parse the next document, or answer `None` at end of input.
    pub fn next_doc(&mut self) -> Result<Option<Doc>, InputError> {
        if self.failed {
            return Ok(None);
        }
        // jq skips a UTF-8 BOM only at the very start of the concatenated
        // stream; its three raw bytes still count for line accounting. Peek
        // only while the bytes seen so far could still be that BOM: a
        // self-contained two-byte document such as `{}` must not open the
        // next operand just to disprove a prefix it never had.
        if self.offset == 0 && self.ensure(0)? && self.buffer[0] == 0xef {
            if self.ensure(1)? && self.buffer[1] == 0xbb && self.ensure(2)? && self.buffer[2] == 0xbf {
                self.offset = 3;
            }
        }
        if !self.skip_trivia()? {
            let position = self.break_position();
            *self.position.borrow_mut() = position;
            return Ok(None);
        }
        let start = self.offset;
        let end = match self.scan_value_end(start) {
            Ok(end) => end,
            Err(error) => {
                self.failed = true;
                return Err(error);
            }
        };
        let slice = &self.buffer[start..end];
        let mut value = match jaq_json::read::parse_single(slice) {
            Ok(value) => value,
            Err(error) => {
                self.failed = true;
                return Err(InputError::Parse {
                    message: format!("{error}"),
                });
            }
        };
        sanitize_value(&mut value);
        let end_range = self.range_at(end.saturating_sub(1));
        let (source, input_line) = match end_range {
            Some(range) => {
                let local_end = end - range.start;
                let mut input_line = input_line(&range.checkpoints, local_end);
                // jq's lexer needs a delimiter after a number or literal. If
                // the token ends exactly at an operand boundary it opens the
                // next operand before returning the value; the line counter
                // then comes from that operand's first read.
                let raw = &self.buffer[start..end];
                let primitive = !matches!(raw.first(), Some(b'{' | b'[' | b'"'));
                let range_index = self
                    .ranges
                    .iter()
                    .position(|candidate| candidate.start == range.start)
                    .unwrap_or(0);
                let range_end = range.end;
                let range_name = range.name.clone();
                if primitive && end == range_end {
                    if let Some(continued) = self.continued_input_line(range_index) {
                        input_line = continued;
                    }
                }
                (range_name, input_line)
            }
            None => ("<stdin>".to_string(), 0),
        };
        self.offset = end;
        let doc = Doc {
            value,
            source: source.clone(),
            input_line,
        };
        *self.position.borrow_mut() = Position {
            source: Some(source),
            line: input_line,
        };
        Ok(Some(doc))
    }

    fn range_at(&self, offset: usize) -> Option<&SourceRange> {
        self.ranges
            .iter()
            .find(|range| offset >= range.start && offset < range.end)
            .or_else(|| self.ranges.last())
    }

    fn continued_input_line(&mut self, end_index: usize) -> Option<usize> {
        let mut opened = false;
        let mut index = end_index + 1;
        loop {
            if index >= self.ranges.len() {
                if self.loaded >= self.pending.len() {
                    break;
                }
                self.load_next().ok()?;
                continue;
            }
            opened = true;
            let range = &self.ranges[index];
            if range.end > range.start {
                return Some(if first_line_terminated(&self.buffer[range.start..range.end]) {
                    1
                } else {
                    0
                });
            }
            index += 1;
        }
        opened.then_some(0)
    }

    fn scan_value_end(&mut self, start: usize) -> Result<usize, InputError> {
        let first = self.buffer.get(start).copied().ok_or_else(|| InputError::Parse {
            message: "Unexpected end of JSON input".to_string(),
        })?;
        if first == b'"' {
            let mut escaped = false;
            let mut index = start + 1;
            loop {
                if !self.ensure(index)? {
                    return Err(InputError::Parse {
                        message: "Unclosed string".to_string(),
                    });
                }
                let byte = self.buffer[index];
                if escaped {
                    escaped = false;
                } else if byte == b'\\' {
                    escaped = true;
                } else if byte == b'"' {
                    return Ok(index + 1);
                }
                index += 1;
            }
        }
        if first == b'{' || first == b'[' {
            let mut expected: Vec<u8> = Vec::new();
            let mut in_string = false;
            let mut escaped = false;
            let mut index = start;
            loop {
                if !self.ensure(index)? {
                    return Err(InputError::Parse {
                        message: format!("Unclosed {}", char::from(first)),
                    });
                }
                let byte = self.buffer[index];
                if in_string {
                    if escaped {
                        escaped = false;
                    } else if byte == b'\\' {
                        escaped = true;
                    } else if byte == b'"' {
                        in_string = false;
                    }
                    index += 1;
                    continue;
                }
                match byte {
                    b'"' => in_string = true,
                    b'#' => {
                        while self.ensure(index)? && self.buffer[index] != b'\n' {
                            index += 1;
                        }
                        continue;
                    }
                    b'{' => expected.push(b'}'),
                    b'[' => expected.push(b']'),
                    b'}' | b']' => {
                        if expected.pop() != Some(byte) {
                            return Err(InputError::Parse {
                                message: format!("Mismatched JSON delimiter at byte {index}"),
                            });
                        }
                        if expected.is_empty() {
                            return Ok(index + 1);
                        }
                    }
                    _ => {}
                }
                index += 1;
            }
        }
        let mut index = start;
        loop {
            if !self.ensure(index)? {
                return Ok(index);
            }
            let byte = self.buffer[index];
            if matches!(
                byte,
                b' ' | b'\t' | b'\n' | b'\r' | b',' | b']' | b'}' | b'[' | b'{' | b'"' | b'#'
            ) {
                return Ok(index);
            }
            index += 1;
        }
    }
}

/// Replace invalid UTF-8 inside JSON strings the way jq 1.6 does.
///
/// jaq preserves invalid bytes in `TStr` values; jq decodes them to U+FFFD.
/// Applying the platform's maximal-subsequence replacement after parsing keeps
/// the raw byte offsets used for line accounting, so only the visible string is
/// rewritten.
fn sanitize_value(value: &mut Val) {
    match value {
        Val::TStr(bytes) => {
            let text = String::from_utf8_lossy(bytes).into_owned();
            *value = Val::utf8_str(text);
        }
        Val::Arr(items) => {
            for item in std::rc::Rc::make_mut(items) {
                sanitize_value(item);
            }
        }
        Val::Obj(map) => {
            let map = std::rc::Rc::make_mut(map);
            let entries: Vec<(Val, Val)> = map.drain(..).collect();
            for (mut key, mut val) in entries {
                sanitize_value(&mut key);
                sanitize_value(&mut val);
                map.insert(key, val);
            }
        }
        _ => {}
    }
}

/// jq 1.6's `fgets(buf, 4096)` chunk boundaries and newline counts.
fn line_checkpoints(bytes: &[u8]) -> Vec<(usize, usize)> {
    let mut checkpoints = Vec::new();
    let mut position = 0usize;
    let mut line = 0usize;
    while position < bytes.len() {
        let limit = (position + 4095).min(bytes.len());
        let newline = bytes[position..limit].iter().position(|byte| *byte == b'\n');
        let end = match newline {
            Some(offset) => position + offset + 1,
            None => limit,
        };
        if newline.is_some() {
            line += 1;
        }
        checkpoints.push((end, line));
        position = end;
    }
    checkpoints
}

fn input_line(checkpoints: &[(usize, usize)], end: usize) -> usize {
    if end == 0 {
        return 0;
    }
    let index = checkpoints.partition_point(|(checkpoint, _)| *checkpoint < end);
    checkpoints.get(index).map(|(_, line)| *line).unwrap_or(0)
}

/// Resolve a guest-relative path against the PWD the toolbox sets.
pub fn resolve_guest_path(path: &str) -> std::path::PathBuf {
    let candidate = std::path::Path::new(path);
    if candidate.is_absolute() {
        return candidate.to_path_buf();
    }
    let cwd = std::env::var("PWD").unwrap_or_else(|_| "/dsh/workspace".to_string());
    std::path::Path::new(&cwd).join(candidate)
}

fn first_line_terminated(bytes: &[u8]) -> bool {
    bytes[..bytes.len().min(4095)].contains(&b'\n')
}

fn newline_count(bytes: &[u8]) -> usize {
    bytes.iter().filter(|byte| **byte == b'\n').count()
}

fn horizontal(byte: u8) -> bool {
    matches!(byte, b' ' | b'\t' | b'\r')
}

// The public wrapper that can see the buffer.
impl InputCursor {
    fn break_position(&self) -> Position {
        let Some(last) = self.ranges.last() else {
            return Position {
                source: Some("<stdin>".to_string()),
                line: 0,
            };
        };
        let source = Some(last.name.clone());
        let bytes = &self.buffer[last.start..last.end];
        if bytes.is_empty() || last.bom_only {
            return Position { source, line: 0 };
        }
        let leading_bom = self.ranges.len() == 1
            && bytes.len() >= 3
            && bytes[0] == 0xef
            && bytes[1] == 0xbb
            && bytes[2] == 0xbf;
        let skip = if leading_bom { 3 } else { 0 };
        if bytes[skip..].iter().all(|byte| horizontal(*byte)) {
            return Position { source, line: 0 };
        }
        if bytes.last() == Some(&b'\n') {
            return Position {
                source,
                line: newline_count(bytes),
            };
        }
        let mut previous = bytes.len();
        while previous > 0 && horizontal(bytes[previous - 1]) {
            previous -= 1;
        }
        if previous > 0 && bytes[previous - 1] == b'\n' {
            return Position {
                source,
                line: newline_count(bytes),
            };
        }
        Position {
            source: None,
            line: 0,
        }
    }
}

/// Raw (`-R`) input: one string per line, with jq's line accounting.
///
/// Raw input stays lazy too: the next line is assembled from only the operands
/// whose bytes it actually needs. A newline inside the first operand therefore
/// never opens a later one, which is what makes `-n -R first(inputs)` with a
/// missing second operand exit 0 instead of reporting an open error.
pub struct RawCursor {
    inner: InputCursor,
    /// First byte of the next unread line in the concatenated operand bytes.
    offset: usize,
    position: Rc<RefCell<Position>>,
    finished: bool,
}

impl RawCursor {
    /// Build a raw cursor over the same operand list.
    pub fn new(files: &[String]) -> Self {
        let inner = InputCursor::new(files);
        let position = inner.position();
        Self {
            inner,
            offset: 0,
            position,
            finished: false,
        }
    }

    /// Shared error/`input_line_number` position.
    pub fn position(&self) -> Rc<RefCell<Position>> {
        Rc::clone(&self.position)
    }

    /// Position jq reports after raw input reaches EOF.
    ///
    /// JSON whitespace is trivia, but raw whitespace is data: a final line
    /// without its newline leaves the reader without a source/line, even when
    /// the line is only spaces. A terminated final line reports that operand's
    /// newline count; trailing empty operands reset it to the last
    /// `file:0` only while the preceding line was terminated. An unreadable
    /// operand keeps its own `file:0` marker, as JSON's break position does.
    fn raw_eof_position(&self) -> Position {
        let Some(last) = self.inner.ranges.last() else {
            return Position {
                source: Some("<stdin>".to_string()),
                line: 0,
            };
        };
        let source = Some(last.name.clone());
        if last.start != last.end {
            let bytes = &self.inner.buffer[last.start..last.end];
            if bytes.last() == Some(&b'\n') {
                return Position {
                    source,
                    line: newline_count(bytes),
                };
            }
            return Position { source: None, line: 0 };
        }
        if last.open_failed {
            return Position { source, line: 0 };
        }
        let terminated = self
            .inner
            .ranges
            .iter()
            .rev()
            .find(|range| range.end > range.start)
            .map(|range| self.inner.buffer[range.end - 1] == b'\n')
            .unwrap_or(true);
        if terminated {
            Position { source, line: 0 }
        } else {
            Position { source: None, line: 0 }
        }
    }

    fn finish(&mut self) -> Option<Doc> {
        self.finished = true;
        *self.position.borrow_mut() = self.raw_eof_position();
        None
    }

    /// Build one line from `start..end`; `newline` excludes the terminator.
    fn line_doc(&self, start: usize, end: usize, newline: Option<usize>) -> Doc {
        let text_end = newline.unwrap_or(end);
        let text = String::from_utf8_lossy(&self.inner.buffer[start..text_end]).into_owned();
        let end_index = end.saturating_sub(1);
        let range_index = self
            .inner
            .ranges
            .iter()
            .position(|range| end_index >= range.start && end_index < range.end);
        let (mut source, mut line) = range_index
            .and_then(|index| self.inner.ranges.get(index))
            .map(|range| {
                (
                    range.name.clone(),
                    newline_count(&self.inner.buffer[range.start..end]),
                )
            })
            .unwrap_or_else(|| ("<stdin>".to_string(), 0));
        // An unterminated final line makes jq's reader ask the next operand
        // for the delimiter. When every remaining operand is empty, that open
        // still resets the line counter to 0 and makes the last empty operand
        // the reported source: `a\nb` + empty -> `["b",0]` at `empty:0`, not
        // `["b",1]` at `a:1`. A later non-empty operand would own `end_index`
        // instead, so only empty trailing ranges reach this branch.
        if newline.is_none() {
            if let (Some(index), Some(last)) = (range_index, self.inner.ranges.last()) {
                if index + 1 < self.inner.ranges.len() {
                    source = last.name.clone();
                    line = 0;
                }
            }
        }
        Doc {
            value: Val::utf8_str(text),
            source,
            input_line: line,
        }
    }

    /// Next raw line, or `None` at end of input.
    pub fn next_doc(&mut self) -> Result<Option<Doc>, InputError> {
        if self.finished {
            *self.position.borrow_mut() = self.raw_eof_position();
            return Ok(None);
        }
        if !self.inner.ensure(self.offset)? {
            return Ok(self.finish());
        }
        let start = self.offset;
        let mut index = start;
        loop {
            if !self.inner.ensure(index)? {
                // EOF without a final newline: the bytes seen are the line.
                let end = index;
                if end == start {
                    return Ok(self.finish());
                }
                let doc = self.line_doc(start, end, None);
                self.offset = end;
                self.finished = true;
                *self.position.borrow_mut() = Position {
                    source: Some(doc.source.clone()),
                    line: doc.input_line,
                };
                return Ok(Some(doc));
            }
            if self.inner.buffer[index] == b'\n' {
                let end = index + 1;
                let doc = self.line_doc(start, end, Some(index));
                self.offset = end;
                *self.position.borrow_mut() = Position {
                    source: Some(doc.source.clone()),
                    line: doc.input_line,
                };
                return Ok(Some(doc));
            }
            index += 1;
        }
    }

    /// Every raw byte, for `-R -s`.
    ///
    /// Slurping is eager by definition, so this is the one path that opens
    /// every operand and records each open failure.
    pub fn all_bytes(&mut self) -> Vec<u8> {
        self.inner.load_all();
        *self.position.borrow_mut() = self.inner.final_position();
        self.inner.buffer.clone()
    }

    /// Operand-open failures collected while reading the stream.
    pub fn take_errors(&mut self) -> Vec<InputError> {
        self.inner.take_errors()
    }

    /// Name and line count of the last operand, for `-R -s`.
    fn final_position(&self) -> Position {
        self.inner.final_position()
    }
}

/// The input cursor variant the invocation selected.
pub enum Cursor {
    /// JSON documents.
    Json(InputCursor),
    /// Raw input lines.
    Raw(RawCursor),
    /// The lazy single-document view `-s` installs.
    Slurp(SlurpCursor),
}

impl Cursor {
    /// Build the cursor for one invocation.
    pub fn new(files: &[String], raw: bool) -> Self {
        if raw {
            Self::Raw(RawCursor::new(files))
        } else {
            Self::Json(InputCursor::new(files))
        }
    }

    /// Wrap the cursor in `-s` without opening any operand yet.
    ///
    /// jq's `-s` is lazy with respect to `-n`: `jq -n -s . missing.json`
    /// prints null and exits 0 without touching the file. The input is read
    /// only when the filter asks for its one document.
    pub fn slurp(self) -> Self {
        match self {
            Self::Json(cursor) => Self::Slurp(SlurpCursor::new(SlurpInner::Json(cursor))),
            Self::Raw(cursor) => Self::Slurp(SlurpCursor::new(SlurpInner::Raw(cursor))),
            other => other,
        }
    }

    /// Shared position cell.
    pub fn position(&self) -> Rc<RefCell<Position>> {
        match self {
            Self::Json(cursor) => cursor.position(),
            Self::Raw(cursor) => cursor.position(),
            Self::Slurp(cursor) => cursor.position(),
        }
    }

    /// Parse the next main/consumed input.
    pub fn next_doc(&mut self) -> Result<Option<Doc>, InputError> {
        match self {
            Self::Json(cursor) => cursor.next_doc(),
            Self::Raw(cursor) => cursor.next_doc(),
            Self::Slurp(cursor) => cursor.next_doc(),
        }
    }

    /// Operand-open failures that must be reported after the filter outputs.
    pub fn take_errors(&mut self) -> Vec<InputError> {
        match self {
            Self::Json(cursor) => cursor.take_errors(),
            Self::Raw(cursor) => cursor.take_errors(),
            Self::Slurp(cursor) => cursor.take_errors(),
        }
    }
}

enum SlurpInner {
    Json(InputCursor),
    Raw(RawCursor),
}

/// Lazy `-s`: materialise the whole stream on first use, not at startup.
pub struct SlurpCursor {
    inner: SlurpInner,
    loaded: bool,
    documents: Vec<Doc>,
    next: usize,
    position: Rc<RefCell<Position>>,
}

impl SlurpCursor {
    fn new(inner: SlurpInner) -> Self {
        let position = match &inner {
            SlurpInner::Json(cursor) => cursor.position(),
            SlurpInner::Raw(cursor) => cursor.position(),
        };
        Self {
            inner,
            loaded: false,
            documents: Vec::new(),
            next: 0,
            position,
        }
    }

    fn position(&self) -> Rc<RefCell<Position>> {
        Rc::clone(&self.position)
    }

    fn load(&mut self) -> Result<(), InputError> {
        if self.loaded {
            return Ok(());
        }
        self.loaded = true;
        let (value, source, input_line) = match &mut self.inner {
            SlurpInner::Json(cursor) => {
                let mut values = Vec::new();
                while let Some(doc) = cursor.next_doc()? {
                    values.push(doc.value);
                }
                let position = cursor.final_position();
                (
                    Val::from_iter(values),
                    position.source.clone().unwrap_or_else(|| "<stdin>".to_string()),
                    position.line,
                )
            }
            SlurpInner::Raw(cursor) => {
                let bytes = cursor.all_bytes();
                let position = cursor.final_position();
                (
                    Val::utf8_str(String::from_utf8_lossy(&bytes).into_owned()),
                    position.source.clone().unwrap_or_else(|| "<stdin>".to_string()),
                    position.line,
                )
            }
        };
        self.documents.push(Doc {
            value,
            source: source.clone(),
            input_line,
        });
        *self.position.borrow_mut() = Position {
            source: Some(source),
            line: input_line,
        };
        Ok(())
    }

    fn next_doc(&mut self) -> Result<Option<Doc>, InputError> {
        self.load()?;
        let Some(doc) = self.documents.get(self.next).cloned() else {
            return Ok(None);
        };
        self.next += 1;
        Ok(Some(doc))
    }

    fn take_errors(&mut self) -> Vec<InputError> {
        match &mut self.inner {
            SlurpInner::Json(cursor) => cursor.take_errors(),
            SlurpInner::Raw(cursor) => cursor.take_errors(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static NEXT: AtomicUsize = AtomicUsize::new(0);

    struct TempDir(PathBuf);

    impl TempDir {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "pdsh-jaq-input-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&path).expect("temporary test directory");
            Self(path)
        }

        fn file(&self, name: &str, bytes: &[u8]) -> String {
            let path = self.0.join(name);
            fs::write(&path, bytes).expect("test fixture");
            path.to_string_lossy().into_owned()
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn text(value: &Val) -> String {
        match value {
            Val::TStr(bytes) | Val::BStr(bytes) => {
                String::from_utf8_lossy(bytes).into_owned()
            }
            other => other.to_string(),
        }
    }

    #[test]
    fn raw_lines_restart_the_line_counter_per_operand() {
        let dir = TempDir::new();
        let r1 = dir.file("r1", b"a\nb\n");
        let r2 = dir.file("r2", b"c\nd\n");
        let mut cursor = RawCursor::new(&[r1.clone(), r2.clone()]);
        let mut docs = Vec::new();
        while let Some(doc) = cursor.next_doc().expect("raw stream") {
            docs.push((text(&doc.value), doc.source, doc.input_line));
        }
        assert_eq!(
            docs,
            vec![
                ("a".to_string(), r1.clone(), 1),
                ("b".to_string(), r1, 2),
                ("c".to_string(), r2.clone(), 1),
                ("d".to_string(), r2, 2),
            ]
        );
    }

    #[test]
    fn a_raw_line_crossing_operands_belongs_to_the_ending_source() {
        let dir = TempDir::new();
        let nonl = dir.file("nonl", b"a\nb");
        let r2 = dir.file("r2", b"\nc\n");
        let mut cursor = RawCursor::new(&[nonl, r2.clone()]);
        let mut docs = Vec::new();
        while let Some(doc) = cursor.next_doc().expect("raw stream") {
            docs.push((text(&doc.value), doc.source, doc.input_line));
        }
        assert_eq!(docs[0], ("a".to_string(), docs[0].1.clone(), 1));
        assert_eq!(docs[1].0, "b");
        assert_eq!(docs[1].1, r2);
        assert_eq!(docs[1].2, 1);
        assert_eq!(docs[2].0, "c");
        assert_eq!(docs[2].2, 2);
    }

    #[test]
    fn raw_slurp_reports_the_last_operand_line_count() {
        let dir = TempDir::new();
        let r1 = dir.file("r1", b"a\nb\nc\n");
        let r2 = dir.file("r2", b"d\ne\n");
        let mut cursor = Cursor::new(&[r1, r2], true).slurp();
        let doc = cursor.next_doc().expect("slurped raw input").expect("one doc");
        assert_eq!(text(&doc.value), "a\nb\nc\nd\ne\n");
        assert_eq!(doc.input_line, 2);
        assert_eq!(cursor.position().borrow().line, 2);
    }

    #[test]
    fn raw_slurp_keeps_reading_after_a_missing_operand() {
        let dir = TempDir::new();
        let missing = dir.0.join("missing").to_string_lossy().into_owned();
        let r1 = dir.file("r1", b"a\nb\n");
        let mut cursor = Cursor::new(&[missing, r1], true).slurp();
        assert!(cursor.take_errors().is_empty(), "slurp must not open before use");
        let doc = cursor.next_doc().expect("slurped raw input").expect("one doc");
        assert_eq!(text(&doc.value), "a\nb\n");
        assert_eq!(doc.input_line, 2);
        assert_eq!(cursor.take_errors().len(), 1);
    }

    #[test]
    fn json_slurp_is_lazy_and_keeps_the_empty_result_after_an_open_error() {
        let dir = TempDir::new();
        let missing = dir.0.join("missing").to_string_lossy().into_owned();
        let mut cursor = Cursor::new(&[missing], false).slurp();
        assert!(cursor.take_errors().is_empty(), "slurp must not open before use");
        let doc = cursor.next_doc().expect("slurped JSON input").expect("one doc");
        assert_eq!(doc.value.to_string(), "[]");
        assert_eq!(doc.input_line, 0);
        assert_eq!(cursor.take_errors().len(), 1);
        assert!(cursor.next_doc().expect("end of slurp").is_none());
    }

    #[test]
    fn json_open_errors_do_not_hide_later_operands() {
        let dir = TempDir::new();
        let missing = dir.0.join("missing").to_string_lossy().into_owned();
        let good = dir.file("good", b"1\n2\n");
        let mut cursor = InputCursor::new(&[missing, good]);
        let first = cursor.next_doc().expect("json stream").expect("first doc");
        assert_eq!(first.value.to_string(), "1");
        assert_eq!(cursor.take_errors().len(), 1);
        let second = cursor.next_doc().expect("json stream").expect("second doc");
        assert_eq!(second.value.to_string(), "2");
        assert!(cursor.next_doc().expect("end of stream").is_none());
    }
}

#[cfg(test)]
mod primary_cursor_tests {
    use super::*;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static NEXT: AtomicUsize = AtomicUsize::new(0);

    fn fixture(name: &str, contents: &[u8]) -> PathBuf {
        let unique = NEXT.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "pdsh-jaq-input-{}-{unique}-{name}",
            std::process::id()
        ));
        std::fs::write(&path, contents).expect("write fixture");
        path
    }

    fn text(doc: &Doc) -> String {
        match &doc.value {
            Val::TStr(bytes) => String::from_utf8_lossy(bytes).into_owned(),
            other => format!("{other:?}"),
        }
    }

    fn collect_raw(files: &[String]) -> Vec<(String, String, usize)> {
        collect_raw_with_position(files).0
    }

    fn collect_raw_with_position(files: &[String]) -> (Vec<(String, String, usize)>, Position) {
        let mut cursor = RawCursor::new(files);
        let mut out = Vec::new();
        while let Some(doc) = cursor.next_doc().expect("raw input") {
            out.push((text(&doc), doc.source, doc.input_line));
        }
        let position = cursor.position().borrow().clone();
        (out, position)
    }

    #[test]
    fn raw_multi_file_line_numbers_reset_per_operand() {
        // Native jq 1.6: `jq -R -c '[.,input_line_number]' f1 f2` reports
        // a 1, b 2, c 1, d 2.
        let f1 = fixture("raw-a", b"a\nb\n");
        let f2 = fixture("raw-b", b"c\nd\n");
        let records = collect_raw(&[
            f1.to_string_lossy().into_owned(),
            f2.to_string_lossy().into_owned(),
        ]);
        let expected = vec![
            ("a".to_string(), f1.to_string_lossy().into_owned(), 1),
            ("b".to_string(), f1.to_string_lossy().into_owned(), 2),
            ("c".to_string(), f2.to_string_lossy().into_owned(), 1),
            ("d".to_string(), f2.to_string_lossy().into_owned(), 2),
        ];
        assert_eq!(records, expected);
        let _ = std::fs::remove_file(f1);
        let _ = std::fs::remove_file(f2);
    }

    #[test]
    fn raw_line_across_operand_boundary_uses_the_next_operands_counter() {
        // Native jq 1.6 treats the operands as one byte stream: `a\nb` then
        // `c\nd\n` is `a`, `bc`, `d`; the continued line belongs to the second
        // operand and its line counter starts there (1), not at 2.
        let f1 = fixture("raw-cont-a", b"a\nb");
        let f2 = fixture("raw-cont-b", b"c\nd\n");
        let records = collect_raw(&[
            f1.to_string_lossy().into_owned(),
            f2.to_string_lossy().into_owned(),
        ]);
        let expected = vec![
            ("a".to_string(), f1.to_string_lossy().into_owned(), 1),
            ("bc".to_string(), f2.to_string_lossy().into_owned(), 1),
            ("d".to_string(), f2.to_string_lossy().into_owned(), 2),
        ];
        assert_eq!(records, expected);
        let _ = std::fs::remove_file(f1);
        let _ = std::fs::remove_file(f2);
    }

    #[test]
    fn raw_unterminated_final_line_reports_the_newline_count() {
        // Native jq 1.6 reports `a` 1 and `b` 1 for `a\nb` (no final newline);
        // with the final newline the second line is 2.
        let f1 = fixture("raw-tail", b"a\nb");
        let records = collect_raw(&[f1.to_string_lossy().into_owned()]);
        assert_eq!(records, vec![
            ("a".to_string(), f1.to_string_lossy().into_owned(), 1),
            ("b".to_string(), f1.to_string_lossy().into_owned(), 1),
        ]);
        let _ = std::fs::remove_file(f1);
    }

    #[test]
    fn raw_unterminated_final_line_before_empty_operand_resets_position() {
        // Native jq 1.6: `a\nb` followed by an empty file reports the final
        // continued line as line 0 at the empty operand (`empty:0`), because
        // opening the next operand resets the counter even when it has no
        // bytes. (`a\nb` alone reports line 1 at the first file.)
        let f1 = fixture("raw-tail-empty-a", b"a\nb");
        let empty = fixture("raw-tail-empty-b", b"");
        let records = collect_raw(&[
            f1.to_string_lossy().into_owned(),
            empty.to_string_lossy().into_owned(),
        ]);
        assert_eq!(records, vec![
            ("a".to_string(), f1.to_string_lossy().into_owned(), 1),
            ("b".to_string(), empty.to_string_lossy().into_owned(), 0),
        ]);
        let _ = std::fs::remove_file(f1);
        let _ = std::fs::remove_file(empty);
    }

    #[test]
    fn raw_unterminated_final_line_uses_the_last_empty_operand() {
        // Several trailing empty operands: jq keeps opening them, so the final
        // continued line is attributed to the last one, still at line 0.
        let f1 = fixture("raw-tail-multi-a", b"a\nb");
        let first = fixture("raw-tail-multi-b", b"");
        let last = fixture("raw-tail-multi-c", b"");
        let records = collect_raw(&[
            f1.to_string_lossy().into_owned(),
            first.to_string_lossy().into_owned(),
            last.to_string_lossy().into_owned(),
        ]);
        assert_eq!(records, vec![
            ("a".to_string(), f1.to_string_lossy().into_owned(), 1),
            ("b".to_string(), last.to_string_lossy().into_owned(), 0),
        ]);
        let _ = std::fs::remove_file(f1);
        let _ = std::fs::remove_file(first);
        let _ = std::fs::remove_file(last);
    }

    #[test]
    fn raw_first_line_does_not_open_a_later_missing_operand() {
        // Native jq 1.6: `jq -n -R -c first(inputs) raw1 missing.json` with
        // `raw1 = "a\n"` prints `"a"` and exits 0; the filter never asks for
        // the second line, so the missing operand must not be opened or
        // recorded.
        let f1 = fixture("raw-lazy-first", b"a\n");
        let missing = fixture("raw-lazy-missing", b"");
        std::fs::remove_file(&missing).expect("remove fixture to model a missing operand");
        let missing = missing.to_string_lossy().into_owned();
        let mut cursor = RawCursor::new(&[
            f1.to_string_lossy().into_owned(),
            missing,
        ]);
        let first = cursor.next_doc().expect("raw stream").expect("first line");
        assert_eq!(text(&first), "a");
        assert!(cursor.take_errors().is_empty(), "the later operand was not consumed");
        let _ = std::fs::remove_file(f1);
    }

    #[test]
    fn raw_later_missing_is_reported_when_the_stream_is_consumed() {
        // The negative control: asking for the next line after a terminated
        // first line does open the missing operand and reports it, so the lazy
        // path above is not swallowing a real open error.
        let f1 = fixture("raw-lazy-negative", b"a\n");
        let missing = fixture("raw-lazy-negative-missing", b"");
        std::fs::remove_file(&missing).expect("remove fixture to model a missing operand");
        let mut cursor = RawCursor::new(&[
            f1.to_string_lossy().into_owned(),
            missing.to_string_lossy().into_owned(),
        ]);
        assert_eq!(text(&cursor.next_doc().expect("raw stream").expect("first line")), "a");
        assert!(cursor.next_doc().expect("end of raw stream").is_none());
        assert_eq!(cursor.take_errors().len(), 1);
        let _ = std::fs::remove_file(f1);
    }

    #[test]
    fn json_two_byte_document_does_not_peek_a_later_missing_operand() {
        // Native jq 1.6: `jq -n -c first(inputs) json2 missing.json` with
        // `json2 = "{}"` prints `{}` and exits 0. The old `ensure(2)` BOM peek
        // read the third byte and opened the missing operand for this
        // self-contained document.
        let f1 = fixture("json-lazy-braces", b"{}");
        let missing = fixture("json-lazy-braces-missing", b"");
        std::fs::remove_file(&missing).expect("remove fixture to model a missing operand");
        let mut cursor = InputCursor::new(&[
            f1.to_string_lossy().into_owned(),
            missing.to_string_lossy().into_owned(),
        ]);
        let first = cursor.next_doc().expect("json stream").expect("first doc");
        assert_eq!(first.value.to_string(), "{}");
        assert!(cursor.take_errors().is_empty(), "the later operand was not consumed");
        let _ = std::fs::remove_file(f1);
    }

    #[test]
    fn json_bom_prefix_still_skips_a_self_contained_document_without_peeking_operands() {
        let f1 = fixture("json-lazy-bom", b"\xef\xbb\xbf{}");
        let missing = fixture("json-lazy-bom-missing", b"");
        std::fs::remove_file(&missing).expect("remove fixture to model a missing operand");
        let mut cursor = InputCursor::new(&[
            f1.to_string_lossy().into_owned(),
            missing.to_string_lossy().into_owned(),
        ]);
        let first = cursor.next_doc().expect("json stream").expect("first doc");
        assert_eq!(first.value.to_string(), "{}");
        assert!(cursor.take_errors().is_empty(), "the later operand was not consumed");
        let _ = std::fs::remove_file(f1);
    }

    #[test]
    fn json_number_without_a_delimiter_still_opens_the_next_operand() {
        // jq's number token needs a delimiter. Native jq 1.6 reports the
        // missing operand for `jq -n -c first(inputs) n1 missing.json` when
        // `n1` is just `1` (no newline): preserve that boundary instead of
        // treating laziness as "never open the next operand".
        let f1 = fixture("json-number-no-delimiter", b"1");
        let missing = fixture("json-number-missing", b"");
        std::fs::remove_file(&missing).expect("remove fixture to model a missing operand");
        let mut cursor = InputCursor::new(&[
            f1.to_string_lossy().into_owned(),
            missing.to_string_lossy().into_owned(),
        ]);
        let first = cursor.next_doc().expect("json stream").expect("first doc");
        assert_eq!(first.value.to_string(), "1");
        assert_eq!(cursor.take_errors().len(), 1);
        let _ = std::fs::remove_file(f1);
    }


    #[test]
    fn raw_eof_unterminated_final_line_is_unknown_even_for_whitespace() {
        // Native jq 1.6: `jq -R -n 'inputs, error("boom")'` reports
        // `(at <unknown>)` when the final raw line has no newline, including a
        // whitespace-only final line. JSON's trivia rules must not turn that
        // unterminated raw data into a terminated-looking `file:0`/line count.
        let f1 = fixture("raw-eof-tail-space", b"a\n   ");
        let (records, position) = collect_raw_with_position(&[f1.to_string_lossy().into_owned()]);
        assert_eq!(records.len(), 2);
        assert_eq!(position.source, None);
        assert_eq!(position.line, 0);
        assert_eq!(position.render(), "<unknown>");
        let _ = std::fs::remove_file(f1);

        let spaces = fixture("raw-eof-spaces", b"   ");
        let (records, position) = collect_raw_with_position(&[spaces.to_string_lossy().into_owned()]);
        assert_eq!(records, vec![("   ".to_string(), spaces.to_string_lossy().into_owned(), 0)]);
        assert_eq!(position.source, None);
        assert_eq!(position.render(), "<unknown>");
        let _ = std::fs::remove_file(spaces);
    }

    #[test]
    fn raw_eof_terminated_final_line_reports_its_newline_count() {
        // Native jq 1.6 reports the final newline-terminated operand and the
        // newline count of that operand: `a\nb\n` is `(at f:2)`.
        let f1 = fixture("raw-eof-terminated", b"a\nb\n");
        let (records, position) = collect_raw_with_position(&[f1.to_string_lossy().into_owned()]);
        assert_eq!(records.len(), 2);
        assert_eq!(position.source.as_deref(), Some(f1.to_string_lossy().as_ref()));
        assert_eq!(position.line, 2);
        let _ = std::fs::remove_file(f1);
    }

    #[test]
    fn raw_eof_terminated_line_and_empty_tail_uses_the_last_empty_operand() {
        // Native jq 1.6: `a\n` followed by an empty operand reports the empty
        // operand at line 0, not the non-empty one at line 1.
        let f1 = fixture("raw-eof-empty-line", b"a\n");
        let empty = fixture("raw-eof-empty-tail", b"");
        let (_, position) = collect_raw_with_position(&[
            f1.to_string_lossy().into_owned(),
            empty.to_string_lossy().into_owned(),
        ]);
        assert_eq!(position.source.as_deref(), Some(empty.to_string_lossy().as_ref()));
        assert_eq!(position.line, 0);
        let _ = std::fs::remove_file(f1);
        let _ = std::fs::remove_file(empty);
    }

    #[test]
    fn raw_eof_unterminated_line_and_empty_tail_stays_unknown() {
        // The document attribution still points the continued `b` at the empty
        // operand (`b` at `empty:0`), but the EOF position is unknown because
        // the final non-empty raw line was never terminated. Native jq 1.6:
        // `jq -R -n 'inputs, error("boom")' tail empty` -> `(at <unknown>)`.
        let f1 = fixture("raw-eof-unterminated-tail", b"a\nb");
        let empty = fixture("raw-eof-unterminated-tail-empty", b"");
        let (records, position) = collect_raw_with_position(&[
            f1.to_string_lossy().into_owned(),
            empty.to_string_lossy().into_owned(),
        ]);
        assert_eq!(records, vec![
            ("a".to_string(), f1.to_string_lossy().into_owned(), 1),
            ("b".to_string(), empty.to_string_lossy().into_owned(), 0),
        ]);
        assert_eq!(position.source, None);
        assert_eq!(position.render(), "<unknown>");
        let _ = std::fs::remove_file(f1);
        let _ = std::fs::remove_file(empty);
    }

    #[test]
    fn raw_eof_all_empty_operands_use_the_last_operand() {
        // Native jq 1.6: two empty operands report the last one at line 0.
        let first = fixture("raw-eof-first-empty", b"");
        let last = fixture("raw-eof-last-empty", b"");
        let (_, position) = collect_raw_with_position(&[
            first.to_string_lossy().into_owned(),
            last.to_string_lossy().into_owned(),
        ]);
        assert_eq!(position.source.as_deref(), Some(last.to_string_lossy().as_ref()));
        assert_eq!(position.line, 0);
        let _ = std::fs::remove_file(first);
        let _ = std::fs::remove_file(last);
    }

    #[test]
    fn raw_eof_unterminated_line_completed_by_later_operand_uses_that_operand() {
        // `a` (no newline) then a one-newline operand is the single raw line
        // `a`; native jq 1.6 reports EOF at the second operand, line 1.
        let f1 = fixture("raw-eof-continued-a", b"a");
        let f2 = fixture("raw-eof-continued-b", b"\n");
        let (records, position) = collect_raw_with_position(&[
            f1.to_string_lossy().into_owned(),
            f2.to_string_lossy().into_owned(),
        ]);
        assert_eq!(records, vec![("a".to_string(), f2.to_string_lossy().into_owned(), 1)]);
        assert_eq!(position.source.as_deref(), Some(f2.to_string_lossy().as_ref()));
        assert_eq!(position.line, 1);
        let _ = std::fs::remove_file(f1);
        let _ = std::fs::remove_file(f2);
    }

    #[test]
    fn raw_eof_unreadable_tail_uses_its_zero_position() {
        // Native jq 1.6 opens the unreadable operand at EOF and reports its
        // `missing:0` marker even after an unterminated raw line; the open
        // error itself is still collected and exits 2.
        let f1 = fixture("raw-eof-missing-tail", b"a");
        let missing = fixture("raw-eof-missing-tail-missing", b"");
        std::fs::remove_file(&missing).expect("remove fixture to model a missing operand");
        let (_, position) = collect_raw_with_position(&[
            f1.to_string_lossy().into_owned(),
            missing.to_string_lossy().into_owned(),
        ]);
        assert_eq!(position.source.as_deref(), Some(missing.to_string_lossy().as_ref()));
        assert_eq!(position.line, 0);
        let _ = std::fs::remove_file(f1);
    }

    #[test]
    fn raw_slurp_position_is_the_last_operand_newline_count() {
        let f1 = fixture("raw-slurp-a", b"a\nb\nc\n");
        let f2 = fixture("raw-slurp-b", b"d\ne\n");
        let mut cursor = Cursor::new(&[
            f1.to_string_lossy().into_owned(),
            f2.to_string_lossy().into_owned(),
        ], true).slurp();
        let doc = cursor.next_doc().expect("raw bytes").expect("slurped document");
        assert_eq!(text(&doc).as_bytes(), b"a\nb\nc\nd\ne\n");
        let position = cursor.position().borrow().clone();
        assert_eq!(position.source.as_deref(), Some(f2.to_string_lossy().as_ref()));
        assert_eq!(position.line, 2);
        let _ = std::fs::remove_file(f1);
        let _ = std::fs::remove_file(f2);
    }
}
