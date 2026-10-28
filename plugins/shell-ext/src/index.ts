// SPDX-License-Identifier: MIT
/**
 * `@phone-dsh/dsh-shell-ext` — the Worker's bash core and long tail.
 *
 * - {@link VfsFileSystem} maps just-bash's filesystem face onto `node:fs`,
 *   which inside the Worker is the runtime's `MemoryVfs` (so writes are sink
 *   mutations) and outside it is a temporary directory for tests. It also
 *   implements the fixed Worker device set (`/dev/null`, `/dev/zero`,
 *   `/dev/urandom`) with a bounded read window, so redirections do not need a
 *   real device node below the VFS root, and resolves the one
 *   documented Worker POSIX alias `/tmp` -> `/dsh/tmp` (PLAN D4/D15), so temp
 *   staging lands in the volatile tmp root instead of failing `ENOENT`.
 * - {@link WorkerShell} runs `bash -c` with output discipline, head/tail
 *   truncation, cancellation and a wall-clock limit.
 * - {@link createArithmeticExpansionPlugin} composes just-bash's arithmetic
 *   evaluator with the shell's own parameter expansion, so `${var#pat}` and
 *   `${var:off:len}` inside `$(( ))` / `(( ))` (including after a `10#` base
 *   prefix) match bash instead of reaching variable lookup as literal names.
 * - {@link createExecBridgeAccelerators} forwards the host-advertised
 *   accelerators with `requires_mseq` and `idem_key` (PLAN D10/D12).
 * - {@link createCurlCommand} carries `curl` over the host `/v1/http` route.
 * - {@link createFindCommand} shadows just-bash's `find` so its `-type`
 *   predicate keeps the full POSIX letter/list grammar over the Worker VFS.
 * - {@link createGrepCommand} shadows just-bash's `grep` so `-I` /
 *   `--binary-files=without-match` — including inside a combined short-option
 *   cluster such as `-RIn` — skips files containing a NUL byte instead of
 *   failing with an option error.
 * - {@link createStatCommand} shadows just-bash's `stat -c` so every GNU
 *   directive the VFS can answer is expanded (and an unsupported one fails
 *   loud) instead of being echoed literally.
 * - {@link createLsCommand} shadows just-bash's long `ls` so its first column
 *   (and the `.`/`..` rows) come from the VFS mode the `stat` shim reports,
 *   instead of a hardcoded `-rw-r--r--`/`drwxr-xr-x`.
 * - {@link createRmdirCommand} shadows just-bash's `rmdir` because the pinned
 *   runtime's `node:fs` replacement has no `rmdir`/`rmdirSync`: the Worker
 *   removal is one POSIX empty-directory delete per operand and publishes the
 *   same VFS remove mutation as `rm -r`.
 * - {@link createCpCommand} adds `cp` archive/preserve semantics (`-a`, `-p`,
 *   `-d`, `--preserve=LIST`) over the bundled copy engine and restores the
 *   target mode explicitly so it is a VFS chmod mutation, not a side effect.
 * - {@link createCmpCommand} adds the POSIX byte comparison the engine never
 *   had: default first-difference report, `-s` status-only and `-l` byte
 *   listing over the Worker VFS, matching the host program's stdout/stderr
 *   bytes and 0/1/2 statuses (G2-D04).
 * - {@link createSortCommand} adds `sort -z`/`--zero-terminated`: NUL records
 *   over stdin/files with `-r -n -u -f -b -o` and `--`; without `-z` the
 *   bundled sort keeps its option surface (G2-FIX-106).
 * - {@link createDuCommand} adds the GNU `du` surface with 4 KiB allocation
 *   blocks, `-h`/`--human-readable`, `-a/-s/-c/--max-depth` and `--`
 *   (G2-FIX-109).
 * - {@link createOdCommand} shadows just-bash's `od` so `-N`/`-j` bound the
 *   bytes read and formatted instead of charging format work for the whole
 *   operand; `-t x1/o1/c`, `-c`, `-A`/`-An` and `-v` are the implemented
 *   surface, and any other format is an explicit exit-2 usage error.
 * - {@link applyGnuConventions} is the single owner of `--`, `--version` and
 *   `--help` for {@link GNU_CONVENTION_PROGRAMS} (G2-FIX-108/G2-FIX-90).
 * - {@link createRipgrepCommand} shadows just-bash's `rg` for glob searches so
 *   the DSH glob/grep tools keep ripgrep's globset contract over the VFS.
 * - {@link createJqCommand} shadows just-bash's `jq` and supplies the
 *   input-consumption family (`inputs`, `input`, `input_line_number`) by
 *   reading the document stream once and injecting the current document and
 *   remaining inputs into the built-in's evaluator (G2-FIX-130).
 * - {@link materializeCapabilityManifest} guarantees `/dsh/home/capabilities.json`
 *   exists before the first dispatch: it adopts the boot-published
 *   `pdsh-capabilities/1` document and writes the minimal fallback only when no
 *   boot entry ran, so the path a `not-available` hint names always exists in
 *   the same VFS (G2-FIX-58).
 * - {@link createGzipCommand}, {@link createGunzipCommand} and
 *   {@link createZcatCommand} shadow just-bash's node:zlib gzip family with one
 *   resolved backend (Web Compression Streams, then a real node:zlib), so a
 *   browser Worker host produces a valid member or fails loud instead of
 *   reporting an empty success.
 * - {@link createReadDecodePlugin} decodes the variables just-bash's `read`
 *   builtin leaves as byte strings, so a `while read` loop's CJK values and
 *   file names are not re-encoded when they reach stdout or a redirection
 *   (the G2-E03 byte-boundary class).
 * - {@link createWorkerCommands} is the production table: just-bash built-ins,
 *   accelerator bridges, `curl`, the Worker `git` program and the installed
 *   WASI toolbox's programs (`python3`), all inside the Worker (D12).
 * @module @phone-dsh/dsh-shell-ext
 */

export {
  VfsFileSystem,
  MAX_FILE_READ_SIZE,
  MAX_FILE_SIZE,
  WORKER_DEVICE_PATHS,
  WORKER_DEVICE_READ_BYTES,
  WORKER_PATH_ALIASES,
  WORKER_TMP_ALIAS,
  WORKER_WRITABLE_ROOTS,
} from './filesystem.ts'
export type {
  VfsDirentLike,
  VfsFileSystemIo,
  VfsFileSystemOptions,
  VfsPathAlias,
  VfsReaddirSync,
} from './filesystem.ts'
export {
  CAPABILITY_MANIFEST_FORMAT,
  capabilityManifest,
  capabilityManifestJson,
  materializeCapabilityManifest,
} from './capabilities.ts'
export type { WorkerCapabilityManifest } from './capabilities.ts'
export {
  OUTPUT_ACCOUNTING_SYMBOL,
  boundOutput,
  DEFAULT_MAX_OUTPUT_BYTES,
  maxOutputBytesFromEnv,
  mergeOutputAccounting,
  readOutputAccounting,
  withOutputAccounting,
} from './output.ts'
export {
  byteStringOutput,
  byteStringToBytes,
  bytesToByteString,
  concatBytes,
  decodeByteString,
  decodeUtf8,
  encodeUtf8,
} from './encoding.ts'
export type { ByteStringOutput } from './encoding.ts'
export type { BoundedOutput, OutputAccounting, StreamTruncation } from './output.ts'
export {
  DEFAULT_STDIN_EOF_TIMEOUT_MS,
  DEFAULT_TIMEOUT_MS,
  SHELL_DISCIPLINE_ENV,
  WorkerShell,
  commandScript,
  disciplineEnvironment,
  isShellInvocation,
  resolveShellMode,
  runShellCommand,
  shellQuote,
  shellTimeoutFromEnv,
  stdinEofTimeoutFromEnv,
} from './shell.ts'
export type { ShellMode, ShellResult, ShellRunOptions, WorkerShellOptions } from './shell.ts'
export {
  TERMINAL_FORMAT,
  TERMINAL_STATE_SYMBOL,
  readTerminalState,
  terminalHandlerEligible,
  terminalSnapshotFromResult,
} from './terminal.ts'
export type {
  TerminalArray,
  TerminalPipeline,
  TerminalState,
  TerminalTermination,
} from './terminal.ts'
export {
  WORKER_EXECUTION_LIMIT_FACT,
  WORKER_EXECUTION_LIMITS,
  workerExecutionLimitsSentence,
} from './execution-limits.ts'
export type { WorkerExecutionLimitFact, WorkerExecutionLimits } from './execution-limits.ts'
export {
  DEFAULT_SHELL_OPTIONS,
  MAX_SHELL_NESTING,
  WORKER_BASH_VERSION,
  createShellInterpreterCommands,
  parseShellInvocation,
  positionalEnvironment,
  shellOptionPrelude,
  shellProgramFor,
  shellUsage,
  shellVersion,
} from './interpreter.ts'
export type {
  ShellInvocationHost,
  ShellInvocationResult,
  ShellOptions,
  ShellPlan,
  ShellPositional,
  ShellProgram,
} from './interpreter.ts'
export {
  BASH_SOURCE_PLUGIN,
  createBashSourcePlugin,
} from './bash-source.ts'
export {
  ARITHMETIC_BASE_COMMAND,
  createArithmeticBaseCommand,
  createArithmeticExpansionPlugin,
} from './arithmetic.ts'
export {
  advertisedAccelerators,
  createAcceleratorCommands,
  createExecBridgeAccelerators,
} from './bridge.ts'
export type { AcceleratorHost, AcceleratorRequest, AcceleratorResult, ExecBridgeAcceleratorOptions } from './bridge.ts'
export {
  MAX_REDIRECTS,
  createCurlCommand,
  hostAllowed,
  parseCurlArguments,
  resolveHostProxy,
  runCurl,
} from './curl.ts'
export type { CurlOptions, HostProxy } from './curl.ts'
export {
  WORKER_SHELL_PROGRAMS,
  createWorkerCommands,
  isWorkerShellProgram,
  workerShellIdentity,
} from './commands.ts'
export type { WorkerCommandOptions } from './commands.ts'
export {
  WORKER_BIN_COMMANDS,
  WORKER_COMMAND_DIRECTORIES,
  commandEntryContent,
  commandPathsReady,
  findCommandPath,
  materializeCommandPaths,
  sanitizeCommandPath,
} from './command-paths.ts'
export { AwkUsageError, createAwkCommand, parseAwkArguments } from './awk.ts'
export {
  JQ_INPUT_FUNCTIONS,
  JQ_UNSAFE_INPUT_WORDS,
  JqShimError,
  createJqCommand,
  findUnsafeInputConsumption,
  findUnsafeInputsValueArgument,
  parseJqDocuments,
  parseJqInvocation,
  planJqShim,
  rewriteJqInputFunctions,
  scanJqInputReferences,
} from './jq.ts'
export type { JqDocument, JqInputReference, JqInvocation, JqShimPlan } from './jq.ts'
export { CMP_USAGE, CmpUsageError, createCmpCommand, parseCmpArguments } from './cmp.ts'
export {
  CpUsageError,
  createCpCommand,
  hasCpArchiveArguments,
  parseCpArguments,
} from './cp.ts'
export type { CpArguments, CpPreserveAttribute } from './cp.ts'
export type { CmpArguments, CmpMode } from './cmp.ts'
export {
  DU_BLOCK_BYTES,
  DU_HELP,
  JUST_BASH_VERSION,
  DuUsageError,
  allocatedBytes,
  createDuCommand,
  formatHuman,
  parseDuArguments,
} from './du.ts'
export type { DuArguments } from './du.ts'
export {
  GNU_CONVENTION_PROGRAMS,
  GNU_CONVENTION_VERSION,
  GNU_CONVENTION_WRAPPED,
  applyGnuConventions,
  applyGnuTerminator,
  isGnuConventionWrapper,
  scanGnuArgv,
} from './gnu-conventions.ts'
export type { GnuArgvScan } from './gnu-conventions.ts'
export {
  OD_MAX_UNRANGED_READ_BYTES,
  OdUsageError,
  createOdCommand,
  formatOdWindow,
  parseOdArguments,
  parseOdByteCount,
} from './od.ts'
export type { OdAddressRadix, OdArguments, OdFormat } from './od.ts'
export {
  SortUsageError,
  createSortCommand,
  parseSortArguments,
  splitNulRecords,
} from './sort.ts'
export type { SortArguments } from './sort.ts'
export {
  CanonicalizeError,
  canonicalizePath,
  createReadlinkCommand,
  createRealpathCommand,
} from './path-commands.ts'
export type { CanonicalizeMode } from './path-commands.ts'
export {
  RMDIR_HELP,
  RmdirUsageError,
  createRmdirCommand,
  parseRmdirArguments,
} from './rmdir.ts'
export type { RmdirArguments } from './rmdir.ts'
export {
  TarError,
  createTarCommand,
  parseTarArguments,
  readTarArchive,
} from './tar.ts'
export {
  GzipBackendUnavailableError,
  createGunzipCommand,
  createGzipCommand,
  createZcatCommand,
  isGzipMember,
  resolveGzipBackend,
} from './gzip.ts'
export type {
  GzipBackend,
  GzipBackendOptions,
  GzipStreamConstructor,
  GzipZlib,
} from './gzip.ts'
export { createToolboxCommands, guestCwdFor, toolboxCommandNames } from './toolbox-commands.ts'
export {
  READ_DECODE_COMMAND,
  READ_DECODE_PLUGIN,
  createReadDecodeCommand,
  createReadDecodePlugin,
  readTargetNames,
} from './read-encoding.ts'
export {
  DEFAULT_TRAP_COMMAND,
  TRAP_EXIT_SIGNAL,
  TRAP_SCOPE_SYMBOL,
  TRAP_TOKEN_ENV,
  clearTrapHandler,
  clearTrapState,
  createTrapCommand,
  createTrapToken,
  getTrapHandler,
  isDefaultTrapCommand,
  listTrapHandlers,
  setTrapHandler,
  trapSignalList,
} from './trap.ts'
export {
  SHELL_MANIFEST_PATH,
  SHELL_REASONS,
  SHELL_REASON_EXIT,
  SHELL_TRAILER_PREFIX,
  UNAVAILABLE_PROGRAMS,
  appendShellTrailer,
  classifyFailure,
  extractFailureProgram,
  hasShellTrailer,
  notAvailableTrailer,
  parseShellTrailer,
  shellFailure,
  trailerCommand,
  trailerLine,
  truncationAnnotation,
  unavailableHint,
  withCommandExit,
  withShellTrailer,
} from './contract.ts'
export type { ShellFailureOptions, ShellReason, ShellTrailer } from './contract.ts'
export {
  FIND_PRINTF_DIRECTIVES,
  FindFormatError,
  POSIX_FIND_TYPE_LETTERS,
  createFindCommand,
  planFindInvocation,
  renderFindFormat,
  rewriteFindTypeArguments,
} from './find.ts'
export type { FindFormatEntry, FindPlan } from './find.ts'
export {
  createGrepCommand,
  createWithoutMatchFileSystem,
  stripGrepBinaryOptions,
} from './grep.ts'
export type { StrippedGrepOptions } from './grep.ts'
export { LsUsageError, createLsCommand, parseLsArguments, requestsLongFormat } from './ls.ts'
export type { LsInvocation, LsOptions } from './ls.ts'
export {
  STAT_FORMAT_SPECIFIERS,
  StatFormatError,
  WORKER_STAT_FALLBACKS,
  createStatCommand,
  formatStat,
  formatStatTime,
  formatSymbolicMode,
  parseStatFormat,
} from './stat.ts'
export type { StatFormatToken } from './stat.ts'
export {
  RipgrepGlobError,
  RipgrepGlobSet,
  createRipgrepCommand,
  parseRipgrepGlobs,
} from './ripgrep.ts'
export type { ParsedRipgrepGlobs, RipgrepGlobPattern } from './ripgrep.ts'
export {
  CORPUS_STUB_PROGRAMS,
  createCorpusHostCommands,
  createCorpusStub,
  createWhichCommand,
} from './corpus.ts'
