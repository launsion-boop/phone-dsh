// SPDX-License-Identifier: MIT
//! `jaq` (also registered as `jq`): a jq-compatible read-only filter
//! accelerator.
//!
//! The filter is compiled with `jaq-core` and the `jaq-std` / `jaq-json`
//! definitions, so the jq language surface (`.a.b`, `.[]`, `select`, `map`,
//! `keys`, `to_entries`, `@base64`, string interpolation, …) comes from jaq.
//! Input files are read through the [`pdsh_core::Vfs`] sandbox; output is emitted
//! through [`pdsh_core::Ctx::emit_stdout`], so the core's output budget and
//! cancellation apply. This accelerator never writes a file.
//!
//! Exit codes follow jq: 0 on success, 1 for `-e` with a false/null (or no)
//! last output, 2 for a usage error, 3 for a compile error, 5 for a runtime,
//! input or I/O error, 4 for `-e` with no output, and the pdsh-core 130 when
//! cancelled.

pub mod args;

use std::io::{self, Read, Write};

use jaq_core::load::{Arena, File, Loader};
use jaq_core::{data::JustLut, Compiler, Ctx as JaqCtx, ValT, Vars};
use jaq_json::Val;
use pdsh_core::{Command, Ctx, Error, EXIT_CANCELLED};

use crate::args::Indent;

/// Exit code for a false/null last output with `-e`.
pub const EXIT_FALSE_OR_NULL: i32 = 1;
/// Exit code for a usage error.
pub const EXIT_USAGE: i32 = 2;
/// Exit code for a filter compile error.
pub const EXIT_COMPILE: i32 = 3;
/// Exit code for `-e` with no output at all.
pub const EXIT_NO_OUTPUT: i32 = 4;
/// Exit code for a runtime or input error.
pub const EXIT_RUNTIME: i32 = 5;

const HELP: &str = "\
jaq (pdsh-shell read-only accelerator; jq-compatible)

USAGE:
    jaq [OPTIONS] FILTER [FILE ...]

OPTIONS:
    -r, --raw-output        write strings without JSON quotes
    -c, --compact-output    write one JSON value per line
    -s, --slurp             read all inputs into one array
    -e, --exit-status       exit 1 when the last output is false or null
    -n, --null-input        use null as the only input; read no files
        --arg NAME VALUE    bind $NAME to a string
        --argjson NAME JSON bind $NAME to a JSON value
        --tab               indent with tabs
        --indent N          indent with N spaces (default 2)
    -h, --help              print this help
        --version           print the version
";

/// One jq-compatible accelerator. The command name is either `jaq` or `jq`.
#[derive(Debug, Clone)]
pub struct JaqCommand {
    name: &'static str,
}

impl JaqCommand {
    /// Create the command under the given accelerator name (`jaq` or `jq`).
    pub fn new(name: &'static str) -> Self {
        JaqCommand { name }
    }
}

impl Default for JaqCommand {
    fn default() -> Self {
        JaqCommand::new("jaq")
    }
}

impl Command for JaqCommand {
    fn name(&self) -> &str {
        self.name
    }

    fn run(&self, argv: &[String], ctx: &mut Ctx<'_>) -> i32 {
        run_jaq(argv, ctx)
    }
}

/// Run one `jaq` invocation against the sandboxed context.
pub fn run_jaq(argv: &[String], ctx: &mut Ctx<'_>) -> i32 {
    run_jaq_with_input(argv, ctx, None)
}

/// Run one `jaq` invocation with an explicit standard-input byte slice.
///
/// `input` of `None` reads the host process's standard input when a filter is
/// run without file arguments; tests and the FFI can supply bytes instead.
pub fn run_jaq_with_input(argv: &[String], ctx: &mut Ctx<'_>, input: Option<&[u8]>) -> i32 {
    match execute(argv, ctx, input) {
        Ok(code) => code,
        Err(Error::Cancelled) => EXIT_CANCELLED,
        Err(error) => {
            let _ = ctx.emit_stderr_str(&format!("jaq: {error}\n"));
            EXIT_RUNTIME
        }
    }
}

fn execute(argv: &[String], ctx: &mut Ctx<'_>, input: Option<&[u8]>) -> Result<i32, Error> {
    let cli = match args::parse(argv) {
        Ok(cli) => cli,
        Err(message) => {
            ctx.emit_stderr_str(&format!("jaq: {message}\n"))?;
            return Ok(EXIT_USAGE);
        }
    };
    if cli.help {
        ctx.emit_stdout_str(HELP)?;
        return Ok(0);
    }
    if cli.version {
        ctx.emit_stdout_str(&format!("jaq {} (pdsh-shell)\n", pdsh_core::VERSION))?;
        return Ok(0);
    }
    let filter_code = match &cli.filter {
        Some(filter) => filter.clone(),
        None => {
            ctx.emit_stderr_str("jaq: missing filter expression\n")?;
            return Ok(EXIT_USAGE);
        }
    };

    // `--argjson` values are parsed before compilation so a bad JSON value is
    // reported even when the filter never references the binding.
    let mut bindings: Vec<(String, Val)> = Vec::new();
    for (name, value) in &cli.args {
        bindings.push((name.clone(), Val::utf8_str(value.clone())));
    }
    for (name, value) in &cli.argjson {
        match jaq_json::read::parse_single(value.as_bytes()) {
            Ok(value) => bindings.push((name.clone(), value)),
            Err(error) => {
                ctx.emit_stderr_str(&format!(
                    "jaq: invalid JSON for --argjson {name}: {error}\n"
                ))?;
                return Ok(EXIT_RUNTIME);
            }
        }
    }
    if cli.null_input {
        bindings.push(("ARGS".to_string(), args_object(&bindings, &cli)));
        bindings.push(("ENV".to_string(), Val::obj(Default::default())));
    } else {
        bindings.push(("ARGS".to_string(), args_object(&bindings, &cli)));
        bindings.push(("ENV".to_string(), Val::obj(Default::default())));
    }
    dedupe_bindings(&mut bindings);
    let var_names: Vec<String> = bindings.iter().map(|(name, _)| name.clone()).collect();
    let var_values: Vec<Val> = bindings.iter().map(|(_, value)| value.clone()).collect();

    let filter = match compile_filter(&filter_code, &var_names) {
        Ok(compiled) => compiled,
        Err(message) => {
            ctx.emit_stderr_str(&format!("jaq: {message}\n"))?;
            return Ok(EXIT_COMPILE);
        }
    };

    let printer = PrettyPrinter::new(&cli);
    let token = ctx.cancel_token().clone();
    let mut last: Option<bool> = None;
    let mut exit_code = 0;

    if cli.null_input {
        match run_documents(
            ctx,
            &filter,
            &var_values,
            std::iter::once(Ok(Val::Null)),
            &printer,
            &mut last,
        )? {
            Some(code) => return Ok(code),
            None => {}
        }
    } else if cli.files.is_empty() {
        let bytes = match input {
            Some(bytes) => bytes.to_vec(),
            None => read_stdin(ctx)?,
        };
        let documents: Box<dyn Iterator<Item = Result<Val, String>>> = if cli.slurp {
            Box::new(slurp_documents(&bytes).into_iter())
        } else {
            Box::new(stream_documents(&bytes))
        };
        match run_documents(ctx, &filter, &var_values, documents, &printer, &mut last)? {
            Some(code) => return Ok(code),
            None => {}
        }
    } else {
        for file in &cli.files {
            token.check()?;
            let bytes = match ctx.read_file(std::path::Path::new(file)) {
                Ok(bytes) => bytes,
                Err(Error::Cancelled) => return Err(Error::Cancelled),
                Err(error) => {
                    ctx.emit_stderr_str(&format!("jaq: {file}: {error}\n"))?;
                    exit_code = EXIT_RUNTIME;
                    continue;
                }
            };
            let documents: Box<dyn Iterator<Item = Result<Val, String>>> = if cli.slurp {
                Box::new(slurp_documents(&bytes).into_iter())
            } else {
                Box::new(stream_documents(&bytes))
            };
            match run_documents(ctx, &filter, &var_values, documents, &printer, &mut last)? {
                Some(code) => return Ok(code),
                None => {}
            }
        }
    }

    if exit_code != 0 {
        return Ok(exit_code);
    }
    if cli.exit_status {
        return Ok(match last {
            Some(true) => 0,
            Some(false) => EXIT_FALSE_OR_NULL,
            None => EXIT_NO_OUTPUT,
        });
    }
    Ok(0)
}

/// The `$ARGS` object: positional arguments (here the input file names) and
/// the named bindings.
fn args_object(bindings: &[(String, Val)], cli: &args::Cli) -> Val {
    let positional: Vec<Val> = cli
        .files
        .iter()
        .map(|file| Val::utf8_str(file.clone()))
        .collect();
    let named: Vec<(Val, Val)> = bindings
        .iter()
        .map(|(name, value)| (Val::utf8_str(name.clone()), value.clone()))
        .collect();
    let mut fields: Vec<(Val, Val)> = Vec::new();
    fields.push((Val::utf8_str("positional"), Val::from_iter(positional)));
    fields.push((Val::utf8_str("named"), Val::obj(named.into_iter().collect())));
    Val::obj(fields.into_iter().collect())
}

fn dedupe_bindings(bindings: &mut Vec<(String, Val)>) {
    let mut unique: Vec<(String, Val)> = Vec::new();
    for (name, value) in bindings.drain(..) {
        if let Some(existing) = unique.iter_mut().find(|(known, _)| *known == name) {
            existing.1 = value;
        } else {
            unique.push((name, value));
        }
    }
    *bindings = unique;
}

type Filter = jaq_core::Filter<JustLut<Val>>;

/// Compile a filter. The returned value owns its compiled program.
fn compile_filter(code: &str, var_names: &[String]) -> Result<Filter, String> {
    let defs = jaq_core::defs()
        .chain(jaq_std::defs())
        .chain(jaq_json::defs());
    let funs = jaq_core::funs()
        .chain(jaq_std::funs())
        .chain(jaq_json::funs());
    let arena = Arena::default();
    let loader = Loader::new(defs);
    let modules = loader
        .load(&arena, File { code, path: () })
        .map_err(|errors| describe_load_errors(&errors))?;
    jaq_core::load::import(&modules, |_path| Err("file loading is not supported".into()))
        .map_err(|errors| describe_load_errors(&errors))?;
    let globals: Vec<String> = var_names
        .iter()
        .map(|name| format!("${name}"))
        .collect();
    let filter = Compiler::default()
        .with_funs(funs)
        .with_global_vars(globals.iter().map(String::as_str))
        .compile(modules)
        .map_err(|errors| describe_compile_errors(&errors))?;
    Ok(filter)
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

fn read_stdin(ctx: &Ctx<'_>) -> Result<Vec<u8>, Error> {
    let max = ctx.limits().max_file_bytes;
    let mut bytes = Vec::new();
    std::io::stdin()
        .take(max.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|error| Error::InvalidRequest(format!("cannot read standard input: {error}")))?;
    if bytes.len() as u64 > max {
        return Err(Error::LimitExceeded {
            limit: "max_file_bytes",
            value: bytes.len() as u64,
            max,
        });
    }
    Ok(bytes)
}

/// Lazily decode one JSON document per step.
///
/// The iterator must be abandoned on its first error: `jaq_json`'s slice
/// decoder does not advance the lexer after a syntax error, so a caller that
/// keeps polling would spin on the same bytes.
fn stream_documents(bytes: &[u8]) -> impl Iterator<Item = Result<Val, String>> + '_ {
    jaq_json::read::parse_many(bytes)
        .map(|result| result.map_err(|error| error.to_string()))
}

/// Decode every document into one value (the `-s` behaviour).
///
/// Stops at the first syntax error, for the reason documented on
/// [`stream_documents`].
fn slurp_documents(bytes: &[u8]) -> Vec<Result<Val, String>> {
    let mut values = Vec::new();
    for document in stream_documents(bytes) {
        match document {
            Ok(value) => values.push(value),
            Err(error) => return vec![Err(error)],
        }
    }
    vec![Ok(Val::from_iter(values))]
}

struct PrettyPrinter {
    pp: jaq_json::write::Pp,
    raw: bool,
}

impl PrettyPrinter {
    fn new(cli: &args::Cli) -> Self {
        let indent = if cli.compact {
            None
        } else {
            match cli.indent {
                Indent::Spaces(width) => Some(" ".repeat(width)),
                Indent::Tab => Some("\t".to_string()),
            }
        };
        PrettyPrinter {
            pp: jaq_json::write::Pp {
                indent,
                sort_keys: false,
                styles: jaq_json::write::Styles::default(),
                sep_space: !cli.compact,
            },
            raw: cli.raw_output,
        }
    }
}

fn run_documents<I>(
    ctx: &mut Ctx<'_>,
    filter: &Filter,
    var_values: &[Val],
    documents: I,
    printer: &PrettyPrinter,
    last: &mut Option<bool>,
) -> Result<Option<i32>, Error>
where
    I: IntoIterator<Item = Result<Val, String>>,
{
    let token = ctx.cancel_token().clone();
    for document in documents {
        token.check()?;
        let input = match document {
            Ok(value) => value,
            Err(error) => {
                ctx.emit_stderr_str(&format!("jaq: parse error: {error}\n"))?;
                return Ok(Some(EXIT_RUNTIME));
            }
        };
        let context = JaqCtx::<JustLut<Val>>::new(&filter.lut, Vars::new(var_values.to_vec()));
        let outputs = filter.id.run((context, input));
        for output in outputs {
            token.check()?;
            let value = match output {
                Ok(value) => value,
                Err(exception) => match exception.get_err() {
                    Ok(error) => {
                        ctx.emit_stderr_str(&format!("jaq: error: {error}\n"))?;
                        return Ok(Some(EXIT_RUNTIME));
                    }
                    Err(exception) => match exception.get_halt() {
                        Ok(code) => return Ok(Some(code)),
                        Err(_) => {
                            ctx.emit_stderr_str("jaq: error: uncaught exception\n")?;
                            return Ok(Some(EXIT_RUNTIME));
                        }
                    },
                },
            };
            *last = Some(value.as_bool());
            write_value(ctx, printer, &value)?;
        }
    }
    Ok(None)
}

/// An `io::Write` adapter so a large output value streams through the core
/// output sink (and its budget) instead of being buffered whole.
struct CtxWriter<'a, 'b> {
    ctx: &'a mut Ctx<'b>,
    cancelled: bool,
}

impl<'a, 'b> CtxWriter<'a, 'b> {
    fn new(ctx: &'a mut Ctx<'b>) -> Self {
        CtxWriter {
            ctx,
            cancelled: false,
        }
    }
}

impl io::Write for CtxWriter<'_, '_> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        match self.ctx.emit_stdout(bytes) {
            Ok(()) => Ok(bytes.len()),
            Err(Error::Cancelled) => {
                self.cancelled = true;
                Err(io::Error::new(io::ErrorKind::Interrupted, "cancelled"))
            }
            Err(error) => Err(io::Error::other(error.to_string())),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn write_value(ctx: &mut Ctx<'_>, printer: &PrettyPrinter, value: &Val) -> Result<(), Error> {
    if printer.raw {
        if let Val::TStr(bytes) | Val::BStr(bytes) = value {
            ctx.emit_stdout(bytes)?;
            ctx.emit_stdout(b"\n")?;
            return Ok(());
        }
    }
    let mut writer = CtxWriter::new(ctx);
    if let Err(error) = jaq_json::write::write(&mut writer, &printer.pp, 0, value) {
        if writer.cancelled {
            return Err(Error::Cancelled);
        }
        return Err(Error::InvalidRequest(format!(
            "cannot format output: {error}"
        )));
    }
    if let Err(error) = writer.write_all(b"\n") {
        if writer.cancelled {
            return Err(Error::Cancelled);
        }
        return Err(Error::InvalidRequest(format!(
            "cannot write output: {error}"
        )));
    }
    if writer.cancelled {
        return Err(Error::Cancelled);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_command_names_are_configurable() {
        assert_eq!(JaqCommand::new("jaq").name(), "jaq");
        assert_eq!(JaqCommand::new("jq").name(), "jq");
    }

    #[test]
    fn slurp_collects_documents_into_an_array() {
        let documents = slurp_documents(b"1 2 3");
        assert_eq!(documents.len(), 1);
        let value = documents.into_iter().next().unwrap().unwrap();
        assert_eq!(value.to_string(), "[1,2,3]");
    }

    #[test]
    fn a_parse_error_is_reported_on_the_first_failing_document() {
        let mut documents = stream_documents(b"{\"a\":}");
        assert!(documents.next().unwrap().is_err());
    }
}
