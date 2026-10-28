// SPDX-License-Identifier: MIT
//! `echo`: deterministic output used by the core, FFI and cancellation tests.

use crate::command::{Command, EXIT_CANCELLED, EXIT_USAGE};
use crate::ctx::Ctx;

/// Writes its arguments, optionally repeated and optionally without a final
/// newline.
///
/// Usage: `echo [-n] [--repeat N] [--] [words...]`.
#[derive(Debug, Default, Clone, Copy)]
pub struct EchoCommand;

impl EchoCommand {
    /// Create the command.
    pub fn new() -> Self {
        EchoCommand
    }
}

impl Command for EchoCommand {
    fn name(&self) -> &str {
        "echo"
    }

    fn run(&self, argv: &[String], ctx: &mut Ctx<'_>) -> i32 {
        let mut repeat: u64 = 1;
        let mut newline = true;
        let mut words: Vec<String> = Vec::new();
        let mut index = 1;
        while index < argv.len() {
            match argv[index].as_str() {
                "-n" => newline = false,
                "--repeat" => {
                    index += 1;
                    let Some(value) = argv.get(index) else {
                        return usage(ctx, "echo: --repeat needs a count");
                    };
                    match value.parse::<u64>() {
                        Ok(count) => repeat = count,
                        Err(_) => return usage(ctx, "echo: --repeat needs a decimal count"),
                    }
                }
                "--" => {
                    words.extend(argv[index + 1..].iter().cloned());
                    break;
                }
                word => words.push(word.to_string()),
            }
            index += 1;
        }
        let mut line = words.join(" ");
        if newline {
            line.push('\n');
        }
        for _ in 0..repeat {
            if ctx.emit_stdout(line.as_bytes()).is_err() {
                return EXIT_CANCELLED;
            }
        }
        0
    }
}

fn usage(ctx: &mut Ctx<'_>, message: &str) -> i32 {
    let _ = ctx.emit_stderr_str(&format!("{message}\n"));
    EXIT_USAGE
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bridge::NullBridge;
    use crate::limits::Limits;
    use crate::mount::tests::TestTree;
    use crate::vfs::StdFsVfs;

    fn run(argv: &[&str], limits: Limits) -> (i32, crate::output::Output) {
        let tree = TestTree::new("echo");
        let vfs = StdFsVfs::for_root(&tree.root).unwrap();
        let bridge = NullBridge;
        let mut ctx = Ctx::new(&vfs, &bridge, "/dsh/workspace", limits);
        let argv: Vec<String> = argv.iter().map(|item| (*item).to_string()).collect();
        let code = EchoCommand.run(&argv, &mut ctx);
        let (stdout, _stderr) = ctx.finish();
        (code, stdout)
    }

    #[test]
    fn echoes_its_words_with_a_newline() {
        let (code, output) = run(&["echo", "hello", "world"], Limits::default());
        assert_eq!(code, 0);
        assert_eq!(output.data, b"hello world\n");
        assert_eq!(output.total_bytes, 12);
    }

    #[test]
    fn supports_dash_n_repeat_and_double_dash() {
        let (code, output) = run(
            &["echo", "-n", "--repeat", "3", "--", "-x"],
            Limits::default(),
        );
        assert_eq!(code, 0);
        assert_eq!(output.data, b"-x-x-x");
        assert_eq!(output.total_bytes, 6);
    }

    #[test]
    fn rejects_a_missing_repeat_count() {
        let (code, _output) = run(&["echo", "--repeat"], Limits::default());
        assert_eq!(code, EXIT_USAGE);
    }

    #[test]
    fn a_cancelled_token_returns_130_instead_of_output() {
        let tree = TestTree::new("echo-cancel");
        let vfs = StdFsVfs::for_root(&tree.root).unwrap();
        let bridge = NullBridge;
        let token = crate::cancel::CancelToken::new();
        token.cancel();
        let mut ctx =
            Ctx::new(&vfs, &bridge, "/dsh/workspace", Limits::default()).with_cancel(token);
        let argv = vec!["echo".to_string(), "ignored".to_string()];
        assert_eq!(EchoCommand.run(&argv, &mut ctx), EXIT_CANCELLED);
        assert_eq!(ctx.stdout_capture().total_bytes, 0);
    }
}
