// SPDX-License-Identifier: MIT
//! `ts-parse` and `ts-query`: read-only tree-sitter syntax accelerators.
//!
//! `ts-parse FILE [--json|--sexp] [--max-depth N] [--lang LANG]` parses a file
//! with the grammar selected by its extension (or `--lang`) and prints the
//! syntax tree either as an S-expression (default) or as JSON.
//!
//! `ts-query FILE QUERY_FILE_OR_STRING [--captures] [--lang LANG]` runs a
//! tree-sitter query over the file and prints one `{name, start, end, text}`
//! JSON line per capture. `--captures` is accepted explicitly (capture rows are
//! the only output shape).
//!
//! Both commands read the source through the [`pdsh_core::Vfs`] sandbox and emit
//! output through [`pdsh_core::Ctx::emit_stdout`]. The cancel token is checked
//! every 1000 visited nodes and captures.

use std::fmt::Write as _;
use std::path::Path;

use tree_sitter::{Language, Node, Parser, Query, QueryCursor, StreamingIterator};
use pdsh_core::{Command, Ctx, Error, EXIT_CANCELLED};

/// Exit code for a usage error.
pub const EXIT_USAGE: i32 = 2;
/// Exit code for a command failure (parse/query engine failure).
pub const EXIT_INTERNAL: i32 = 70;

/// Nodes between two cancellation checks.
pub const CANCEL_CHECK_NODES: usize = 1000;

const HELP: &str = "\
ts-parse / ts-query (pdsh-shell read-only accelerators)

USAGE:
    ts-parse FILE [--json|--sexp] [--max-depth N] [--lang LANG]
    ts-query FILE QUERY_FILE_OR_STRING [--captures] [--lang LANG]

LANGUAGES:
    ts, tsx, js, swift, py, rs, c, json (selected by extension unless --lang)

OPTIONS:
        --json          print the tree as JSON instead of an S-expression
        --sexp          print the tree as an S-expression (default)
        --max-depth N   omit children below depth N (root is depth 0)
        --captures      accepted explicitly (ts-query always prints capture rows)
        --lang LANG     override the language selected by the extension
    -h, --help          print this help
";

/// The supported grammars.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Grammar {
    /// TypeScript.
    TypeScript,
    /// TSX.
    Tsx,
    /// JavaScript (including JSX).
    JavaScript,
    /// Swift.
    Swift,
    /// Python.
    Python,
    /// Rust.
    Rust,
    /// C.
    C,
    /// JSON.
    Json,
}

impl Grammar {
    /// Select a grammar from a file extension.
    pub fn for_path(path: &Path) -> Option<Grammar> {
        let extension = path.extension()?.to_str()?.to_ascii_lowercase();
        Some(match extension.as_str() {
            "ts" | "mts" | "cts" => Grammar::TypeScript,
            "tsx" => Grammar::Tsx,
            "js" | "mjs" | "cjs" | "jsx" => Grammar::JavaScript,
            "swift" => Grammar::Swift,
            "py" | "pyi" => Grammar::Python,
            "rs" => Grammar::Rust,
            "c" | "h" => Grammar::C,
            "json" => Grammar::Json,
            _ => return None,
        })
    }

    /// Select a grammar from a `--lang` name.
    pub fn for_name(name: &str) -> Option<Grammar> {
        Some(match name.to_ascii_lowercase().as_str() {
            "ts" | "typescript" => Grammar::TypeScript,
            "tsx" => Grammar::Tsx,
            "js" | "javascript" | "jsx" => Grammar::JavaScript,
            "swift" => Grammar::Swift,
            "py" | "python" => Grammar::Python,
            "rs" | "rust" => Grammar::Rust,
            "c" => Grammar::C,
            "json" => Grammar::Json,
            _ => return None,
        })
    }

    /// The tree-sitter language object.
    pub fn language(self) -> Language {
        match self {
            Grammar::TypeScript => Language::new(tree_sitter_typescript::LANGUAGE_TYPESCRIPT),
            Grammar::Tsx => Language::new(tree_sitter_typescript::LANGUAGE_TSX),
            Grammar::JavaScript => Language::new(tree_sitter_javascript::LANGUAGE),
            Grammar::Swift => Language::new(tree_sitter_swift::LANGUAGE),
            Grammar::Python => Language::new(tree_sitter_python::LANGUAGE),
            Grammar::Rust => Language::new(tree_sitter_rust::LANGUAGE),
            Grammar::C => Language::new(tree_sitter_c::LANGUAGE),
            Grammar::Json => Language::new(tree_sitter_json::LANGUAGE),
        }
    }

    /// A stable lowercase name.
    pub fn name(self) -> &'static str {
        match self {
            Grammar::TypeScript => "typescript",
            Grammar::Tsx => "tsx",
            Grammar::JavaScript => "javascript",
            Grammar::Swift => "swift",
            Grammar::Python => "python",
            Grammar::Rust => "rust",
            Grammar::C => "c",
            Grammar::Json => "json",
        }
    }
}

/// The `ts-parse` accelerator.
#[derive(Debug, Default, Clone, Copy)]
pub struct TsParseCommand;

impl Command for TsParseCommand {
    fn name(&self) -> &str {
        "ts-parse"
    }

    fn run(&self, argv: &[String], ctx: &mut Ctx<'_>) -> i32 {
        run_ts_parse(argv, ctx)
    }
}

/// The `ts-query` accelerator.
#[derive(Debug, Default, Clone, Copy)]
pub struct TsQueryCommand;

impl Command for TsQueryCommand {
    fn name(&self) -> &str {
        "ts-query"
    }

    fn run(&self, argv: &[String], ctx: &mut Ctx<'_>) -> i32 {
        run_ts_query(argv, ctx)
    }
}

/// Run `ts-parse`.
pub fn run_ts_parse(argv: &[String], ctx: &mut Ctx<'_>) -> i32 {
    match execute_parse(argv, ctx) {
        Ok(code) => code,
        Err(Error::Cancelled) => EXIT_CANCELLED,
        Err(error) => {
            let _ = ctx.emit_stderr_str(&format!("ts-parse: {error}\n"));
            EXIT_INTERNAL
        }
    }
}

/// Run `ts-query`.
pub fn run_ts_query(argv: &[String], ctx: &mut Ctx<'_>) -> i32 {
    match execute_query(argv, ctx) {
        Ok(code) => code,
        Err(Error::Cancelled) => EXIT_CANCELLED,
        Err(error) => {
            let _ = ctx.emit_stderr_str(&format!("ts-query: {error}\n"));
            EXIT_INTERNAL
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ParseArgs {
    file: String,
    json: bool,
    max_depth: Option<usize>,
    lang: Option<String>,
    help: bool,
}

fn parse_parse_args(argv: &[String]) -> Result<ParseArgs, String> {
    let mut file = None;
    let mut args = ParseArgs {
        file: String::new(),
        json: false,
        max_depth: None,
        lang: None,
        help: false,
    };
    let mut index = 1;
    while index < argv.len() {
        let argument = &argv[index];
        match argument.as_str() {
            "--json" => args.json = true,
            "--sexp" => args.json = false,
            "--max-depth" => {
                index += 1;
                let value = argv
                    .get(index)
                    .ok_or_else(|| "--max-depth needs a value".to_string())?;
                args.max_depth = Some(
                    value
                        .parse::<usize>()
                        .map_err(|_| format!("invalid value for --max-depth: {value:?}"))?,
                );
            }
            "--lang" => {
                index += 1;
                args.lang = Some(
                    argv.get(index)
                        .cloned()
                        .ok_or_else(|| "--lang needs a value".to_string())?,
                );
            }
            "-h" | "--help" => args.help = true,
            other if other.starts_with("--max-depth=") => {
                let value = &other["--max-depth=".len()..];
                args.max_depth = Some(
                    value
                        .parse::<usize>()
                        .map_err(|_| format!("invalid value for --max-depth: {value:?}"))?,
                );
            }
            other if other.starts_with("--lang=") => {
                args.lang = Some(other["--lang=".len()..].to_string());
            }
            other if other.starts_with('-') => {
                return Err(format!("unrecognized flag {other}"));
            }
            other => {
                if file.replace(other.to_string()).is_some() {
                    return Err("expected exactly one FILE".to_string());
                }
            }
        }
        index += 1;
    }
    if args.help {
        return Ok(args);
    }
    args.file = file.ok_or_else(|| "missing FILE".to_string())?;
    Ok(args)
}

fn execute_parse(argv: &[String], ctx: &mut Ctx<'_>) -> Result<i32, Error> {
    let args = match parse_parse_args(argv) {
        Ok(args) => args,
        Err(message) => {
            ctx.emit_stderr_str(&format!("ts-parse: {message}\n"))?;
            return Ok(EXIT_USAGE);
        }
    };
    if args.help {
        ctx.emit_stdout_str(HELP)?;
        return Ok(0);
    }
    let grammar = match select_grammar(&args.file, args.lang.as_deref()) {
        Ok(grammar) => grammar,
        Err(message) => {
            ctx.emit_stderr_str(&format!("ts-parse: {message}\n"))?;
            return Ok(EXIT_USAGE);
        }
    };
    let source = match ctx.read_file(Path::new(&args.file)) {
        Ok(source) => source,
        Err(Error::Cancelled) => return Err(Error::Cancelled),
        Err(error) => {
            ctx.emit_stderr_str(&format!("ts-parse: {}: {error}\n", args.file))?;
            return Ok(EXIT_USAGE);
        }
    };
    let tree = match parse_source(grammar, &source) {
        Ok(tree) => tree,
        Err(message) => {
            ctx.emit_stderr_str(&format!("ts-parse: {}: {message}\n", args.file))?;
            return Ok(EXIT_INTERNAL);
        }
    };
    let root = tree.root_node();
    if args.json {
        let mut output = String::new();
        write_json_node(ctx, &mut output, &root, 0, args.max_depth, None, &mut 0)?;
        output.push('\n');
        ctx.emit_stdout_str(&output)?;
    } else {
        let mut output = String::new();
        write_sexp(
            ctx,
            &mut output,
            &root,
            0,
            args.max_depth,
            &mut 0,
        )?;
        output.push('\n');
        ctx.emit_stdout_str(&output)?;
    }
    Ok(0)
}

fn select_grammar(file: &str, lang: Option<&str>) -> Result<Grammar, String> {
    if let Some(name) = lang {
        return Grammar::for_name(name)
            .ok_or_else(|| format!("unknown language {name:?}"));
    }
    Grammar::for_path(Path::new(file))
        .ok_or_else(|| format!("cannot infer the language of {file:?}; use --lang"))
}

fn parse_source(grammar: Grammar, source: &[u8]) -> Result<tree_sitter::Tree, String> {
    let language = grammar.language();
    let mut parser = Parser::new();
    parser
        .set_language(&language)
        .map_err(|error| format!("cannot load the {} grammar: {error}", grammar.name()))?;
    parser
        .parse(source, None)
        .ok_or_else(|| "the parser returned no tree".to_string())
}

fn check_progress(ctx: &Ctx<'_>, counter: &mut usize) -> Result<(), Error> {
    *counter += 1;
    if *counter % CANCEL_CHECK_NODES == 0 {
        ctx.check_cancel()?;
    }
    Ok(())
}

fn write_sexp(
    ctx: &Ctx<'_>,
    output: &mut String,
    node: &Node<'_>,
    depth: usize,
    max_depth: Option<usize>,
    counter: &mut usize,
) -> Result<(), Error> {
    check_progress(ctx, counter)?;
    output.push('(');
    output.push_str(node.kind());
    let descend = max_depth.map(|max| depth < max).unwrap_or(true);
    if descend {
        let mut cursor = node.walk();
        for child in node.children(&mut cursor) {
            if !child.is_named() {
                continue;
            }
            output.push(' ');
            write_sexp(ctx, output, &child, depth + 1, max_depth, counter)?;
        }
    }
    output.push(')');
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn write_json_node(
    ctx: &Ctx<'_>,
    output: &mut String,
    node: &Node<'_>,
    depth: usize,
    max_depth: Option<usize>,
    field: Option<&str>,
    counter: &mut usize,
) -> Result<(), Error> {
    check_progress(ctx, counter)?;
    output.push('{');
    let mut first = true;
    if let Some(field) = field {
        write_json_field(output, &mut first, "field", field);
    }
    write_json_field(output, &mut first, "type", node.kind());
    write_json_number(output, &mut first, "start", node.start_byte());
    write_json_number(output, &mut first, "end", node.end_byte());
    let descend = max_depth.map(|max| depth < max).unwrap_or(true);
    if descend {
        let children: Vec<(Option<&str>, Node<'_>)> = {
            let mut cursor = node.walk();
            node.children(&mut cursor)
                .enumerate()
                .filter(|(_, child)| child.is_named())
                .map(|(index, child)| {
                    let field = node.field_name_for_child(index as u32);
                    (field, child)
                })
                .collect()
        };
        if !children.is_empty() {
            write_json_key(output, &mut first, "children");
            output.push('[');
            for (position, (child_field, child)) in children.iter().enumerate() {
                if position > 0 {
                    output.push(',');
                }
                write_json_node(
                    ctx,
                    output,
                    child,
                    depth + 1,
                    max_depth,
                    *child_field,
                    counter,
                )?;
            }
            output.push(']');
        }
    }
    output.push('}');
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct QueryArgs {
    file: String,
    query: String,
    captures: bool,
    lang: Option<String>,
    help: bool,
}

fn parse_query_args(argv: &[String]) -> Result<QueryArgs, String> {
    let mut positionals: Vec<String> = Vec::new();
    let mut args = QueryArgs {
        file: String::new(),
        query: String::new(),
        captures: false,
        lang: None,
        help: false,
    };
    let mut index = 1;
    let mut end_of_flags = false;
    while index < argv.len() {
        let argument = &argv[index];
        if end_of_flags {
            positionals.push(argument.clone());
            index += 1;
            continue;
        }
        match argument.as_str() {
            "--" => end_of_flags = true,
            "--captures" => args.captures = true,
            "--lang" => {
                index += 1;
                args.lang = Some(
                    argv.get(index)
                        .cloned()
                        .ok_or_else(|| "--lang needs a value".to_string())?,
                );
            }
            "-h" | "--help" => args.help = true,
            other if other.starts_with("--lang=") => {
                args.lang = Some(other["--lang=".len()..].to_string());
            }
            other if other.starts_with('-') && positionals.len() < 2 => {
                return Err(format!("unrecognized flag {other}"));
            }
            other => positionals.push(other.to_string()),
        }
        index += 1;
    }
    if args.help {
        return Ok(args);
    }
    if positionals.len() != 2 {
        return Err("expected FILE and QUERY_FILE_OR_STRING".to_string());
    }
    args.file = positionals.remove(0);
    args.query = positionals.remove(0);
    Ok(args)
}

fn execute_query(argv: &[String], ctx: &mut Ctx<'_>) -> Result<i32, Error> {
    let args = match parse_query_args(argv) {
        Ok(args) => args,
        Err(message) => {
            ctx.emit_stderr_str(&format!("ts-query: {message}\n"))?;
            return Ok(EXIT_USAGE);
        }
    };
    if args.help {
        ctx.emit_stdout_str(HELP)?;
        return Ok(0);
    }
    let grammar = match select_grammar(&args.file, args.lang.as_deref()) {
        Ok(grammar) => grammar,
        Err(message) => {
            ctx.emit_stderr_str(&format!("ts-query: {message}\n"))?;
            return Ok(EXIT_USAGE);
        }
    };
    let source = match ctx.read_file(Path::new(&args.file)) {
        Ok(source) => source,
        Err(Error::Cancelled) => return Err(Error::Cancelled),
        Err(error) => {
            ctx.emit_stderr_str(&format!("ts-query: {}: {error}\n", args.file))?;
            return Ok(EXIT_USAGE);
        }
    };
    let query_source = match query_source(ctx, &args.query) {
        Ok(query) => query,
        Err(Error::Cancelled) => return Err(Error::Cancelled),
        Err(error) => {
            ctx.emit_stderr_str(&format!("ts-query: {}: {error}\n", args.query))?;
            return Ok(EXIT_USAGE);
        }
    };
    let tree = match parse_source(grammar, &source) {
        Ok(tree) => tree,
        Err(message) => {
            ctx.emit_stderr_str(&format!("ts-query: {}: {message}\n", args.file))?;
            return Ok(EXIT_INTERNAL);
        }
    };
    let language = grammar.language();
    let query = match Query::new(&language, &query_source) {
        Ok(query) => query,
        Err(error) => {
            ctx.emit_stderr_str(&format!("ts-query: invalid query: {error}\n"))?;
            return Ok(EXIT_USAGE);
        }
    };
    let names = query.capture_names();
    let mut cursor = QueryCursor::new();
    let mut matches = cursor.matches(&query, tree.root_node(), source.as_slice());
    let mut counter = 0usize;
    let mut output = String::new();
    let _ = args.captures;
    while let Some(query_match) = matches.next() {
        check_progress(ctx, &mut counter)?;
        for capture in query_match.captures {
            check_progress(ctx, &mut counter)?;
            let name = names
                .get(capture.index as usize)
                .copied()
                .unwrap_or("capture");
            write_capture_row(&mut output, name, &capture.node, &source);
            ctx.emit_stdout_str(&output)?;
            output.clear();
        }
    }
    Ok(0)
}

fn query_source(ctx: &mut Ctx<'_>, argument: &str) -> Result<String, Error> {
    let path = Path::new(argument);
    if let Ok(metadata) = ctx.metadata(path) {
        if metadata.is_file() {
            let bytes = ctx.read_file(path)?;
            return Ok(String::from_utf8_lossy(&bytes).into_owned());
        }
    }
    Ok(argument.to_string())
}

fn write_capture_row(output: &mut String, name: &str, node: &Node<'_>, source: &[u8]) {
    output.push('{');
    let mut first = true;
    write_json_field(output, &mut first, "name", name);
    write_json_number(output, &mut first, "start", node.start_byte());
    write_json_number(output, &mut first, "end", node.end_byte());
    write_json_field(
        output,
        &mut first,
        "text",
        &node_text(node, source),
    );
    output.push('}');
    output.push('\n');
}

fn node_text(node: &Node<'_>, source: &[u8]) -> String {
    let start = node.start_byte().min(source.len());
    let end = node.end_byte().min(source.len());
    String::from_utf8_lossy(&source[start..end]).into_owned()
}

fn write_json_key(output: &mut String, first: &mut bool, key: &str) {
    if !*first {
        output.push(',');
    }
    *first = false;
    output.push('"');
    output.push_str(key);
    output.push_str("\":");
}

fn write_json_field(output: &mut String, first: &mut bool, key: &str, value: &str) {
    write_json_key(output, first, key);
    output.push('"');
    escape_json_into(output, value);
    output.push('"');
}

fn write_json_number(output: &mut String, first: &mut bool, key: &str, value: usize) {
    write_json_key(output, first, key);
    let _ = write!(output, "{value}");
}

fn escape_json_into(output: &mut String, value: &str) {
    for character in value.chars() {
        match character {
            '"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            control if (control as u32) < 0x20 => {
                let _ = write!(output, "\\u{:04x}", control as u32);
            }
            other => output.push(other),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extensions_map_to_grammars() {
        assert_eq!(Grammar::for_path(Path::new("a.ts")), Some(Grammar::TypeScript));
        assert_eq!(Grammar::for_path(Path::new("a.tsx")), Some(Grammar::Tsx));
        assert_eq!(Grammar::for_path(Path::new("a.js")), Some(Grammar::JavaScript));
        assert_eq!(Grammar::for_path(Path::new("a.swift")), Some(Grammar::Swift));
        assert_eq!(Grammar::for_path(Path::new("a.py")), Some(Grammar::Python));
        assert_eq!(Grammar::for_path(Path::new("a.rs")), Some(Grammar::Rust));
        assert_eq!(Grammar::for_path(Path::new("a.c")), Some(Grammar::C));
        assert_eq!(Grammar::for_path(Path::new("a.json")), Some(Grammar::Json));
        assert_eq!(Grammar::for_path(Path::new("a.txt")), None);
    }

    #[test]
    fn language_names_and_extensions_agree() {
        for (name, grammar) in [
            ("ts", Grammar::TypeScript),
            ("tsx", Grammar::Tsx),
            ("js", Grammar::JavaScript),
            ("swift", Grammar::Swift),
            ("py", Grammar::Python),
            ("rs", Grammar::Rust),
            ("c", Grammar::C),
            ("json", Grammar::Json),
        ] {
            assert_eq!(Grammar::for_name(name), Some(grammar));
        }
        assert_eq!(Grammar::for_name("cobol"), None);
    }

    #[test]
    fn json_escaping_handles_quotes_and_controls() {
        let mut output = String::new();
        escape_json_into(&mut output, "a\"b\\c\n");
        assert_eq!(output, "a\\\"b\\\\c\\n");
    }

    #[test]
    fn only_one_file_argument_is_accepted() {
        let argv = vec![
            "ts-parse".to_string(),
            "a.rs".to_string(),
            "b.rs".to_string(),
        ];
        assert!(parse_parse_args(&argv).is_err());
    }
}
