// SPDX-License-Identifier: MIT
//! Command-line parsing for the read-only `rg` accelerator.
//!
//! The parser accepts the argv set the DSH `grep` / `glob` tools emit
//! (`--json`, `--files`, `--sort=modified`, `--no-ignore`, `--hidden`,
//! `--no-config`, `--glob=…`, `--regexp=…`, `--`, a positional pattern and
//! paths) plus the common ripgrep variants implemented by the accelerator.
//! Parsing is deliberately self-contained: a malformed argument is a usage
//! error (exit 2), never a panic.

/// How to order the discovered files.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Sort {
    /// Walk order (directory entries sorted by name).
    #[default]
    None,
    /// Display path, lexicographically.
    Path,
    /// File modification time, oldest first (the ripgrep `--sort=modified`
    /// order), ties broken by display path.
    Modified,
}

/// Pattern case handling.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Case {
    /// Case sensitive (ripgrep's default).
    #[default]
    Sensitive,
    /// `-i`.
    Insensitive,
    /// `-S`: insensitive only when the pattern has no uppercase letter.
    Smart,
}

/// Parsed options of one `rg` invocation.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Options {
    /// `--json`: emit ripgrep's JSON lines.
    pub json: bool,
    /// `--files`: list files, do not search their contents.
    pub files: bool,
    /// Result ordering.
    pub sort: Sort,
    /// `--no-ignore`: do not read `.gitignore` / `.ignore` files.
    pub no_ignore: bool,
    /// `--hidden`: include hidden files and directories.
    pub hidden: bool,
    /// `-g` / `--glob` values, in order.
    pub globs: Vec<String>,
    /// Pattern case handling.
    pub case: Case,
    /// `-F` / `--fixed-strings`.
    pub fixed: bool,
    /// `-e` / `--regexp` values, in order.
    pub patterns: Vec<String>,
    /// `-n` / `--line-number` (text output only).
    pub line_number: bool,
    /// `-H` / `--with-filename` (text output only).
    pub with_filename: bool,
    /// `--column` (text output only).
    pub column: bool,
    /// `-m` / `--max-count`, per file.
    pub max_count: Option<u64>,
    /// `--max-filesize`, in bytes.
    pub max_filesize: Option<u64>,
    /// `--max-depth`, in directory levels.
    pub max_depth: Option<usize>,
    /// `-w` / `--word-regexp`.
    pub word: bool,
    /// `-t` / `--type` names.
    pub types: Vec<String>,
    /// `-T` / `--type-not` names.
    pub types_not: Vec<String>,
    /// `--no-messages`: suppress per-path error messages.
    pub no_messages: bool,
    /// `-B` / `--before-context` lines.
    pub before: usize,
    /// `-A` / `--after-context` lines.
    pub after: usize,
    /// `-uuu`: treat binary files as text.
    pub binary_text: bool,
    /// `-h` / `--help`.
    pub help: bool,
    /// `--version`.
    pub version: bool,
    /// Search roots exactly as written on the command line (empty = cwd).
    ///
    /// [`Invocation::paths`] carries the same list; this copy lets the walker
    /// borrow one options value.
    pub paths: Vec<String>,
}

impl Options {
    /// True when any positive glob is present.
    pub fn has_positive_glob(&self) -> bool {
        self.globs.iter().any(|glob| !glob.starts_with('!'))
    }
}

/// One fully parsed invocation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Invocation {
    /// Parsed options.
    pub options: Options,
    /// The single positional pattern when no `-e` was given.
    pub pattern: Option<String>,
    /// Search roots exactly as written on the command line (empty = cwd).
    pub paths: Vec<String>,
}

/// Parse an `rg` argv vector (including `argv[0]`).
pub fn parse(argv: &[String]) -> Result<Invocation, String> {
    let mut options = Options::default();
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
            let (name, inline) = split_inline(long);
            let value = |index: &mut usize| -> Result<String, String> {
                if let Some(value) = inline {
                    return Ok(value.to_string());
                }
                *index += 1;
                argv.get(*index)
                    .cloned()
                    .ok_or_else(|| format!("option --{name} needs a value"))
            };
            match name {
                "json" => set_flag(&mut options.json, inline, name)?,
                "files" => set_flag(&mut options.files, inline, name)?,
                "sort" => {
                    let value = value(&mut index)?;
                    options.sort = match value.as_str() {
                        "none" => Sort::None,
                        "path" => Sort::Path,
                        "modified" => Sort::Modified,
                        other => return Err(format!("invalid value for --sort: {other:?}")),
                    };
                }
                "no-ignore" => set_flag(&mut options.no_ignore, inline, name)?,
                "hidden" => set_flag(&mut options.hidden, inline, name)?,
                "no-config" => {
                    // Accepted and ignored: the accelerator has no config file
                    // to read, and a host config can never inject `--pre`.
                }
                "no-messages" => set_flag(&mut options.no_messages, inline, name)?,
                "glob" => options.globs.push(value(&mut index)?),
                "regexp" => options.patterns.push(value(&mut index)?),
                "ignore-case" => {
                    reject_inline(inline, name)?;
                    options.case = Case::Insensitive;
                }
                "case-sensitive" => {
                    reject_inline(inline, name)?;
                    options.case = Case::Sensitive;
                }
                "smart-case" => {
                    reject_inline(inline, name)?;
                    options.case = Case::Smart;
                }
                "fixed-strings" => set_flag(&mut options.fixed, inline, name)?,
                "word-regexp" => set_flag(&mut options.word, inline, name)?,
                "line-number" => set_flag(&mut options.line_number, inline, name)?,
                "with-filename" => set_flag(&mut options.with_filename, inline, name)?,
                "column" => set_flag(&mut options.column, inline, name)?,
                "max-count" => options.max_count = Some(parse_u64(&value(&mut index)?, name)?),
                "max-filesize" => {
                    options.max_filesize = Some(parse_size(&value(&mut index)?, name)?)
                }
                "max-depth" => {
                    options.max_depth = Some(parse_usize(&value(&mut index)?, name)?)
                }
                "type" => options.types.push(value(&mut index)?),
                "type-not" => options.types_not.push(value(&mut index)?),
                "before-context" => {
                    options.before = parse_usize(&value(&mut index)?, name)?;
                }
                "after-context" => {
                    options.after = parse_usize(&value(&mut index)?, name)?;
                }
                "context" => {
                    let context = parse_usize(&value(&mut index)?, name)?;
                    options.before = context;
                    options.after = context;
                }
                "help" => {
                    reject_inline(inline, name)?;
                    options.help = true;
                }
                "version" => {
                    reject_inline(inline, name)?;
                    options.version = true;
                }
                other => return Err(format!("unrecognized flag --{other}")),
            }
            index += 1;
            continue;
        }
        if arg.len() > 1 && arg.starts_with('-') {
            let chars: Vec<char> = arg.chars().skip(1).collect();
            let mut cursor = 0;
            while cursor < chars.len() {
                let flag = chars[cursor];
                let takes_value = matches!(flag, 'e' | 'g' | 't' | 'T' | 'm' | 'A' | 'B' | 'C' | 'd');
                if takes_value {
                    let inline: String = chars[cursor + 1..].iter().collect();
                    let value = if inline.is_empty() {
                        index += 1;
                        argv.get(index)
                            .cloned()
                            .ok_or_else(|| format!("option -{flag} needs a value"))?
                    } else {
                        inline
                    };
                    match flag {
                        'e' => options.patterns.push(value),
                        'g' => options.globs.push(value),
                        't' => options.types.push(value),
                        'T' => options.types_not.push(value),
                        'm' => options.max_count = Some(parse_u64(&value, "max-count")?),
                        'A' => options.after = parse_usize(&value, "after-context")?,
                        'B' => options.before = parse_usize(&value, "before-context")?,
                        'C' => {
                            let context = parse_usize(&value, "context")?;
                            options.before = context;
                            options.after = context;
                        }
                        'd' => options.max_depth = Some(parse_usize(&value, "max-depth")?),
                        _ => unreachable!("value-taking flags are exhaustive"),
                    }
                    cursor = chars.len();
                    continue;
                }
                match flag {
                    'i' => options.case = Case::Insensitive,
                    's' => options.case = Case::Sensitive,
                    'S' => options.case = Case::Smart,
                    'F' => options.fixed = true,
                    'w' => options.word = true,
                    'n' => options.line_number = true,
                    'H' => options.with_filename = true,
                    'h' => options.help = true,
                    'u' => {
                        // `-u` disables ignores, `-uu` also includes hidden
                        // files, `-uuu` additionally treats binary files as
                        // text (ripgrep's own counting).
                        if options.no_ignore {
                            if options.hidden {
                                options.binary_text = true;
                            } else {
                                options.hidden = true;
                            }
                        } else {
                            options.no_ignore = true;
                        }
                    }
                    other => return Err(format!("unrecognized flag -{other}")),
                }
                cursor += 1;
            }
            index += 1;
            continue;
        }
        positionals.push(arg);
        index += 1;
    }

    if options.help || options.version {
        return Ok(Invocation {
            options,
            pattern: None,
            paths: Vec::new(),
        });
    }
    if !options.patterns.is_empty() && options.files {
        return Err("--files cannot be used with --regexp/-e".to_string());
    }
    let (pattern, paths) = if options.files || !options.patterns.is_empty() {
        (None, positionals)
    } else {
        let mut positionals = positionals.into_iter();
        let pattern = positionals
            .next()
            .ok_or_else(|| "no pattern given (use -e/--regexp or a positional pattern)".to_string())?;
        (Some(pattern), positionals.collect())
    };
    Ok(Invocation {
        options: Options {
            paths: paths.clone(),
            ..options
        },
        pattern,
        paths,
    })
}

fn split_inline(long: &str) -> (&str, Option<&str>) {
    match long.find('=') {
        Some(index) => (&long[..index], Some(&long[index + 1..])),
        None => (long, None),
    }
}

fn reject_inline(inline: Option<&str>, name: &str) -> Result<(), String> {
    if inline.is_some() {
        return Err(format!("option --{name} takes no value"));
    }
    Ok(())
}

fn set_flag(flag: &mut bool, inline: Option<&str>, name: &str) -> Result<(), String> {
    reject_inline(inline, name)?;
    *flag = true;
    Ok(())
}

fn parse_u64(value: &str, name: &str) -> Result<u64, String> {
    value
        .parse::<u64>()
        .map_err(|_| format!("invalid value for --{name}: {value:?}"))
}

fn parse_usize(value: &str, name: &str) -> Result<usize, String> {
    value
        .parse::<usize>()
        .map_err(|_| format!("invalid value for --{name}: {value:?}"))
}

/// Parse a ripgrep file-size value: an integer with an optional `K`, `M` or
/// `G` suffix (binary multiples), optionally followed by `B`.
fn parse_size(value: &str, name: &str) -> Result<u64, String> {
    let trimmed = value.trim();
    let (digits, multiplier) = match trimmed.strip_suffix(['b', 'B']) {
        Some(digits) => (digits, 1),
        None => {
            let mut chars = trimmed.chars();
            let last = chars.next_back();
            match last.map(|character| character.to_ascii_uppercase()) {
                Some('K') => (chars.as_str(), 1024),
                Some('M') => (chars.as_str(), 1024 * 1024),
                Some('G') => (chars.as_str(), 1024 * 1024 * 1024),
                _ => (trimmed, 1),
            }
        }
    };
    let number = digits
        .parse::<u64>()
        .map_err(|_| format!("invalid value for --{name}: {value:?}"))?;
    number
        .checked_mul(multiplier)
        .ok_or_else(|| format!("invalid value for --{name}: {value:?}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(args: &[&str]) -> Vec<String> {
        args.iter().map(|arg| (*arg).to_string()).collect()
    }

    #[test]
    fn dsh_grep_argv_is_accepted() {
        let invocation =
            parse(&argv(&["rg", "--json", "--regexp=const", "--glob=*.ts", "--", "src"]))
                .unwrap();
        assert!(invocation.options.json);
        assert_eq!(invocation.options.patterns, vec!["const"]);
        assert_eq!(invocation.options.globs, vec!["*.ts"]);
        assert_eq!(invocation.paths, vec!["src"]);
        assert!(invocation.pattern.is_none());
    }

    #[test]
    fn dsh_glob_argv_is_accepted() {
        let invocation = parse(&argv(&[
            "rg",
            "--files",
            "--glob=**/*.ts",
            "--sort=modified",
            "--no-ignore",
            "--hidden",
            "--glob=!**/.git",
            "--glob=!**/.git/**",
            "--",
            "sub",
        ]))
        .unwrap();
        assert!(invocation.options.files);
        assert_eq!(invocation.options.sort, Sort::Modified);
        assert!(invocation.options.no_ignore);
        assert!(invocation.options.hidden);
        assert_eq!(
            invocation.options.globs,
            vec!["**/*.ts", "!**/.git", "!**/.git/**"]
        );
        assert_eq!(invocation.paths, vec!["sub"]);
    }

    #[test]
    fn a_positional_pattern_and_paths_are_split() {
        let invocation = parse(&argv(&["rg", "-n", "needle", "a", "b"])).unwrap();
        assert_eq!(invocation.pattern.as_deref(), Some("needle"));
        assert_eq!(invocation.paths, vec!["a", "b"]);
        assert!(invocation.options.line_number);
    }

    #[test]
    fn repeated_regexp_flags_do_not_consume_a_positional() {
        let invocation = parse(&argv(&["rg", "-e", "a", "-e", "b", "src"])).unwrap();
        assert_eq!(invocation.options.patterns, vec!["a", "b"]);
        assert_eq!(invocation.pattern, None);
        assert_eq!(invocation.paths, vec!["src"]);
    }

    #[test]
    fn short_flags_can_be_grouped_and_carry_values() {
        let invocation = parse(&argv(&["rg", "-inw", "-g*.rs", "-m2", "x"])).unwrap();
        assert!(invocation.options.line_number);
        assert!(invocation.options.word);
        assert_eq!(invocation.options.case, Case::Insensitive);
        assert_eq!(invocation.options.globs, vec!["*.rs"]);
        assert_eq!(invocation.options.max_count, Some(2));
        assert_eq!(invocation.pattern.as_deref(), Some("x"));
    }

    #[test]
    fn the_double_dash_stops_flag_parsing() {
        let invocation = parse(&argv(&["rg", "--", "--flag"])).unwrap();
        assert_eq!(invocation.pattern.as_deref(), Some("--flag"));
        assert!(invocation.paths.is_empty());
    }

    #[test]
    fn context_options_are_parsed() {
        let invocation = parse(&argv(&["rg", "-C", "2", "-A", "4", "x"])).unwrap();
        assert_eq!(invocation.options.before, 2);
        assert_eq!(invocation.options.after, 4);
    }

    #[test]
    fn sizes_and_depths_are_parsed() {
        let invocation =
            parse(&argv(&["rg", "--max-filesize=10K", "--max-depth", "3", "x"])).unwrap();
        assert_eq!(invocation.options.max_filesize, Some(10 * 1024));
        assert_eq!(invocation.options.max_depth, Some(3));
    }

    #[test]
    fn missing_patterns_and_values_are_usage_errors() {
        assert!(parse(&argv(&["rg", "--json"])).is_err());
        assert!(parse(&argv(&["rg", "--glob"])).is_err());
        assert!(parse(&argv(&["rg", "--sort=sideways", "x"])).is_err());
        assert!(parse(&argv(&["rg", "--no-ignore=yes", "x"])).is_err());
        assert!(parse(&argv(&["rg", "--nonsense", "x"])).is_err());
    }

    #[test]
    fn repeated_u_levels_disable_ignore_then_hidden_then_binary() {
        let invocation = parse(&argv(&["rg", "-uuu", "x"])).unwrap();
        assert!(invocation.options.no_ignore);
        assert!(invocation.options.hidden);
        assert!(invocation.options.binary_text);
    }
}
