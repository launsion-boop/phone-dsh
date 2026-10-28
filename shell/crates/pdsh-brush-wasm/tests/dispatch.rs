// SPDX-License-Identifier: MIT
//! Host-side tests for the dispatch hook and the shell runner.
//!
//! On the host `std::io::pipe` works, so these tests drive brush's real
//! pipeline implementation and prove that a dispatched command receives the
//! bytes the previous stage wrote. The wasm `echo hi | cat` smoke test lives in
//! `harness/smoke.mjs` and exercises the `/dsh/tmp` workaround instead.

use std::sync::{Arc, Mutex};

use pdsh_brush_wasm::{
    CommandRequest, CommandResult, Dispatch, DispatchError, ShellConfig, ShellRunner,
};

#[derive(Debug, Clone, PartialEq, Eq)]
struct Call {
    command: String,
    args: Vec<String>,
    stdin: String,
    cwd: String,
    env: Vec<(String, String)>,
}

#[derive(Default)]
struct RecordingDispatch {
    names: Vec<String>,
    calls: Mutex<Vec<Call>>,
    result: Mutex<CommandResult>,
    failure: Option<String>,
    cancelled: bool,
}

impl RecordingDispatch {
    fn with_names(names: &[&str]) -> Arc<Self> {
        Arc::new(Self {
            names: names.iter().map(|name| (*name).to_string()).collect(),
            ..Self::default()
        })
    }

    fn failing(message: &str) -> Arc<Self> {
        Arc::new(Self {
            names: vec!["mytool".to_string()],
            failure: Some(message.to_string()),
            ..Self::default()
        })
    }

    fn calls(&self) -> Vec<Call> {
        self.calls.lock().expect("calls").clone()
    }

    fn set_result(&self, result: CommandResult) {
        *self.result.lock().expect("result") = result;
    }
}

impl Dispatch for RecordingDispatch {
    fn command_names(&self) -> Vec<String> {
        self.names.clone()
    }

    fn execute(&self, request: CommandRequest<'_>) -> Result<CommandResult, DispatchError> {
        self.calls.lock().expect("calls").push(Call {
            command: request.command.to_string(),
            args: request.args.to_vec(),
            stdin: String::from_utf8_lossy(request.stdin).into_owned(),
            cwd: request.cwd.clone(),
            env: request.env.clone(),
        });
        if let Some(message) = &self.failure {
            return Err(DispatchError(message.clone()));
        }
        Ok(self.result.lock().expect("result").clone())
    }

    fn is_cancelled(&self) -> bool {
        self.cancelled
    }
}

/// Shared scratch working directory for the tests in this process.
fn scratch_dir() -> std::path::PathBuf {
    use std::sync::OnceLock;
    static DIRECTORY: OnceLock<std::path::PathBuf> = OnceLock::new();
    DIRECTORY
        .get_or_init(|| {
            let path = std::env::temp_dir().join(format!("pdsh-brush-tests-{}", std::process::id()));
            std::fs::create_dir_all(&path).expect("scratch dir");
            path
        })
        .clone()
}

/// Builds a shell whose working directory is the shared scratch directory.
fn runner(dispatch: Arc<RecordingDispatch>) -> ShellRunner {
    ShellRunner::with_config(
        dispatch,
        ShellConfig {
            working_dir: scratch_dir(),
            env: Vec::new(),
        },
    )
    .expect("shell builds")
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

#[test]
fn dispatches_a_pipeline_stage_and_feeds_it_stdin() {
    let dispatch = RecordingDispatch::with_names(&["cat"]);
    dispatch.set_result(CommandResult {
        exit_code: 0,
        stdout: b"hi\n".to_vec(),
        stderr: Vec::new(),
    });
    let mut shell = runner(dispatch.clone());

    let outcome = shell.run("echo hi | cat").expect("pipeline runs");

    assert_eq!(outcome.exit_code, 0);
    assert_eq!(text(&outcome.stdout), "hi\n");
    let calls = dispatch.calls();
    assert_eq!(calls.len(), 1, "cat must be dispatched once");
    assert_eq!(calls[0].command, "cat");
    assert_eq!(calls[0].stdin, "hi\n");
    assert!(calls[0].args.is_empty());
}

#[test]
fn passes_arguments_cwd_and_exported_environment() {
    let dispatch = RecordingDispatch::with_names(&["mytool"]);
    dispatch.set_result(CommandResult::default());
    let mut shell = runner(dispatch.clone());

    let outcome = shell
        .run("mytool alpha 'two words' /dsh/workspace")
        .expect("script runs");

    assert_eq!(outcome.exit_code, 0);
    let calls = dispatch.calls();
    assert_eq!(
        calls[0].args,
        vec![
            "alpha".to_string(),
            "two words".to_string(),
            "/dsh/workspace".to_string()
        ]
    );
    assert_eq!(calls[0].cwd, scratch_dir().to_string_lossy());
    assert!(calls[0].env.contains(&("HOME".to_string(), "/dsh/home".to_string())));
    assert!(calls[0].env.contains(&("TERM".to_string(), "dumb".to_string())));
    assert!(
        !calls[0]
            .env
            .iter()
            .any(|(name, _)| name == pdsh_brush_wasm::dispatch::DISPATCH_VAR),
        "the dispatch registry id is internal"
    );
}

#[test]
fn forwards_host_stdout_stderr_and_exit_status() {
    let dispatch = RecordingDispatch::with_names(&["mytool"]);
    dispatch.set_result(CommandResult {
        exit_code: 7,
        stdout: b"out\n".to_vec(),
        stderr: b"err\n".to_vec(),
    });
    let mut shell = runner(dispatch);

    let outcome = shell.run("mytool").expect("script runs");

    assert_eq!(outcome.exit_code, 7);
    assert_eq!(text(&outcome.stdout), "out\n");
    assert_eq!(text(&outcome.stderr), "err\n");
}

#[test]
fn unregistered_command_is_not_routed() {
    let dispatch = RecordingDispatch::with_names(&["cat"]);
    let mut shell = runner(dispatch.clone());

    let outcome = shell.run("nosuchcommand").expect("script runs");

    assert_eq!(outcome.exit_code, 127);
    assert!(text(&outcome.stderr).contains("command not found"));
    assert!(dispatch.calls().is_empty());
}

#[test]
fn a_host_builtin_wins_over_a_dispatch_name() {
    let dispatch = RecordingDispatch::with_names(&["echo"]);
    let mut shell = runner(dispatch.clone());

    let outcome = shell.run("echo from-builtin").expect("script runs");

    assert_eq!(outcome.exit_code, 0);
    assert_eq!(text(&outcome.stdout), "from-builtin\n");
    assert!(
        dispatch.calls().is_empty(),
        "brush's echo builtin must take precedence"
    );
}

#[test]
fn a_host_error_returns_126_and_is_reported() {
    let dispatch = RecordingDispatch::failing("the host refused");
    let mut shell = runner(dispatch);

    let outcome = shell.run("mytool").expect("script runs");

    assert_eq!(outcome.exit_code, 126);
    assert!(text(&outcome.stderr).contains("mytool: the host refused"));
}

#[test]
fn a_cancelled_host_stops_before_executing() {
    let dispatch = Arc::new(RecordingDispatch {
        names: vec!["mytool".to_string()],
        cancelled: true,
        ..RecordingDispatch::default()
    });
    let mut shell = runner(dispatch.clone());

    let outcome = shell.run("mytool").expect("script runs");

    assert_eq!(outcome.exit_code, 130);
    assert!(
        dispatch.calls().is_empty(),
        "a cancelled shell must not call the host"
    );
}

#[test]
fn runs_a_for_loop() {
    let dispatch = RecordingDispatch::with_names(&[]);
    let mut shell = runner(dispatch);

    let outcome = shell
        .run("for i in 1 2 3; do echo \"n=$i\"; done")
        .expect("loop runs");

    assert_eq!(outcome.exit_code, 0);
    assert_eq!(text(&outcome.stdout), "n=1\nn=2\nn=3\n");
}

#[test]
fn shell_state_persists_between_runs() {
    let dispatch = RecordingDispatch::with_names(&[]);
    let mut shell = runner(dispatch);

    shell.run("GREETING=hello").expect("assignment runs");
    let outcome = shell.run("echo \"$GREETING\"").expect("echo runs");

    assert_eq!(text(&outcome.stdout), "hello\n");
}

#[test]
fn a_script_can_write_and_read_the_wasi_workspace() {
    let dispatch = RecordingDispatch::with_names(&["cat"]);
    dispatch.set_result(CommandResult {
        exit_code: 0,
        stdout: b"file-body\n".to_vec(),
        stderr: Vec::new(),
    });
    let mut shell = runner(dispatch.clone());

    // The working directory is /dsh/workspace, so each test needs a unique
    // file name to stay independent of the other tests in this process.
    let outcome = shell
        .run("printf '%s\\n' body > pdsh-brush-test.txt; cat pdsh-brush-test.txt")
        .expect("script runs");

    assert_eq!(outcome.exit_code, 0);
    let calls = dispatch.calls();
    assert_eq!(calls[0].command, "cat");
    assert_eq!(calls[0].args, vec!["pdsh-brush-test.txt".to_string()]);
    let _ = std::fs::remove_file("/dsh/workspace/pdsh-brush-test.txt");
}

#[test]
fn config_controls_working_directory_and_environment() {
    let directory = std::env::temp_dir().join(format!("pdsh-brush-{}", std::process::id()));
    std::fs::create_dir_all(&directory).expect("temp dir");
    let dispatch = RecordingDispatch::with_names(&["mytool"]);
    dispatch.set_result(CommandResult::default());
    let config = ShellConfig {
        working_dir: directory.clone(),
        env: vec![("PDSH_TEST".to_string(), "value".to_string())],
    };
    let mut shell = ShellRunner::with_config(dispatch.clone(), config).expect("shell builds");

    let outcome = shell.run("mytool").expect("script runs");

    assert_eq!(outcome.exit_code, 0);
    let calls = dispatch.calls();
    assert_eq!(calls[0].cwd, directory.to_string_lossy());
    assert!(calls[0].env.contains(&("PDSH_TEST".to_string(), "value".to_string())));
    let _ = std::fs::remove_dir_all(directory);
}

#[test]
fn a_builtin_name_is_not_replaced_by_the_dispatch_table() {
    let dispatch = RecordingDispatch::with_names(&["echo"]);
    dispatch.set_result(CommandResult::default());
    let mut shell = runner(dispatch.clone());
    let outcome = shell.run("echo one").expect("script runs");
    assert_eq!(text(&outcome.stdout), "one\n");
    assert!(dispatch.calls().is_empty());
}
