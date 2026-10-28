// SPDX-License-Identifier: MIT
//! `jq`-compatible WASI executable for the phone-dsh Worker.
//!
//! This is a real input-language engine, not a token rewriter: the filter is
//! parsed and compiled by `jaq-core` with the MIT `jaq-std`/`jaq-json`
//! definitions, so scopes, `reduce`/`foreach`, `break`, function arguments and
//! lazy generation are the engine's semantics. What this crate adds is the jq
//! input contract the Worker needs:
//!
//! - `input` consumes the next document and raises jq's `break` at EOF;
//! - `inputs` yields every remaining document lazily;
//! - `input_line_number` tracks jq 1.6's `fgets` line count;
//! - `$ARGS`, `$ENV` and `$__loc__` are real bindings;
//! - files are read through WASI's preopened Worker VFS, stdin is the
//!   Worker-delivered stream, and stdout/stderr are ordinary file writes.
//!
//! It deliberately does not claim complete jq compatibility: the engine
//! identity and the remaining deviations are documented in
//! `plugins/wasi-toolbox/jq/README.md` and `plugins/THIRD_PARTY.md`.

mod args;
mod input;

use std::cell::RefCell;
use std::io::{Read, Write};
use std::rc::Rc;

use args::{ArgsMode, Cli};
use input::{resolve_guest_path, Cursor, InputError, Position};
use jaq_core::data::HasLut;
use jaq_core::load::{Arena, File, Loader};
use jaq_core::{Compiler, Ctx as JaqCtx, DataT, Error, Exn, Native, Vars};
use jaq_json::{Map, Val};
use jaq_std::input::{HasInputs, Inputs, RcIter};

/// jq 1.6 usage error.
const EXIT_USAGE: i32 = 2;
/// jq 1.6 filter compile error.
const EXIT_COMPILE: i32 = 3;
/// jq 1.6 `-e` with no output.
const EXIT_NO_OUTPUT: i32 = 4;
/// jq 1.6 runtime or input error.
const EXIT_RUNTIME: i32 = 5;

const HELP: &str = "\
jq - commandline JSON processor [version 1.6]

Usage:  jq [options...] filter [files...]

Options:
  -c, --compact-output     compact instead of pretty-printed output
  -r, --raw-output         output strings without quotes
  -j, --join-output        no newline after each output
  -n, --null-input         use null as the single input value
  -s, --slurp              read all inputs into an array
  -R, --raw-input          read raw strings, not JSON texts
  -e, --exit-status        set exit status based on the last output
  -S, --sort-keys          sort object keys
  -a, --ascii-output       escape non-ASCII characters
      --tab                indent with tabs
      --indent N           indent with N spaces
      --arg NAME VALUE     bind $NAME to a string
      --argjson NAME JSON  bind $NAME to a JSON value
      --rawfile NAME FILE  bind $NAME to the raw file contents
      --slurpfile NAME FILE bind $NAME to the file's JSON values as an array
      --args               remaining words are $ARGS.positional strings
      --jsonargs           remaining words are $ARGS.positional JSON values
  -h, --help               show this help
      --version            show the version
";

/// One run of the engine, including how the input layer failed.
enum Failure {
    /// A filter runtime error.
    Value(String),
    /// jq's `break` after an exhausted `input`.
    Break,
    /// `halt`/`halt_error` with an explicit status.
    Halt(i32),
    /// The input layer failed (parse/open) and carries its own exit status.
    Input(InputError),
}

/// The binding set and the matching global-variable names.
struct Bindings {
    names: Vec<String>,
    values: Vec<Val>,
}

/// Input provider shared by the main loop and `input`/`inputs`.
struct InputValues {
    cursor: Rc<RefCell<Cursor>>,
    failed: bool,
}

impl Iterator for InputValues {
    // `jaq_std::input::Inputs` fixes this error channel to `String`. The string
    // is the real jq error value (parse message or "break"), never a marker we
    // decode later; the native filters below turn it back into a real
    // `Error<Val>` so jaq's `try`/`catch` sees exactly what jq exposes.
    type Item = Result<Val, String>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.failed {
            return None;
        }
        match self.cursor.borrow_mut().next_doc() {
            Ok(Some(doc)) => Some(Ok(doc.value)),
            Ok(None) => None,
            Err(error) => {
                self.failed = true;
                // A parse error is an ordinary jq error *value*: `catch` gets
                // the message string and an uncaught one is a runtime error
                // (exit 5), exactly like native jq's input callback.
                Some(Err(error_payload(&error)))
            }
        }
    }
}

fn error_payload(error: &InputError) -> String {
    match error {
        InputError::Parse { message } => message.clone(),
        other => other.to_string(),
    }
}

/// Runtime data the jaq native filters see.
#[derive(Clone)]
struct InputData<'a> {
    lut: &'a jaq_core::Lut<InputsData>,
    inputs: Inputs<'a, Val>,
    position: Rc<RefCell<Position>>,
}

/// Marker type selecting the value/data families for `jaq_core`.
struct InputsData;

impl DataT for InputsData {
    type V<'a> = Val;
    type Data<'a> = InputData<'a>;
}

impl<'a> HasLut<'a, InputsData> for InputData<'a> {
    fn lut(&self) -> &'a jaq_core::Lut<InputsData> {
        self.lut
    }
}

impl<'a> HasInputs<'a, Val> for InputData<'a> {
    fn inputs(&self) -> Inputs<'a, Val> {
        self.inputs
    }
}

type Filter = jaq_core::Filter<InputsData>;

fn input_fun() -> jaq_core::native::Fun<InputsData> {
    (
        "input",
        jaq_core::native::v(0),
        Native::new(|cv: jaq_core::Cv<'_, InputsData>| {
            let mut inputs = cv.0.data().inputs();
            match inputs.next() {
                Some(Ok(value)) => jaq_core::box_iter::box_once(Ok(value)),
                Some(Err(message)) => jaq_core::box_iter::box_once(Err(Exn::from(Error::new(
                    Val::utf8_str(message),
                )))),
                None => jaq_core::box_iter::box_once(Err(Exn::from(Error::new(Val::utf8_str(
                    "break",
                ))))),
            }
        }),
    )
}

fn inputs_fun() -> jaq_core::native::Fun<InputsData> {
    (
        "inputs",
        jaq_core::native::v(0),
        Native::new(|cv: jaq_core::Cv<'_, InputsData>| {
            let inputs = cv.0.data().inputs();
            Box::new(inputs.map(|result| {
                result.map_err(|message| Exn::from(Error::new(Val::utf8_str(message))))
            }))
        }),
    )
}

fn line_fun() -> jaq_core::native::Fun<InputsData> {
    (
        "input_line_number",
        jaq_core::native::v(0),
        Native::new(|cv: jaq_core::Cv<'_, InputsData>| {
            let line = cv.0.data().position.borrow().line;
            jaq_core::box_iter::box_once(Ok(Val::from(line)))
        }),
    )
}

fn compile_filter(code: &str, globals: &[String]) -> Result<Filter, String> {
    let defs = jaq_core::defs()
        .chain(jaq_std::defs())
        .chain(jaq_json::defs());
    let funs: Vec<jaq_core::native::Fun<InputsData>> = jaq_core::funs()
        .chain(jaq_std::funs())
        .chain(jaq_json::funs())
        .filter(|(name, _, _)| !matches!(*name, "input" | "inputs" | "input_line_number"))
        .chain([input_fun(), inputs_fun(), line_fun()])
        .collect();
    let arena = Arena::default();
    let loader = Loader::new(defs);
    let modules = loader
        .load(&arena, File { code, path: () })
        .map_err(|errors| describe_load_errors(&errors))?;
    jaq_core::load::import(&modules, |_path| Err("file loading is not supported".into()))
        .map_err(|errors| describe_load_errors(&errors))?;
    let globals: Vec<String> = globals.iter().map(|name| format!("${name}")).collect();
    Compiler::default()
        .with_funs(funs)
        .with_global_vars(globals.iter().map(String::as_str))
        .compile(modules)
        .map_err(|errors| describe_compile_errors(&errors))
}

fn describe_load_errors<P: std::fmt::Debug>(
    errors: &[(File<&str, P>, jaq_core::load::Error<&str>)],
) -> String {
    let mut messages = Vec::new();
    for (file, error) in errors {
        let detail = match error {
            jaq_core::load::Error::Io(errors) => format!("could not load module: {errors:?}"),
            jaq_core::load::Error::Lex(errors) => format!("invalid syntax: {errors:?}"),
            jaq_core::load::Error::Parse(errors) => format!("parse error: {errors:?}"),
        };
        messages.push(format!("in filter {:?}: {detail}", file.code));
    }
    messages.join("\n")
}

fn describe_compile_errors<P: std::fmt::Debug>(
    errors: &[(File<&str, P>, Vec<jaq_core::compile::Error<&str>>)],
) -> String {
    let mut messages = Vec::new();
    for (file, errors) in errors {
        for error in errors {
            messages.push(format!("in filter {:?}: {error:?}", file.code));
        }
    }
    messages.join("\n")
}

fn main() {
    let code = run();
    std::process::exit(code);
}

fn run() -> i32 {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let cli = match args::parse(&argv) {
        Ok(cli) => cli,
        Err(error) => {
            let _ = writeln!(std::io::stderr(), "{error}");
            return EXIT_USAGE;
        }
    };
    if cli.help {
        let _ = std::io::stdout().write_all(HELP.as_bytes());
        return 0;
    }
    if cli.version {
        // Keep the `jq-1.6` compatibility prefix scripts probe for, but never
        // hide the real engine: this is jaq's language core, not jq's binary.
        let _ = writeln!(
            std::io::stdout(),
            "jq-1.6 (pdsh-jaq-wasm; jaq-core 3.1.2 + jaq-std 3.0.4 + jaq-json 2.0.3; jq-1.6-compatible interface)"
        );
        return 0;
    }
    let filter_code = rewrite_location(&cli.filter.clone().unwrap_or_default());
    let bindings = match build_bindings(&cli) {
        Ok(bindings) => bindings,
        Err(code) => return code,
    };
    let filter = match compile_filter(&filter_code, &bindings.names) {
        Ok(filter) => filter,
        Err(message) => {
            let _ = writeln!(std::io::stderr(), "jq: error: {message}");
            return EXIT_COMPILE;
        }
    };

    let mut cursor = Cursor::new(&cli.files, cli.raw_input);
    if cli.slurp {
        // `-s` is deferred: `-n` must not open any operand at all.
        cursor = cursor.slurp();
    }
    let position = cursor.position();
    let cursor = Rc::new(RefCell::new(cursor));
    let input_iter = RcIter::new(InputValues {
        cursor: Rc::clone(&cursor),
        failed: false,
    });
    let data = InputData {
        lut: &filter.lut,
        inputs: &input_iter,
        position: Rc::clone(&position),
    };
    let printer = Printer::new(&cli);
    let mut last: Option<bool> = None;
    let mut evaluated = 0usize;
    let mut failure: Option<Failure> = None;

    if cli.null_input {
        evaluated = 1;
        failure = evaluate(
            &filter,
            &data,
            &bindings.values,
            Val::Null,
            &printer,
            &mut last,
            &position,
        )
        .err();
    } else {
        loop {
            let doc = match cursor.borrow_mut().next_doc() {
                Ok(Some(doc)) => doc,
                Ok(None) => break,
                Err(error) => {
                    failure = Some(Failure::Input(error));
                    break;
                }
            };
            evaluated += 1;
            if let Err(error) = evaluate(
                &filter,
                &data,
                &bindings.values,
                doc.value,
                &printer,
                &mut last,
                &position,
            ) {
                failure = Some(error);
                break;
            }
        }
    }

    let _ = std::io::stdout().flush();
    let mut code = if let Some(failure) = failure {
        report(failure, &position)
    } else if cli.exit_status {
        if evaluated == 0 {
            // jq 1.6 does not enter the filter at all when a non-null
            // invocation has no input document.
            0
        } else {
            match last {
                Some(true) => 0,
                Some(false) => 1,
                None => EXIT_NO_OUTPUT,
            }
        }
    } else {
        0
    };

    // jq prints an unreadable operand but keeps reading the remaining ones and
    // still exits 2, even if the filter produced output or a later failure.
    let errors = cursor.borrow_mut().take_errors();
    if !errors.is_empty() {
        for error in &errors {
            let _ = writeln!(std::io::stderr(), "{error}");
        }
        code = EXIT_USAGE;
    }
    code
}

fn evaluate(
    filter: &Filter,
    data: &InputData<'_>,
    values: &[Val],
    input: Val,
    printer: &Printer,
    last: &mut Option<bool>,
    position: &Rc<RefCell<Position>>,
) -> Result<(), Failure> {
    let context: JaqCtx<'_, InputsData> = JaqCtx::new(data.clone(), Vars::new(values.to_vec()));
    for output in filter.id.run((context, input)) {
        match output {
            Ok(value) => {
                *last = Some(truthy(&value));
                if let Err(error) = printer.write(&value) {
                    return Err(Failure::Value(error));
                }
            }
            Err(exception) => {
                let error = match exception.get_err() {
                    Ok(error) => error,
                    Err(exception) => {
                        return match exception.get_halt() {
                            Ok(code) => Err(Failure::Halt(code)),
                            Err(_) => Err(Failure::Value("uncaught exception".to_string())),
                        }
                    }
                };
                let value = error.into_val();
                if matches!(&value, Val::TStr(bytes) | Val::BStr(bytes) if bytes.as_ref() == &b"break"[..])
                {
                    return Err(Failure::Break);
                }
                return Err(Failure::Value(display_error_value(value)));
            }
        }
    }
    let _ = position;
    Ok(())
}

fn display_error_value(value: Val) -> String {
    match value {
        Val::TStr(bytes) | Val::BStr(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
        other => other.to_string(),
    }
}

fn truthy(value: &Val) -> bool {
    !matches!(value, Val::Null | Val::Bool(false))
}

fn report(failure: Failure, position: &Rc<RefCell<Position>>) -> i32 {
    let at = position.borrow().render();
    match failure {
        Failure::Break => {
            let _ = writeln!(std::io::stderr(), "jq: error (at {at}): break");
            EXIT_RUNTIME
        }
        Failure::Halt(code) => code,
        Failure::Input(error) => {
            let _ = writeln!(std::io::stderr(), "{error}");
            error.exit_code()
        }
        Failure::Value(message) => {
            let _ = writeln!(std::io::stderr(), "jq: error (at {at}): {message}");
            EXIT_RUNTIME
        }
    }
}

/// Replace every real `$__loc__` reference with the object literal jq binds at
/// that source position. The scan skips ordinary string contents and comments,
/// but keeps looking inside `\( ... )` interpolations. Positions are counted
/// in the original source, so an inserted literal (which contains no newline)
/// cannot shift a later reference.
fn rewrite_location(code: &str) -> String {
    #[derive(Clone, Copy)]
    enum Mode {
        Code,
        String,
        Comment,
        Interp(usize),
    }

    let bytes = code.as_bytes();
    let mut out = String::with_capacity(code.len());
    let mut stack = vec![Mode::Code];
    let mut line = 1usize;
    let mut index = 0usize;
    let marker = b"$__loc__";
    while index < bytes.len() {
        let byte = bytes[index];
        if byte >= 0x80 {
            let character = code[index..].chars().next().expect("valid UTF-8 source");
            out.push(character);
            index += character.len_utf8();
            continue;
        }
        let mode = *stack.last().expect("mode stack is never empty");
        match mode {
            Mode::Comment => {
                out.push(byte as char);
                if byte == b'\n' {
                    line += 1;
                    stack.pop();
                }
                index += 1;
            }
            Mode::String => {
                if byte == b'\\' && index + 1 < bytes.len() {
                    out.push('\\');
                    let next = bytes[index + 1];
                    if next >= 0x80 {
                        let character = code[index + 1..].chars().next().expect("valid UTF-8");
                        out.push(character);
                        index += 1 + character.len_utf8();
                    } else {
                        out.push(next as char);
                        if next == b'(' {
                            stack.push(Mode::Interp(1));
                        }
                        index += 2;
                    }
                } else {
                    out.push(byte as char);
                    if byte == b'"' {
                        stack.pop();
                    } else if byte == b'\n' {
                        line += 1;
                    }
                    index += 1;
                }
            }
            Mode::Interp(depth) => {
                if byte == b'#' {
                    stack.push(Mode::Comment);
                    out.push('#');
                    index += 1;
                } else if byte == b'"' {
                    stack.push(Mode::String);
                    out.push('"');
                    index += 1;
                } else if byte == b'(' {
                    stack.pop();
                    stack.push(Mode::Interp(depth + 1));
                    out.push('(');
                    index += 1;
                } else if byte == b')' {
                    stack.pop();
                    if depth > 1 {
                        stack.push(Mode::Interp(depth - 1));
                    }
                    out.push(')');
                    index += 1;
                } else if let Some(end) = location_at(bytes, index, marker) {
                    out.push_str(&format!(
                        "{{\"file\":\"<top-level>\",\"line\":{line}}}"
                    ));
                    index = end;
                } else {
                    if byte == b'\n' {
                        line += 1;
                    }
                    out.push(byte as char);
                    index += 1;
                }
            }
            Mode::Code => {
                if byte == b'#' {
                    stack.push(Mode::Comment);
                    out.push('#');
                    index += 1;
                } else if byte == b'"' {
                    stack.push(Mode::String);
                    out.push('"');
                    index += 1;
                } else if let Some(end) = location_at(bytes, index, marker) {
                    out.push_str(&format!(
                        "{{\"file\":\"<top-level>\",\"line\":{line}}}"
                    ));
                    index = end;
                } else {
                    if byte == b'\n' {
                        line += 1;
                    }
                    out.push(byte as char);
                    index += 1;
                }
            }
        }
    }
    out
}

fn location_at(bytes: &[u8], index: usize, marker: &[u8]) -> Option<usize> {
    if !bytes[index..].starts_with(marker) {
        return None;
    }
    let end = index + marker.len();
    match bytes.get(end) {
        Some(byte) if byte.is_ascii_alphanumeric() || *byte == b'_' => None,
        _ => Some(end),
    }
}

fn build_bindings(cli: &Cli) -> Result<Bindings, i32> {
    let mut entries: Vec<(String, Val)> = Vec::new();
    for (name, value) in &cli.args {
        entries.push((name.clone(), Val::utf8_str(value.clone())));
    }
    for (name, text) in &cli.argjson {
        match jaq_json::read::parse_single(text.as_bytes()) {
            Ok(mut value) => {
                sanitize_value(&mut value);
                entries.push((name.clone(), value));
            }
            Err(error) => {
                let _ = writeln!(
                    std::io::stderr(),
                    "jq: invalid JSON text passed to --argjson {name}: {error}"
                );
                return Err(EXIT_USAGE);
            }
        }
    }
    for binding in &cli.rawfiles {
        match std::fs::read(resolve_guest_path(&binding.path)) {
            Ok(bytes) => entries.push((
                binding.name.clone(),
                Val::utf8_str(String::from_utf8_lossy(&bytes).into_owned()),
            )),
            Err(error) => {
                let _ = writeln!(
                    std::io::stderr(),
                    "jq: Bad JSON in --rawfile {} {}: Could not open {}: {}",
                    binding.name,
                    binding.path,
                    binding.path,
                    error
                );
                return Err(EXIT_USAGE);
            }
        }
    }
    for binding in &cli.slurpfiles {
        match std::fs::read(resolve_guest_path(&binding.path)) {
            Ok(bytes) => {
                let mut values = Vec::new();
                for value in jaq_json::read::parse_many(&bytes) {
                    match value {
                        Ok(mut value) => {
                            sanitize_value(&mut value);
                            values.push(value);
                        }
                        Err(error) => {
                            let _ = writeln!(
                                std::io::stderr(),
                                "jq: Bad JSON in --slurpfile {} {}: {error}",
                                binding.name,
                                binding.path
                            );
                            return Err(EXIT_USAGE);
                        }
                    }
                }
                entries.push((binding.name.clone(), Val::from_iter(values)));
            }
            Err(error) => {
                let _ = writeln!(
                    std::io::stderr(),
                    "jq: Bad JSON in --slurpfile {} {}: Could not open {}: {}",
                    binding.name,
                    binding.path,
                    binding.path,
                    error
                );
                return Err(EXIT_USAGE);
            }
        }
    }

    let positional: Vec<Val> = match cli.args_mode {
        None => Vec::new(),
        Some(ArgsMode::Strings) => cli
            .positional
            .iter()
            .map(|value| Val::utf8_str(value.clone()))
            .collect(),
        Some(ArgsMode::Json) => {
            let mut values = Vec::new();
            for text in &cli.positional {
                match jaq_json::read::parse_single(text.as_bytes()) {
                    Ok(mut value) => {
                        sanitize_value(&mut value);
                        values.push(value);
                    }
                    Err(error) => {
                        let _ = writeln!(
                            std::io::stderr(),
                            "jq: invalid JSON text passed to --jsonargs: {error}"
                        );
                        return Err(EXIT_USAGE);
                    }
                }
            }
            values
        }
    };
    let mut named = Map::default();
    for (name, value) in &entries {
        named.insert(Val::utf8_str(name.clone()), value.clone());
    }
    let mut args_object = Map::default();
    args_object.insert(
        Val::utf8_str("positional"),
        Val::from_iter(positional),
    );
    args_object.insert(Val::utf8_str("named"), Val::obj(named));
    entries.push(("ARGS".to_string(), Val::obj(args_object)));

    let mut env = Map::default();
    for (name, value) in std::env::vars() {
        env.insert(Val::utf8_str(name), Val::utf8_str(value));
    }
    entries.push(("ENV".to_string(), Val::obj(env)));

    let mut unique: Vec<(String, Val)> = Vec::new();
    for (name, value) in entries {
        if let Some(existing) = unique.iter_mut().find(|(known, _)| *known == name) {
            existing.1 = value;
        } else {
            unique.push((name, value));
        }
    }
    let mut names = Vec::with_capacity(unique.len());
    let mut values = Vec::with_capacity(unique.len());
    for (name, value) in unique {
        names.push(name);
        values.push(value);
    }
    Ok(Bindings { names, values })
}

fn sanitize_value(value: &mut Val) {
    match value {
        Val::TStr(bytes) => {
            *value = Val::utf8_str(String::from_utf8_lossy(bytes).into_owned());
        }
        Val::Arr(items) => {
            for item in std::rc::Rc::make_mut(items) {
                sanitize_value(item);
            }
        }
        Val::Obj(map) => {
            let map = std::rc::Rc::make_mut(map);
            let entries: Vec<(Val, Val)> = map.drain(..).collect();
            for (mut key, mut value) in entries {
                sanitize_value(&mut key);
                sanitize_value(&mut value);
                map.insert(key, value);
            }
        }
        _ => {}
    }
}

/// Output formatter for one invocation.
struct Printer {
    pp: jaq_json::write::Pp,
    raw: bool,
    join: bool,
    ascii: bool,
}

impl Printer {
    fn new(cli: &Cli) -> Self {
        let indent = if cli.compact {
            None
        } else if cli.tab {
            Some("\t".to_string())
        } else {
            Some(" ".repeat(cli.indent.unwrap_or(2)))
        };
        Self {
            pp: jaq_json::write::Pp {
                indent,
                sort_keys: cli.sort_keys,
                styles: jaq_json::write::Styles::default(),
                sep_space: !cli.compact,
            },
            raw: cli.raw_output,
            join: cli.join_output,
            ascii: cli.ascii_output,
        }
    }

    fn write(&self, value: &Val) -> Result<(), String> {
        let mut stdout = std::io::stdout().lock();
        if self.raw {
            if let Val::TStr(bytes) | Val::BStr(bytes) = value {
                stdout
                    .write_all(bytes)
                    .map_err(|error| error.to_string())?;
                if !self.join {
                    stdout.write_all(b"\n").map_err(|error| error.to_string())?;
                }
                return Ok(());
            }
        }
        if self.ascii {
            let mut buffer = Vec::new();
            jaq_json::write::write(&mut buffer, &self.pp, 0, value)
                .map_err(|error| error.to_string())?;
            let escaped = ascii_escape(&buffer);
            stdout
                .write_all(&escaped)
                .map_err(|error| error.to_string())?;
        } else {
            jaq_json::write::write(&mut stdout, &self.pp, 0, value)
                .map_err(|error| error.to_string())?;
        }
        if !self.join {
            stdout.write_all(b"\n").map_err(|error| error.to_string())?;
        }
        Ok(())
    }
}

/// Escape non-ASCII characters in already-serialised JSON.
fn ascii_escape(bytes: &[u8]) -> Vec<u8> {
    let text = String::from_utf8_lossy(bytes);
    let mut out = Vec::with_capacity(bytes.len());
    for character in text.chars() {
        if character.is_ascii() {
            out.push(character as u8);
            continue;
        }
        let mut units = [0u16; 2];
        for unit in character.encode_utf16(&mut units) {
            out.extend_from_slice(format!("\\u{unit:04x}").as_bytes());
        }
    }
    out
}

// Keep `Read` in scope for the stdin path in `input` and avoid an unused
// import warning when a host builds the binary without a stdin read.
#[allow(dead_code)]
fn read_all(mut source: impl Read) -> std::io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    source.read_to_end(&mut bytes)?;
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::rewrite_location;

    #[test]
    fn location_uses_the_reference_line() {
        assert_eq!(
            rewrite_location("$__loc__"),
            "{\"file\":\"<top-level>\",\"line\":1}"
        );
        assert_eq!(
            rewrite_location("1,\n$__loc__"),
            "1,\n{\"file\":\"<top-level>\",\"line\":2}"
        );
        assert_eq!(
            rewrite_location("def f:\n  $__loc__;\n[f, f]"),
            "def f:\n  {\"file\":\"<top-level>\",\"line\":2};\n[f, f]"
        );
        assert_eq!(
            rewrite_location("1 |\n# comment\n$__loc__"),
            "1 |\n# comment\n{\"file\":\"<top-level>\",\"line\":3}"
        );
    }

    #[test]
    fn location_skips_strings_and_similar_variables_but_not_interpolation() {
        assert_eq!(
            rewrite_location("\"$__loc__\""),
            "\"$__loc__\"",
            "a plain string literal is data, not the special variable"
        );
        assert_eq!(
            rewrite_location("# $__loc__\n$__loc__"),
            "# $__loc__\n{\"file\":\"<top-level>\",\"line\":2}"
        );
        assert_eq!(
            rewrite_location("$__loc__x"),
            "$__loc__x",
            "a longer variable name is not the special variable"
        );
        assert_eq!(
            rewrite_location("\"x\\($__loc__)\""),
            "\"x\\({\"file\":\"<top-level>\",\"line\":1})\""
        );
        assert_eq!(
            rewrite_location("\"é\\\\\\(1)\""),
            "\"é\\\\\\(1)\"",
            "non-ASCII string bytes and escaped backslashes survive the scan"
        );
    }
}
