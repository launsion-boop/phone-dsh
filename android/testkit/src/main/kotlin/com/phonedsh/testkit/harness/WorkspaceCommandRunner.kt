// :testkit harness — a real `workspace_command` executor for a POSIX host.
// SPDX-License-Identifier: MIT
//
// ---- what this can and cannot do ------------------------------------------
// `ScenarioExecution.runWorkspaceCommand` asks the execution to run a shell
// command against the materialized workspace. The macOS runner spawns
// `/bin/bash`; an Android device has no bash, no python3 and no git, and even
// its POSIX shell is mksh with the toybox applets on `PATH`.
//
// This runner therefore does two things, and says which one it did:
//
//   1. **Runs it for real** when the command only uses POSIX-sh control flow
//      plus the toybox coreutils subset (`grep`, `test`, `wc`, `find`, `sed`,
//      `awk`, `ls`, …). It stages a throwaway copy of the materialized tree in a
//      temporary directory, rewrites `/dsh/workspace` to that copy, spawns
//      `sh -c` with the copy as the working directory and returns the process's
//      real exit code and output. Nothing is synthesised: an exit 0 is a real
//      process's exit 0.
//   2. **Defers** (`CommandOutcome.pendingHost`) when the command needs a tool
//      this environment does not have (`git`, `python3`, `bash`, …), uses
//      bash-only syntax (`[[`, `${…}`, `<<<`, process substitution, …), or when
//      no shell could be spawned. A deferral is never a pass: the runner reports
//      it as `PENDING_HOST`, exactly the iOS-Simulator two-phase rule.
//
// ---- the executor is named in the evidence --------------------------------
// On a JVM host the shell is the host's `/bin/sh` and the tools are the host's
// coreutils, not Android's toybox: the allowlist below is the *tool set* Android
// provides, not a claim that every flag behaves identically. An evaluated
// outcome carries the executor in its detail (`host-sh /bin/sh; toybox-subset`)
// so evidence from this runner is attributable. On Android the same class
// resolves to `/system/bin/sh` and the toybox applets on `PATH`.
//
// -- not attempted yet -------------------------------------------------------
// * archive tooling (`tar`, `gzip`) and `xargs`/`find -exec` indirection;
// * Python (`python3 …`), git history and `bash script.sh` — the bulk of the
//   catalog's commands;
// * heredocs (`<<`) and here-strings: the body is not classified, so the whole
//   command is deferred rather than half-checked.

package com.phonedsh.testkit.harness

import com.phonedsh.testkit.scenario.CommandOutcome
import com.phonedsh.testkit.scenario.CommandStatus
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * The two materialized trees a `workspace_command` can see.
 *
 * [workspace] mirrors `/dsh/workspace` and [home] mirrors `/dsh/home`; both are
 * *derived* copies owned by the WAL (`wal.md` §6), never the runner's own
 * bookkeeping.
 */
public data class WorkspaceTrees(
    public val workspace: Path,
    public val home: Path,
)

/** Runs one `workspace_command` against the materialized trees. */
public fun interface WorkspaceCommandRunner {
    /**
     * Runs [command] and reports exactly what happened.
     *
     * Implementations must never return exit 0 for a command they did not run:
     * a capability gap is [CommandOutcome.pendingHost].
     */
    public fun run(command: String, trees: WorkspaceTrees): CommandOutcome
}

/**
 * The toybox-subset executor described in this file's header.
 *
 * @param shell the POSIX shell to spawn; defaults to `/system/bin/sh` when it
 *   exists (Android) and `/bin/sh` otherwise.
 * @param timeoutMillis how long a command may run before it is killed and
 *   reported as a timeout. A timeout is an evaluated failure, never a deferral,
 *   because the process really did run.
 */
public class ToyboxWorkspaceCommandRunner(
    private val shell: String = defaultHostShell(),
    private val timeoutMillis: Long = DEFAULT_TIMEOUT_MILLIS,
) : WorkspaceCommandRunner {
    override fun run(command: String, trees: WorkspaceTrees): CommandOutcome {
        val verdict = ToyboxCommandClassifier.classify(command)
        if (verdict is CommandVerdict.Deferred) {
            return CommandOutcome.pendingHost("$PENDING_PREFIX ${verdict.reason}")
        }
        if (!File(shell).canExecute()) {
            return CommandOutcome.pendingHost(
                "$PENDING_PREFIX no POSIX shell at $shell on this host; the command was not run",
            )
        }
        val sandbox = try {
            Files.createTempDirectory("pdsh-scenario-command")
        } catch (failure: IOException) {
            return CommandOutcome.pendingHost(
                "$PENDING_PREFIX no temporary directory for the workspace copy " +
                    "(${failure.javaClass.simpleName}); the command was not run",
            )
        }
        try {
            val workspaceCopy = sandbox.resolve(WORKSPACE).toAbsolutePath()
            val homeCopy = sandbox.resolve(HOME).toAbsolutePath()
            val copied = try {
                stage(trees.workspace, workspaceCopy) + stage(trees.home, homeCopy)
            } catch (failure: IOException) {
                return CommandOutcome.pendingHost(
                    "$PENDING_PREFIX the materialized tree could not be staged " +
                        "(${failure.javaClass.simpleName}); the command was not run",
                )
            }
            val rewritten = command
                .replace(VFS_WORKSPACE, workspaceCopy.toString())
                .replace(VFS_HOME, homeCopy.toString())
            val banner = "host-sh $shell; toybox-subset command; $copied file(s) copied from the materialized tree"
            val process = try {
                ProcessBuilder(shell, "-c", rewritten)
                    .directory(workspaceCopy.toFile())
                    .redirectErrorStream(true)
                    .start()
            } catch (failure: IOException) {
                return CommandOutcome.pendingHost(
                    "$PENDING_PREFIX the shell $shell could not be spawned " +
                        "(${failure.javaClass.simpleName}); the command was not run",
                )
            }
            val captured = ByteArrayOutputStream()
            val pump = thread(isDaemon = true, name = "pdsh-scenario-command") {
                try {
                    process.inputStream.use { stream -> stream.copyTo(captured) }
                } catch (_: IOException) {
                    // The output is best-effort diagnostics; the exit code is the verdict.
                }
            }
            val finished = try {
                process.waitFor(timeoutMillis, TimeUnit.MILLISECONDS)
            } catch (interrupted: InterruptedException) {
                Thread.currentThread().interrupt()
                process.destroyForcibly()
                return CommandOutcome.pendingHost(
                    "$PENDING_PREFIX the command run was interrupted before it finished",
                )
            }
            if (!finished) {
                process.destroyForcibly()
                process.waitFor(FORCE_KILL_GRACE_MILLIS, TimeUnit.MILLISECONDS)
                pump.join(FORCE_KILL_GRACE_MILLIS)
                return CommandOutcome(
                    exitCode = -1,
                    stdout = tail(captured.toByteArray()),
                    timedOut = true,
                    status = CommandStatus.EVALUATED,
                    detail = "timed out after $timeoutMillis ms ($banner)",
                )
            }
            pump.join(PUMP_JOIN_MILLIS)
            val exitCode = process.exitValue()
            val output = tail(captured.toByteArray())
            return CommandOutcome(
                exitCode = exitCode,
                stdout = output,
                status = CommandStatus.EVALUATED,
                detail = if (exitCode == 0) {
                    "exit 0 ($banner)"
                } else {
                    "exit $exitCode ($banner)" + if (output.isEmpty()) "" else ": $output"
                },
            )
        } finally {
            deleteBestEffort(sandbox)
        }
    }

    private companion object {
        const val WORKSPACE = "workspace"
        const val HOME = "home"
        const val VFS_WORKSPACE = "/dsh/workspace"
        const val VFS_HOME = "/dsh/home"
        const val PENDING_PREFIX = "pending_host:"
        const val FORCE_KILL_GRACE_MILLIS = 2_000L
        const val PUMP_JOIN_MILLIS = 5_000L

        /** Enough for a 300k-line `wc` to finish; a real command is not a stress test. */
        const val DEFAULT_TIMEOUT_MILLIS = 60_000L

        fun defaultHostShell(): String =
            listOf("/system/bin/sh", "/bin/sh").firstOrNull { File(it).canExecute() } ?: "/bin/sh"

        /**
         * Copies every regular file below [from] into [to], preserving relative
         * paths and bytes. Returns the file count.
         *
         * A symlink is deliberately not followed: the D4 workspace grammar has
         * no symlinks, and a test must not be able to make a command read
         * outside the throwaway copy.
         */
        fun stage(from: Path, to: Path): Int {
            if (!Files.isDirectory(from, LinkOption.NOFOLLOW_LINKS)) return 0
            Files.createDirectories(to)
            var count = 0
            Files.walk(from).use { stream ->
                for (source in stream) {
                    val relative = from.relativize(source).toString()
                    if (relative.isEmpty()) continue
                    val target = to.resolve(relative)
                    when {
                        Files.isDirectory(source, LinkOption.NOFOLLOW_LINKS) ->
                            Files.createDirectories(target)

                        Files.isRegularFile(source, LinkOption.NOFOLLOW_LINKS) -> {
                            target.parent?.let { Files.createDirectories(it) }
                            Files.copy(
                                source,
                                target,
                                StandardCopyOption.REPLACE_EXISTING,
                                StandardCopyOption.COPY_ATTRIBUTES,
                            )
                            count += 1
                        }
                    }
                }
            }
            return count
        }

        fun deleteBestEffort(root: Path) {
            try {
                Files.walk(root).use { stream ->
                    stream.sorted(Comparator.reverseOrder<Path>()).forEach { Files.deleteIfExists(it) }
                }
            } catch (_: IOException) {
                // A failed cleanup is not a verdict; the OS removes the temp dir.
            }
        }

        /** One line of diagnostics, capped so a verdict detail stays readable. */
        fun tail(bytes: ByteArray): String =
            bytes.toString(Charsets.UTF_8).trim().replace(WHITESPACE, " ").take(MAX_DETAIL_CHARS)

        val WHITESPACE = Regex("\\s+")
        const val MAX_DETAIL_CHARS = 400
    }
}

// ---------------------------------------------------------------------------
// Classification
// ---------------------------------------------------------------------------

/** The classifier's answer for one command string. */
internal sealed interface CommandVerdict {
    /** The command is within the POSIX-sh + toybox subset and may be spawned. */
    data object Supported : CommandVerdict

    /** The command cannot be run here; [reason] is user-facing evidence. */
    data class Deferred(val reason: String) : CommandVerdict
}

/**
 * Decides whether [ToyboxWorkspaceCommandRunner] may spawn a command.
 *
 * The rule is deliberately conservative in one direction only: a false
 * deferral costs a `pending_host` row, while a false "supported" would make the
 * host's coreutils answer for a device it is not. So three independent checks
 * must all pass:
 *
 * 1. no host-only tool name appears **anywhere** in the command (this catches
 *    `eval "git …"`, `xargs python3`, `awk "… system(…)"`);
 * 2. no bash-only syntax appears (Android's shell is mksh, not bash);
 * 3. every word in a command position is a toybox applet or a POSIX builtin,
 *    scanning inside `$(…)` and backtick substitutions too.
 */
internal object ToyboxCommandClassifier {
    /** The external commands an Android host really has (toybox applets). */
    val ALLOWED_TOOLS: Set<String> = setOf(
        "awk", "basename", "cat", "chmod", "cksum", "cmp", "comm", "cp", "cut", "date",
        "df", "diff", "dirname", "du", "echo", "expr", "false", "find", "grep", "head",
        "id", "ln", "ls", "md5sum", "mkdir", "mv", "od", "printf", "pwd", "readlink",
        "realpath", "rm", "sed", "seq", "sha1sum", "sha256sum", "sleep", "sort", "stat",
        "tail", "tee", "test", "touch", "tr", "true", "uniq", "wc",
    )

    /** The POSIX builtins this runner is willing to rely on. */
    val ALLOWED_BUILTINS: Set<String> = setOf(
        "test", "[", "cd", "exit", "read", "printf", "echo", "true", "false", ":",
        "return", "break", "continue", "shift", "set", "export", "unset", "umask",
    )

    /** Keywords that introduce a command list (`then`/`do` included). */
    private val OPEN_KEYWORDS: Set<String> =
        setOf("if", "then", "elif", "else", "while", "until", "do", "!", "time", "{")

    /** Keywords that close a command list. */
    private val CLOSE_KEYWORDS: Set<String> = setOf("fi", "done", "esac", "}")

    /**
     * Tool names an Android host does not have. Matched as whole words so
     * `grep`/`gitignore`-style substrings do not trip it, but any occurrence
     * (including inside quotes, or embedded in a path that names the tool)
     * defers: that is what stops `eval`-shaped indirection from sneaking a tool
     * past the command-name scan.
     */
    private val HOST_ONLY_TOOLS: Regex = Regex(
        "(?<![A-Za-z0-9_.-])(" +
            "git|python3?|bash|zsh|fish|sh|node|npm|npx|deno|bun|ruby|perl|php|make|cmake|" +
            "pip3?|uv|curl|wget|java|javac|kotlinc|kotlin|gradle|docker|ssh|scp|rsync|" +
            "ffmpeg|tar|gzip|xz|bzip2|7z|zip|unzip|openssl|gpg|cargo|rustc|swift|" +
            "xcodebuild|adb|xargs" +
            ")(?![A-Za-z0-9_./-])",
    )

    /** Bash-only constructs; Android's shell is mksh and toybox, not bash. */
    private val BASHISMS: List<Pair<Regex, String>> = listOf(
        Regex("\\[\\[(?!:)") to "[[ … ]] conditional",
        Regex("\\$'") to "\$'…' quoting",
        Regex("\\$\\{") to "\${…} parameter expansion",
        Regex("<<<") to "<<< here-string",
        Regex("[<>]\\(") to "process substitution",
        Regex("&>") to "&> redirection",
        Regex("\\|&") to "|& pipeline",
        Regex("\\(\\(") to "((…)) arithmetic command",
        Regex("(^|\\s)function\\s") to "function keyword",
        Regex("(^|\\s)declare\\s") to "declare builtin",
        Regex("(^|\\s)local\\s") to "local builtin",
        Regex("(^|\\s)source\\s") to "source builtin",
        Regex("(^|\\s)shopt\\b") to "shopt builtin",
        Regex("(^|\\s)mapfile\\s") to "mapfile builtin",
        Regex("(^|\\s)readarray\\s") to "readarray builtin",
        Regex("(^|\\s)select\\s") to "select loop",
        Regex("(^|\\s)coproc\\s") to "coproc",
        Regex("(^|\\s)pushd\\s") to "pushd builtin",
        Regex("(^|\\s)popd\\s") to "popd builtin",
        Regex("pipefail") to "set -o pipefail",
        Regex(";;&") to ";;& case terminator",
        Regex("<<") to "a here-document",
    )

    /** Finds `-exec`-shaped `find` indirection, which can run arbitrary programs. */
    private val FIND_INDIRECTION: Regex = Regex("-(exec|execdir|ok|okdir|delete|fprint|fls)\\b")

    /** Classifies [command]; the returned verdict never guesses. */
    fun classify(command: String): CommandVerdict {
        if (command.isBlank()) {
            return CommandVerdict.Deferred("the command is empty")
        }
        HOST_ONLY_TOOLS.find(command)?.let { match ->
            val tool = match.groupValues[1]
            return CommandVerdict.Deferred(
                "the command invokes `$tool`, which an Android host cannot run " +
                    "(no bash/python3/git); only the toybox coreutils subset is attempted",
            )
        }
        for ((pattern, name) in BASHISMS) {
            if (pattern.containsMatchIn(command)) {
                return CommandVerdict.Deferred(
                    "the command uses bash-only syntax ($name); an Android host runs " +
                        "mksh and toybox, not bash",
                )
            }
        }
        FIND_INDIRECTION.find(command)?.let { match ->
            return CommandVerdict.Deferred(
                "the command uses `find ${match.groupValues[1]}`, which runs another " +
                    "program this runner cannot classify",
            )
        }
        return when (val reason = checkStatements(command)) {
            null -> CommandVerdict.Supported
            else -> CommandVerdict.Deferred(reason)
        }
    }

    /**
     * Validates one shell text (the whole command or one `$(…)` body) and
     * returns the first reason it cannot be run, or `null` when it can.
     */
    private fun checkStatements(text: String): String? {
        val tokens = ArrayList<ShellToken>()
        ShellScanner(text, tokens).let { scanner ->
            scanner.fill()?.let { return it }
        }
        return validateCommands(tokens)
    }

    private fun validateCommands(tokens: List<ShellToken>): String? {
        var expectCommand = true
        var forState = ForState.NONE
        var index = 0
        var sawCommand = false
        while (index < tokens.size) {
            when (val token = tokens[index]) {
                is ShellToken.Separator -> {
                    expectCommand = true
                    if (token.text != "|" && token.text != "&&" && token.text != "||") forState = ForState.NONE
                    index += 1
                }

                ShellToken.Redirection -> index += 1

                is ShellToken.Word -> {
                    val word = token.text
                    index += 1
                    when {
                        forState == ForState.VARIABLE -> {
                            forState = ForState.LIST
                            expectCommand = false
                        }

                        forState == ForState.LIST -> {
                            if (word == "do") {
                                forState = ForState.NONE
                                expectCommand = true
                            }
                            // Every other word in the `in …` list is data.
                        }

                        // An argument is never a keyword: `test ! -e x` must not
                        // read `!` as command-position negation.
                        !expectCommand -> Unit

                        word == "for" || word == "select" || word == "case" -> {
                            forState = ForState.VARIABLE
                            expectCommand = false
                        }

                        word in OPEN_KEYWORDS -> expectCommand = true

                        word in CLOSE_KEYWORDS -> expectCommand = false

                        ASSIGNMENT.matches(word) -> expectCommand = true

                        else -> {
                            val name = word
                            if (name.startsWith("-")) {
                                return "the command starts a statement with the option `$name`"
                            }
                            if (name.contains('/')) {
                                return "the command invokes `$name` by path; only bare " +
                                    "toybox applet names are attempted"
                            }
                            if (name !in ALLOWED_TOOLS && name !in ALLOWED_BUILTINS) {
                                return "the command `$name` is not in the toybox subset " +
                                    "available on an Android host"
                            }
                            sawCommand = true
                            expectCommand = false
                        }
                    }
                }
            }
        }
        return if (sawCommand) null else "the command has no statement to execute"
    }

    private enum class ForState { NONE, VARIABLE, LIST }

    private val ASSIGNMENT = Regex("[A-Za-z_][A-Za-z0-9_]*=.*")

    private sealed interface ShellToken {
        data class Word(val text: String) : ShellToken

        data class Separator(val text: String) : ShellToken

        data object Redirection : ShellToken
    }

    /**
     * A small POSIX-sh word scanner: enough to know which words sit in command
     * position, and to hand each `$(…)` / backtick body to a recursive check.
     * It is not a parser and does not evaluate anything.
     */
    private class ShellScanner(
        private val text: String,
        private val tokens: MutableList<ShellToken>,
    ) {
        private var index: Int = 0

        fun fill(): String? {
            val word = StringBuilder()
            var started = false
            while (index < text.length) {
                val c = text[index]
                when {
                    c == '\\' -> {
                        index += 1
                        if (index < text.length) {
                            word.append(text[index])
                            started = true
                            index += 1
                        }
                    }

                    c == '\'' -> {
                        val end = text.indexOf('\'', index + 1)
                        if (end < 0) return "the command has an unterminated single-quoted string"
                        word.append(text, index + 1, end)
                        started = true
                        index = end + 1
                    }

                    c == '"' -> {
                        started = true
                        readDoubleQuoted(word)?.let { return it }
                    }

                    c == '$' && index + 1 < text.length && text[index + 1] == '(' -> {
                        started = true
                        readSubstitution(word)?.let { return it }
                    }

                    c == '`' -> {
                        started = true
                        readBacktick(word)?.let { return it }
                    }

                    c == '\n' -> {
                        flush(word, started)
                        started = false
                        tokens += ShellToken.Separator("\n")
                        index += 1
                    }

                    c.isWhitespace() -> {
                        flush(word, started)
                        started = false
                        index += 1
                    }

                    c == '#' && !started -> {
                        while (index < text.length && text[index] != '\n') index += 1
                    }

                    c == ';' -> {
                        flush(word, started)
                        started = false
                        tokens += ShellToken.Separator(";")
                        index += 1
                    }

                    c == '|' -> {
                        flush(word, started)
                        started = false
                        if (index + 1 < text.length && text[index + 1] == '|') {
                            tokens += ShellToken.Separator("||")
                            index += 2
                        } else {
                            tokens += ShellToken.Separator("|")
                            index += 1
                        }
                    }

                    c == '&' -> {
                        flush(word, started)
                        started = false
                        if (index + 1 < text.length && text[index + 1] == '&') {
                            tokens += ShellToken.Separator("&&")
                            index += 2
                        } else {
                            tokens += ShellToken.Separator("&")
                            index += 1
                        }
                    }

                    c == '(' || c == ')' -> {
                        flush(word, started)
                        started = false
                        tokens += ShellToken.Separator(c.toString())
                        index += 1
                    }

                    c == '<' || c == '>' -> {
                        flush(word, started)
                        started = false
                        tokens += ShellToken.Redirection
                        index = skipRedirection()
                    }

                    else -> {
                        word.append(c)
                        started = true
                        index += 1
                    }
                }
            }
            flush(word, started)
            return null
        }

        private fun flush(word: StringBuilder, started: Boolean) {
            if (!started) return
            tokens += ShellToken.Word(word.toString())
            word.setLength(0)
        }

        private fun readDoubleQuoted(word: StringBuilder): String? {
            index += 1
            while (index < text.length) {
                val c = text[index]
                when {
                    c == '"' -> {
                        index += 1
                        return null
                    }

                    c == '\\' -> {
                        index += 1
                        if (index < text.length) {
                            word.append(text[index])
                            index += 1
                        }
                    }

                    c == '$' && index + 1 < text.length && text[index + 1] == '(' ->
                        readSubstitution(word)?.let { return it }

                    c == '`' -> readBacktick(word)?.let { return it }

                    else -> {
                        word.append(c)
                        index += 1
                    }
                }
            }
            return "the command has an unterminated double-quoted string"
        }

        private fun readSubstitution(word: StringBuilder): String? {
            val start = index + 2
            val end = findClosingParen(start)
                ?: return "the command has an unterminated \$(…) substitution"
            ToyboxCommandClassifier.checkStatements(text.substring(start, end))?.let { return it }
            word.append("\$sub")
            index = end + 1
            return null
        }

        private fun readBacktick(word: StringBuilder): String? {
            val start = index + 1
            var cursor = start
            while (cursor < text.length && text[cursor] != '`') {
                if (text[cursor] == '\\') cursor += 1
                cursor += 1
            }
            if (cursor >= text.length) return "the command has an unterminated backtick substitution"
            ToyboxCommandClassifier.checkStatements(text.substring(start, cursor))?.let { return it }
            word.append("\$sub")
            index = cursor + 1
            return null
        }

        /** The index just past the `)` matching the `(` before [start]. */
        private fun findClosingParen(start: Int): Int? {
            var depth = 1
            var cursor = start
            var quote: Char? = null
            while (cursor < text.length) {
                val c = text[cursor]
                when {
                    quote != null -> if (c == quote) quote = null
                    c == '\\' -> cursor += 1
                    c == '\'' || c == '"' -> quote = c
                    c == '(' -> depth += 1
                    c == ')' -> {
                        depth -= 1
                        if (depth == 0) return cursor
                    }
                }
                cursor += 1
            }
            return null
        }

        /** Skips the operator run plus, when there is one, its target word. */
        private fun skipRedirection(): Int {
            var cursor = index
            while (cursor < text.length && (text[cursor] == '<' || text[cursor] == '>')) cursor += 1
            if (cursor < text.length && text[cursor] == '&') {
                cursor += 1
                while (cursor < text.length && text[cursor].isDigit()) cursor += 1
                return cursor
            }
            while (cursor < text.length && text[cursor].isWhitespace()) cursor += 1
            if (cursor >= text.length) return cursor
            val next = text[cursor]
            if (next in ";&|()\n<>" || next == '`') return cursor
            var quote: Char? = null
            while (cursor < text.length) {
                val c = text[cursor]
                when {
                    quote != null -> if (c == quote) quote = null
                    c == '\\' -> cursor += 1
                    c == '\'' || c == '"' -> quote = c
                    c.isWhitespace() || c in ";&|()<>" -> return cursor
                }
                cursor += 1
            }
            return cursor
        }
    }
}
