// SPDX-License-Identifier: MIT
//! Detection of a single top-level pipeline for the WASI pipe workaround.
//!
//! This is deliberately conservative: only a script whose whole program is
//! one pipeline of two or more commands is executed stage by stage by the
//! runner. Anything else (a pipeline inside a loop, inside a command
//! substitution, combined with `&&`/`||`, timed or asynchronous) goes through
//! the normal brush path and therefore fails on wasm32-wasip1 with the
//! released brush-core.

use brush_core::{Shell, extensions};
use brush_parser::Parser;
use brush_parser::ast;

/// A top-level pipeline that the runner can execute stage by stage.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PipelinePlan {
    /// The rendered source of each stage, in pipeline order.
    pub stages: Vec<String>,
    /// True when the pipeline was prefixed with `!`.
    pub negate: bool,
}

/// Returns a plan for a script that is exactly one top-level pipeline.
#[must_use]
pub fn single_pipeline_stages(
    shell: &Shell<extensions::DefaultShellExtensions>,
    script: &str,
) -> Option<PipelinePlan> {
    let options = shell.parser_options();
    let mut parser = Parser::new(script.as_bytes(), &options);
    let program = parser.parse_program().ok()?;
    plan_for_program(&program)
}

fn plan_for_program(program: &ast::Program) -> Option<PipelinePlan> {
    if program.complete_commands.len() != 1 {
        return None;
    }
    let complete = &program.complete_commands[0];
    if complete.0.len() != 1 {
        return None;
    }
    let item = &complete.0[0];
    if !matches!(item.1, ast::SeparatorOperator::Sequence) {
        // A background pipeline has different waiting semantics.
        return None;
    }
    let and_or = &item.0;
    if !and_or.additional.is_empty() {
        return None;
    }
    let pipeline = &and_or.first;
    if pipeline.timed.is_some() || pipeline.seq.len() < 2 {
        return None;
    }
    Some(PipelinePlan {
        stages: pipeline.seq.iter().map(ToString::to_string).collect(),
        negate: pipeline.bang,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plan(script: &str) -> Option<PipelinePlan> {
        let options = brush_parser::ParserOptions::default();
        let mut parser = Parser::new(script.as_bytes(), &options);
        let program = parser.parse_program().ok()?;
        plan_for_program(&program)
    }

    #[test]
    fn a_top_level_pipeline_is_split() {
        let plan = plan("echo hi | cat").expect("pipeline");
        assert_eq!(plan.stages, vec!["echo hi", "cat"]);
        assert!(!plan.negate);
    }

    #[test]
    fn three_stages_are_kept_in_order() {
        let plan = plan("echo a b | tr ' ' '\\n' | wc -l").expect("pipeline");
        assert_eq!(plan.stages.len(), 3);
        assert_eq!(plan.stages[0], "echo a b");
    }

    #[test]
    fn a_negated_pipeline_is_marked() {
        let plan = plan("! echo hi | grep -q nope").expect("pipeline");
        assert!(plan.negate);
        assert_eq!(plan.stages.len(), 2);
    }

    #[test]
    fn a_plain_command_is_not_a_pipeline() {
        assert!(plan("echo hi").is_none());
    }

    #[test]
    fn an_and_or_list_is_not_a_plain_pipeline() {
        assert!(plan("echo hi | cat && echo done").is_none());
    }

    #[test]
    fn two_complete_commands_are_not_a_plain_pipeline() {
        assert!(plan("echo hi | cat; echo done").is_none());
    }

    #[test]
    fn a_loop_containing_a_pipeline_is_not_rewritten() {
        assert!(plan("for i in 1 2; do echo $i | cat; done").is_none());
    }

    #[test]
    fn an_asynchronous_pipeline_is_not_rewritten() {
        assert!(plan("echo hi | cat &").is_none());
    }
}
