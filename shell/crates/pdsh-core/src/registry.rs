// SPDX-License-Identifier: MIT
//! Name-to-command registry and the capability JSON it produces.

use std::collections::BTreeMap;

use crate::caps::Caps;
use crate::command::Command;
use crate::commands::{CapsCommand, EchoCommand};
use crate::ctx::Ctx;
use crate::error::{Error, Result};
use crate::limits::Limits;

/// A set of read-only commands keyed by accelerator name.
pub struct Registry {
    commands: BTreeMap<String, Box<dyn Command>>,
    accelerators: Vec<String>,
    version: String,
}

impl Registry {
    /// An empty registry with the given version string.
    pub fn new(version: impl Into<String>) -> Self {
        Registry {
            commands: BTreeMap::new(),
            accelerators: Vec::new(),
            version: version.into(),
        }
    }

    /// A registry with the two built-in test commands (`echo`, `pdsh-caps`).
    ///
    /// Neither command is advertised; the production registry that links the
    /// real accelerators registers them with [`Registry::register_accelerator`].
    pub fn with_defaults() -> Self {
        let mut registry = Registry::new(env!("CARGO_PKG_VERSION"));
        registry.register(Box::new(EchoCommand::new()));
        registry.register(Box::new(CapsCommand::new()));
        registry
    }

    /// Register a command without advertising it as an accelerator.
    ///
    /// Returns the previous command under the same name, if any.
    pub fn register(&mut self, command: Box<dyn Command>) -> Option<Box<dyn Command>> {
        self.commands.insert(command.name().to_string(), command)
    }

    /// Register a command and advertise its name to the host.
    pub fn register_accelerator(&mut self, command: Box<dyn Command>) {
        let name = command.name().to_string();
        self.register(command);
        if !self.accelerators.contains(&name) {
            self.accelerators.push(name);
        }
    }

    /// All registered command names, sorted.
    pub fn names(&self) -> Vec<String> {
        self.commands.keys().cloned().collect()
    }

    /// Advertised accelerator names, sorted.
    pub fn accelerator_names(&self) -> Vec<String> {
        self.caps().accelerators
    }

    /// Look up a command.
    pub fn get(&self, name: &str) -> Option<&dyn Command> {
        self.commands.get(name).map(Box::as_ref)
    }

    /// The version string of this registry.
    pub fn version(&self) -> &str {
        &self.version
    }

    /// Build the capability object.
    pub fn caps(&self) -> Caps {
        Caps::new(self.accelerators.clone(), self.version.clone())
    }

    /// Render the capabilities JSON for the given limits.
    pub fn caps_json(&self, limits: &Limits) -> String {
        self.caps().json(limits)
    }

    /// Run `name` with `argv` (including `argv[0]`).
    ///
    /// The registry installs its capability object on the context first, so
    /// `pdsh-caps` always reports the registry that is actually executing.
    pub fn run(&self, name: &str, argv: &[String], ctx: &mut Ctx<'_>) -> Result<i32> {
        if argv.is_empty() || argv.first().map(String::as_str) != Some(name) {
            return Err(Error::InvalidRequest(format!(
                "argv[0] must equal the command name {name:?}"
            )));
        }
        ctx.check_cancel()?;
        ctx.set_caps(self.caps());
        let command = self
            .commands
            .get(name)
            .ok_or_else(|| Error::UnknownCommand(name.to_string()))?;
        Ok(command.run(argv, ctx))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bridge::NullBridge;
    use crate::command::EXIT_CANCELLED;
    use crate::ctx::Ctx;
    use crate::mount::tests::TestTree;
    use crate::vfs::StdFsVfs;
    use std::sync::mpsc;

    struct ConstantCommand {
        name: &'static str,
        text: &'static str,
    }

    impl Command for ConstantCommand {
        fn name(&self) -> &str {
            self.name
        }

        fn run(&self, _argv: &[String], ctx: &mut Ctx<'_>) -> i32 {
            match ctx.emit_stdout_str(self.text) {
                Ok(()) => 0,
                Err(_) => EXIT_CANCELLED,
            }
        }
    }

    fn run_registry(
        registry: &Registry,
        argv: &[&str],
        limits: Limits,
        cancel: Option<crate::cancel::CancelToken>,
    ) -> (Result<i32>, crate::output::Output, crate::output::Output) {
        let tree = TestTree::new("registry");
        let vfs = StdFsVfs::for_root(&tree.root).unwrap();
        let bridge = NullBridge;
        let mut ctx = Ctx::new(&vfs, &bridge, "/dsh/workspace", limits);
        if let Some(cancel) = cancel {
            ctx = ctx.with_cancel(cancel);
        }
        let argv: Vec<String> = argv.iter().map(|item| (*item).to_string()).collect();
        let result = registry.run(&argv[0], &argv, &mut ctx);
        let (stdout, stderr) = ctx.finish();
        (result, stdout, stderr)
    }

    #[test]
    fn defaults_register_echo_and_caps_but_advertise_nothing() {
        let registry = Registry::with_defaults();
        assert_eq!(registry.names(), vec!["echo", "pdsh-caps"]);
        assert!(registry.accelerator_names().is_empty());
        let json = registry.caps_json(&Limits::default());
        assert!(json.starts_with("{\"accelerators\":[],"));
        assert!(json.contains(env!("CARGO_PKG_VERSION")));
    }

    #[test]
    fn only_registered_accelerators_are_advertised() {
        let mut registry = Registry::with_defaults();
        registry.register(Box::new(ConstantCommand {
            name: "internal",
            text: "x",
        }));
        registry.register_accelerator(Box::new(ConstantCommand {
            name: "rg",
            text: "rg",
        }));
        // `Registry::names` is the BTreeMap order, not registration order.
        assert_eq!(
            registry.names(),
            vec!["echo", "internal", "pdsh-caps", "rg"]
        );
        let caps = registry.caps();
        assert_eq!(caps.accelerators, vec!["rg"]);
        assert_eq!(caps.json(&Limits::default()).contains("\"rg\""), true);
    }

    #[test]
    fn unknown_commands_are_typed_errors() {
        let registry = Registry::with_defaults();
        let argv = vec!["nope".to_string()];
        let (result, _stdout, _stderr) =
            run_registry(&registry, &argv.iter().map(String::as_str).collect::<Vec<_>>(), Limits::default(), None);
        assert!(matches!(result, Err(Error::UnknownCommand(name)) if name == "nope"));
    }

    #[test]
    fn argv_zero_must_match_the_registered_name() {
        let registry = Registry::with_defaults();
        let tree = TestTree::new("registry-argv");
        let vfs = StdFsVfs::for_root(&tree.root).unwrap();
        let bridge = NullBridge;
        let mut ctx = Ctx::new(&vfs, &bridge, "/dsh/workspace", Limits::default());
        let argv = vec!["other".to_string()];
        let result = registry.run("echo", &argv, &mut ctx);
        assert!(matches!(result, Err(Error::InvalidRequest(_))));
    }

    #[test]
    fn pdsh_caps_prints_the_registry_capabilities() {
        let mut registry = Registry::with_defaults();
        registry.register_accelerator(Box::new(ConstantCommand {
            name: "jaq",
            text: "",
        }));
        let (result, stdout, _stderr) = run_registry(
            &registry,
            &["pdsh-caps"],
            Limits::default().with_timeout_ms(1234),
            None,
        );
        assert_eq!(result.unwrap(), 0);
        let text = String::from_utf8(stdout.data).unwrap();
        assert!(text.contains("\"jaq\""));
        assert!(text.contains("\"timeout\":1234"));
        assert!(text.trim_end().ends_with('}'));
    }

    #[test]
    fn echo_runs_through_the_registry() {
        let registry = Registry::with_defaults();
        let (result, stdout, _stderr) =
            run_registry(&registry, &["echo", "hi"], Limits::default(), None);
        assert_eq!(result.unwrap(), 0);
        assert_eq!(stdout.data, b"hi\n");
    }

    struct LoopCommand {
        started: std::sync::Mutex<Option<mpsc::Sender<()>>>,
    }

    impl Command for LoopCommand {
        fn name(&self) -> &str {
            "loop"
        }

        fn run(&self, _argv: &[String], ctx: &mut Ctx<'_>) -> i32 {
            let mut ticks: u64 = 0;
            loop {
                if ctx.emit_stdout(b"tick\n").is_err() {
                    return EXIT_CANCELLED;
                }
                ticks += 1;
                if ticks == 300 {
                    if let Some(sender) = self.started.lock().unwrap().take() {
                        let _ = sender.send(());
                    }
                }
                if ctx.check_cancel().is_err() {
                    return EXIT_CANCELLED;
                }
            }
        }
    }

    #[test]
    fn cancel_stops_a_long_output_loop_mid_stream() {
        let tree = TestTree::new("registry-cancel");
        let token = crate::cancel::CancelToken::new();
        let (sender, receiver) = mpsc::channel();
        let mut registry = Registry::new("test");
        registry.register_accelerator(Box::new(LoopCommand {
            started: std::sync::Mutex::new(Some(sender)),
        }));
        let limits = Limits {
            max_output_bytes: 1024,
            ..Limits::default()
        };
        let trigger = token.clone();
        let worker = std::thread::spawn(move || {
            let vfs = StdFsVfs::for_root(&tree.root).unwrap();
            let bridge = NullBridge;
            let mut ctx = Ctx::new(&vfs, &bridge, "/dsh/workspace", limits).with_cancel(token);
            let argv = vec!["loop".to_string()];
            let result = registry.run("loop", &argv, &mut ctx);
            let (stdout, _stderr) = ctx.finish();
            (result, stdout)
        });
        receiver.recv().unwrap();
        trigger.cancel();
        let (result, stdout) = worker.join().unwrap();
        assert_eq!(result.unwrap(), EXIT_CANCELLED);
        assert!(stdout.truncated);
        assert!(stdout.total_bytes > 0);
    }
}
