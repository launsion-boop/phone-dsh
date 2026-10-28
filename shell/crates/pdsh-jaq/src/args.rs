// SPDX-License-Identifier: MIT
//! Command-line parsing for the jq-compatible `jaq` / `jq` accelerators.
//!
//! Supported argv: `jaq [OPTIONS] FILTER [FILE ...]`. Options are the ones the
//! jq compatibility contract names: `-r/--raw-output`, `-c/--compact-output`,
//! `-s/--slurp`, `-e/--exit-status`, `-n/--null-input`, `--arg name value`,
//! `--argjson name json`, `--tab`, `--indent N`, plus `--help` / `--version`.
//! Options and the filter may be separated by `--`.

/// Output indentation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Indent {
    /// One space per `--indent N`.
    Spaces(usize),
    /// One tab per level (`--tab`).
    Tab,
}

impl Default for Indent {
    fn default() -> Self {
        Indent::Spaces(2)
    }
}

/// Parsed input of one invocation.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Cli {
    /// `-r`: write strings without JSON quotes.
    pub raw_output: bool,
    /// `-c`: one output value per line.
    pub compact: bool,
    /// `-s`: read all inputs into one array.
    pub slurp: bool,
    /// `-e`: exit 1 when the last output is false or null.
    pub exit_status: bool,
    /// `-n`: use `null` as the only input and read no files.
    pub null_input: bool,
    /// `--arg` bindings, in order.
    pub args: Vec<(String, String)>,
    /// `--argjson` bindings, in order.
    pub argjson: Vec<(String, String)>,
    /// Indentation of pretty output.
    pub indent: Indent,
    /// The filter expression.
    pub filter: Option<String>,
    /// Input files, in order (`empty` means standard input).
    pub files: Vec<String>,
    /// `--help`.
    pub help: bool,
    /// `--version`.
    pub version: bool,
}

/// Parse a `jaq` argv vector (including `argv[0]`).
pub fn parse(argv: &[String]) -> Result<Cli, String> {
    let mut cli = Cli::default();
    let mut positionals: Vec<String> = Vec::new();
    let mut index = 1;
    let mut end_of_flags = false;
    while index < argv.len() {
        let arg = argv[index].clone();
        if end_of_flags {
            positionals.push(arg);
            index += 1;
            continue;
        }
        if arg == "--" {
            end_of_flags = true;
            index += 1;
            continue;
        }
        if let Some(long) = arg.strip_prefix("--") {
            let (name, inline) = match long.find('=') {
                Some(position) => (&long[..position], Some(&long[position + 1..])),
                None => (long, None),
            };
            let values = |count: usize, index: &mut usize| -> Result<Vec<String>, String> {
                let mut values = Vec::with_capacity(count);
                if let Some(inline) = inline {
                    values.push(inline.to_string());
                }
                while values.len() < count {
                    *index += 1;
                    let value = argv
                        .get(*index)
                        .cloned()
                        .ok_or_else(|| format!("option --{name} needs a value"))?;
                    values.push(value);
                }
                Ok(values)
            };
            match name {
                "raw-output" => cli.raw_output = true,
                "compact-output" => cli.compact = true,
                "slurp" => cli.slurp = true,
                "exit-status" => cli.exit_status = true,
                "null-input" => cli.null_input = true,
                "tab" => cli.indent = Indent::Tab,
                "indent" => {
                    let values = values(1, &mut index)?;
                    let width = values[0]
                        .parse::<usize>()
                        .map_err(|_| format!("invalid value for --indent: {:?}", values[0]))?;
                    if width > 16 {
                        return Err(format!("invalid value for --indent: {width}"));
                    }
                    cli.indent = Indent::Spaces(width);
                }
                "arg" => {
                    let values = values(2, &mut index)?;
                    cli.args.push((values[0].clone(), values[1].clone()));
                }
                "argjson" => {
                    let values = values(2, &mut index)?;
                    cli.argjson
                        .push((values[0].clone(), values[1].clone()));
                }
                "help" => cli.help = true,
                "version" => cli.version = true,
                other => return Err(format!("unrecognized flag --{other}")),
            }
            if inline.is_some() && values_consumed(name) == 0 {
                return Err(format!("option --{name} takes no value"));
            }
            index += 1;
            continue;
        }
        if arg.len() > 1 && arg.starts_with('-') {
            for flag in arg.chars().skip(1) {
                match flag {
                    'r' => cli.raw_output = true,
                    'c' => cli.compact = true,
                    's' => cli.slurp = true,
                    'e' => cli.exit_status = true,
                    'n' => cli.null_input = true,
                    'h' => cli.help = true,
                    other => return Err(format!("unrecognized flag -{other}")),
                }
            }
            index += 1;
            continue;
        }
        positionals.push(arg);
        index += 1;
    }
    if cli.help || cli.version {
        return Ok(cli);
    }
    let mut positionals = positionals.into_iter();
    cli.filter = Some(
        positionals
            .next()
            .ok_or_else(|| "missing filter expression".to_string())?,
    );
    cli.files = positionals.collect();
    Ok(cli)
}

fn values_consumed(name: &str) -> usize {
    match name {
        "indent" => 1,
        "arg" => 2,
        "argjson" => 2,
        _ => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(args: &[&str]) -> Vec<String> {
        args.iter().map(|arg| (*arg).to_string()).collect()
    }

    #[test]
    fn a_filter_and_files_are_split() {
        let cli = parse(&argv(&["jaq", ".a", "one.json", "two.json"])).unwrap();
        assert_eq!(cli.filter.as_deref(), Some(".a"));
        assert_eq!(cli.files, vec!["one.json", "two.json"]);
    }

    #[test]
    fn short_flags_can_be_grouped() {
        let cli = parse(&argv(&["jaq", "-rce", "."])).unwrap();
        assert!(cli.raw_output);
        assert!(cli.compact);
        assert!(cli.exit_status);
    }

    #[test]
    fn arg_and_argjson_bindings_keep_their_order() {
        let cli = parse(&argv(&[
            "jaq", "--arg", "name", "value", "--argjson", "n", "3", ".",
        ]))
        .unwrap();
        assert_eq!(cli.args, vec![("name".to_string(), "value".to_string())]);
        assert_eq!(cli.argjson, vec![("n".to_string(), "3".to_string())]);
    }

    #[test]
    fn indent_and_tab_are_accepted() {
        let cli = parse(&argv(&["jaq", "--indent", "4", "."])).unwrap();
        assert_eq!(cli.indent, Indent::Spaces(4));
        let cli = parse(&argv(&["jaq", "--tab", "."])).unwrap();
        assert_eq!(cli.indent, Indent::Tab);
        assert!(parse(&argv(&["jaq", "--indent", "99", "."])).is_err());
    }

    #[test]
    fn a_missing_filter_and_unknown_flags_are_usage_errors() {
        assert!(parse(&argv(&["jaq", "--raw-output"])).is_err());
        assert!(parse(&argv(&["jaq", "--nonsense", "."])).is_err());
        assert!(parse(&argv(&["jaq", "--arg", "only-one", "."])).is_err());
    }
}
