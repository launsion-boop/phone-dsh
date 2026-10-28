// SPDX-License-Identifier: MIT
//! `phone` and `ctx`: host-bridge accelerators.
//!
//! The native side never talks to an MCP endpoint itself. Both commands forward
//! one tool call to the host app through [`pdsh_core::HostBridge`] and print the
//! JSON result unchanged:
//!
//! ```text
//! phone <tool> [json-args]   -> call_tool("phone.<tool>", <json-args>)
//! ctx <query>               -> call_tool("ctx.query", {"q": <query>})
//! ```
//!
//! A bridge failure is reported on stderr and exits with 69 (EX_UNAVAILABLE),
//! matching the exec-bridge error convention; a usage error exits 64 and a
//! bridge result larger than the invocation's output budget exits 65 instead of
//! printing a truncated JSON document.

use std::fmt::Write as _;

use serde_json::Value;
use pdsh_core::{Command, Ctx, Error, EXIT_CANCELLED, EXIT_USAGE};

/// Exit code for an unavailable host bridge or a failed tool call.
pub const EXIT_BRIDGE: i32 = 69;
/// Exit code for a bridge result that exceeds the output budget.
pub const EXIT_OVERSIZE: i32 = 65;

/// Longest accepted tool name.
pub const MAX_TOOL_NAME: usize = 64;

const HELP: &str = "\
phone / ctx (pdsh-shell read-only host-bridge accelerators)

USAGE:
    phone <tool> [json-args]    call the host tool phone.<tool>
    ctx <query>                 call the host tool ctx.query with {\"q\": query}

The result is printed as JSON. A bridge failure exits 69; a usage error 64;
a result larger than the output budget 65.
";

/// The `phone` accelerator.
#[derive(Debug, Default, Clone, Copy)]
pub struct PhoneCommand;

impl Command for PhoneCommand {
    fn name(&self) -> &str {
        "phone"
    }

    fn run(&self, argv: &[String], ctx: &mut Ctx<'_>) -> i32 {
        run_phone(argv, ctx)
    }
}

/// The `ctx` accelerator.
#[derive(Debug, Default, Clone, Copy)]
pub struct CtxCommand;

impl Command for CtxCommand {
    fn name(&self) -> &str {
        "ctx"
    }

    fn run(&self, argv: &[String], ctx: &mut Ctx<'_>) -> i32 {
        run_ctx(argv, ctx)
    }
}

/// Run `phone <tool> [json-args]`.
pub fn run_phone(argv: &[String], ctx: &mut Ctx<'_>) -> i32 {
    match execute_phone(argv, ctx) {
        Ok(code) => code,
        Err(Error::Cancelled) => EXIT_CANCELLED,
        Err(error) => fail(ctx, &format!("phone: {error}")),
    }
}

/// Run `ctx <query>`.
pub fn run_ctx(argv: &[String], ctx: &mut Ctx<'_>) -> i32 {
    match execute_ctx(argv, ctx) {
        Ok(code) => code,
        Err(Error::Cancelled) => EXIT_CANCELLED,
        Err(error) => fail(ctx, &format!("ctx: {error}")),
    }
}

fn fail(ctx: &mut Ctx<'_>, message: &str) -> i32 {
    let _ = ctx.emit_stderr_str(&format!("{message}\n"));
    EXIT_BRIDGE
}

fn execute_phone(argv: &[String], ctx: &mut Ctx<'_>) -> Result<i32, Error> {
    if argv.get(1).map(String::as_str) == Some("--help") || argv.get(1).map(String::as_str) == Some("-h") {
        ctx.emit_stdout_str(HELP)?;
        return Ok(0);
    }
    let Some(tool) = argv.get(1) else {
        ctx.emit_stderr_str("phone: missing tool name\n")?;
        return Ok(EXIT_USAGE);
    };
    if !valid_tool_name(tool) {
        ctx.emit_stderr_str(&format!("phone: invalid tool name {tool:?}\n"))?;
        return Ok(EXIT_USAGE);
    }
    let args_json = if argv.len() > 2 {
        argv[2..].join(" ")
    } else {
        "{}".to_string()
    };
    let args: Value = match serde_json::from_str(&args_json) {
        Ok(value) => value,
        Err(error) => {
            ctx.emit_stderr_str(&format!("phone: invalid JSON arguments: {error}\n"))?;
            return Ok(EXIT_USAGE);
        }
    };
    if !args.is_object() {
        ctx.emit_stderr_str("phone: JSON arguments must be an object\n")?;
        return Ok(EXIT_USAGE);
    }
    let name = format!("phone.{tool}");
    forward(ctx, &name, &args_json)
}

fn execute_ctx(argv: &[String], ctx: &mut Ctx<'_>) -> Result<i32, Error> {
    if argv.get(1).map(String::as_str) == Some("--help") || argv.get(1).map(String::as_str) == Some("-h") {
        ctx.emit_stdout_str(HELP)?;
        return Ok(0);
    }
    let query = argv.get(1..).map(|words| words.join(" ")).unwrap_or_default();
    let query = query.trim();
    if query.is_empty() {
        ctx.emit_stderr_str("ctx: missing query\n")?;
        return Ok(EXIT_USAGE);
    }
    let mut args_json = String::with_capacity(query.len() + 16);
    args_json.push_str("{\"q\":");
    write_json_string(&mut args_json, query);
    args_json.push('}');
    forward(ctx, "ctx.query", &args_json)
}

fn forward(ctx: &mut Ctx<'_>, name: &str, args_json: &str) -> Result<i32, Error> {
    ctx.check_cancel()?;
    let result = match ctx.bridge().call_tool(name, args_json) {
        Ok(result) => result,
        Err(Error::Cancelled) => return Err(Error::Cancelled),
        Err(Error::Bridge(message)) => {
            ctx.emit_stderr_str(&format!("{name}: {message}\n"))?;
            return Ok(EXIT_BRIDGE);
        }
        Err(error) => {
            ctx.emit_stderr_str(&format!("{name}: {error}\n"))?;
            return Ok(EXIT_BRIDGE);
        }
    };
    let trimmed = result.trim_end_matches(['\n', '\r', ' ', '\t']);
    if trimmed.len() > ctx.limits().max_output_bytes {
        ctx.emit_stderr_str(&format!(
            "{name}: result of {} bytes exceeds the output budget of {} bytes\n",
            trimmed.len(),
            ctx.limits().max_output_bytes
        ))?;
        return Ok(EXIT_OVERSIZE);
    }
    ctx.emit_stdout_str(trimmed)?;
    ctx.emit_stdout_str("\n")?;
    Ok(0)
}

fn valid_tool_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= MAX_TOOL_NAME
        && name
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-'))
}

fn write_json_string(output: &mut String, value: &str) {
    output.push('"');
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
    output.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_names_are_restricted() {
        assert!(valid_tool_name("contacts.search"));
        assert!(valid_tool_name("calendar_list"));
        assert!(!valid_tool_name(""));
        assert!(!valid_tool_name("with space"));
        assert!(!valid_tool_name("../escape"));
        assert!(!valid_tool_name(&"x".repeat(MAX_TOOL_NAME + 1)));
    }

    #[test]
    fn query_json_is_escaped() {
        let mut output = String::new();
        write_json_string(&mut output, "a \"b\"\n");
        assert_eq!(output, "\"a \\\"b\\\"\\n\"");
        let parsed: Value = serde_json::from_str(&output).unwrap();
        assert_eq!(parsed, "a \"b\"\n");
    }
}
