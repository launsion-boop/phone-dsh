// SPDX-License-Identifier: MIT
//! argv parsing for the Worker `jq` executable.
//!
//! The surface is the jq 1.6 option set the Worker shell and the upstream
//! tools actually use. Unknown options are a usage error (exit 2), never a
//! silently ignored flag: the engine exists so a jq invocation means what the
//! command line says.

/// A `--rawfile` / `--slurpfile` operand.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FileBinding {
    /// Variable name without `$`.
    pub name: String,
    /// Operand path as spelled on the command line.
    pub path: String,
}

/// Parsed command line.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Cli {
    pub raw_output: bool,
    pub compact: bool,
    pub slurp: bool,
    pub exit_status: bool,
    pub null_input: bool,
    pub join_output: bool,
    pub ascii_output: bool,
    pub sort_keys: bool,
    pub raw_input: bool,
    pub tab: bool,
    pub indent: Option<usize>,
    pub args: Vec<(String, String)>,
    pub argjson: Vec<(String, String)>,
    pub rawfiles: Vec<FileBinding>,
    pub slurpfiles: Vec<FileBinding>,
    pub filter: Option<String>,
    pub files: Vec<String>,
    pub positional: Vec<String>,
    pub args_mode: Option<ArgsMode>,
    pub help: bool,
    pub version: bool,
}

/// How `--args` / `--jsonargs` treats the remaining positional words.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ArgsMode {
    /// `--args`: every remaining word is a string in `$ARGS.positional`.
    Strings,
    /// `--jsonargs`: every remaining word is parsed as JSON.
    Json,
}

/// argv parse failure; the shell reports it as a usage error (exit 2).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UsageError(pub String);

impl core::fmt::Display for UsageError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str(&self.0)
    }
}

fn takes_value(name: &str) -> usize {
    match name {
        "indent" => 1,
        "arg" | "argjson" | "rawfile" | "slurpfile" => 2,
        _ => 0,
    }
}

fn is_option_word(token: &str) -> bool {
    // jq's `isoptish`: a word is option-shaped only when the second character
    // is `-` or an ASCII letter, so a negative filter such as `-1` stays a
    // filter and does not become an unknown option.
    let mut chars = token.chars();
    if chars.next() != Some('-') {
        return false;
    }
    matches!(chars.next(), Some('-') | Some('A'..='Z') | Some('a'..='z'))
}

/// Parse the words after argv[0].
pub fn parse(argv: &[String]) -> Result<Cli, UsageError> {
    let mut cli = Cli::default();
    let mut options_done = false;
    let mut index = 0usize;
    while index < argv.len() {
        let token = &argv[index];
        if !options_done && token == "--" {
            // jq 1.6 only accepts `--` after the filter; before it the word is
            // a usage error. Keeping the distinction stops a typo from turning
            // the next option into a filter expression.
            if cli.filter.is_none() {
                return Err(UsageError("jq: -- must follow the filter expression".to_string()));
            }
            options_done = true;
            index += 1;
            continue;
        }
        if !options_done && token.starts_with("--") && token.len() > 2 {
            let (name, inline) = match token[2..].find('=') {
                Some(at) => (&token[2..2 + at], Some(&token[3 + at..])),
                None => (&token[2..], None),
            };
            let mut value_at = index + 1;
            let mut value = |what: &str| -> Result<String, UsageError> {
                if let Some(inline) = inline {
                    return Ok(inline.to_string());
                }
                let found = argv
                    .get(value_at)
                    .cloned()
                    .ok_or_else(|| UsageError(format!("jq: option --{name} needs a value for {what}")))?;
                value_at += 1;
                Ok(found)
            };
            match (name, takes_value(name)) {
                ("arg", 2) => {
                    let key = value("NAME")?;
                    let val = value("VALUE")?;
                    cli.args.push((key, val));
                }
                ("argjson", 2) => {
                    let key = value("NAME")?;
                    let val = value("JSON")?;
                    cli.argjson.push((key, val));
                }
                ("rawfile", 2) => {
                    let name = value("NAME")?;
                    let path = value("FILE")?;
                    cli.rawfiles.push(FileBinding { name, path });
                }
                ("slurpfile", 2) => {
                    let name = value("NAME")?;
                    let path = value("FILE")?;
                    cli.slurpfiles.push(FileBinding { name, path });
                }
                ("indent", 1) => {
                    let raw = value("N")?;
                    let width = raw
                        .parse::<usize>()
                        .map_err(|_| UsageError(format!("jq: invalid --indent value {raw:?}")))?;
                    if width > 16 {
                        return Err(UsageError(format!("jq: invalid --indent value {width}")));
                    }
                    cli.indent = Some(width);
                }
                ("args", 0) => cli.args_mode = Some(ArgsMode::Strings),
                ("jsonargs", 0) => cli.args_mode = Some(ArgsMode::Json),
                ("raw-input", 0) => cli.raw_input = true,
                ("raw-output", 0) => cli.raw_output = true,
                ("compact-output", 0) => cli.compact = true,
                ("exit-status", 0) => cli.exit_status = true,
                ("slurp", 0) => cli.slurp = true,
                ("null-input", 0) => cli.null_input = true,
                ("join-output", 0) => cli.join_output = true,
                ("ascii-output", 0) => cli.ascii_output = true,
                ("sort-keys", 0) => cli.sort_keys = true,
                ("tab", 0) => cli.tab = true,
                ("color-output", 0) | ("monochrome-output", 0) => {}
                ("help", 0) => cli.help = true,
                ("version", 0) => cli.version = true,
                (other, 0) => return Err(UsageError(format!("jq: Unknown option --{other}"))),
                (other, _) => return Err(UsageError(format!("jq: Unknown option --{other}"))),
            }
            index = if inline.is_some() { index + 1 } else {
                // `takes_value` words consumed their values through `value_at`.
                value_at
            };
            continue;
        }
        if !options_done && is_option_word(token) && !token.starts_with("--") {
            for letter in token.chars().skip(1) {
                match letter {
                    'r' => cli.raw_output = true,
                    'c' => cli.compact = true,
                    's' => cli.slurp = true,
                    'e' => cli.exit_status = true,
                    'n' => cli.null_input = true,
                    'j' => cli.join_output = true,
                    'a' => cli.ascii_output = true,
                    'S' => cli.sort_keys = true,
                    'R' => cli.raw_input = true,
                    'C' | 'M' => {}
                    'h' => cli.help = true,
                    other => return Err(UsageError(format!("jq: Unknown option -{other}"))),
                }
            }
            index += 1;
            continue;
        }
        if cli.filter.is_none() {
            cli.filter = Some(token.clone());
        } else if cli.args_mode.is_some() {
            cli.positional.push(token.clone());
        } else {
            cli.files.push(token.clone());
        }
        index += 1;
    }
    if cli.help || cli.version {
        return Ok(cli);
    }
    if cli.filter.is_none() {
        return Err(UsageError("jq: missing filter expression".to_string()));
    }
    Ok(cli)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(items: &[&str]) -> Vec<String> {
        items.iter().map(|item| (*item).to_string()).collect()
    }

    #[test]
    fn a_negative_filter_is_not_an_option() {
        let cli = parse(&words(&["-1, inputs"])).unwrap();
        assert_eq!(cli.filter.as_deref(), Some("-1, inputs"));
    }

    #[test]
    fn option_values_do_not_become_the_filter() {
        let cli = parse(&words(&["--arg", "x", "--help", ".", "a"])).unwrap();
        assert_eq!(cli.args, vec![("x".to_string(), "--help".to_string())]);
        assert_eq!(cli.filter.as_deref(), Some("."));
        assert_eq!(cli.files, vec!["a"]);
    }

    #[test]
    fn args_mode_collects_positionals_instead_of_files() {
        let cli = parse(&words(&["-n", "$ARGS", "--args", "a", "b"])).unwrap();
        assert_eq!(cli.files, Vec::<String>::new());
        assert_eq!(cli.positional, vec!["a", "b"]);
    }
}
