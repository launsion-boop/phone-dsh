// SPDX-License-Identifier: MIT
/**
 * Apply the phone-DSH terminal-state seam to the installed just-bash 3.6.0
 * browser bundle.
 *
 * just-bash is Apache-2.0 and is consumed as an ordinary npm dependency
 * (`just-bash/browser`), not vendored. The published browser bundle is
 * minified and does not ship the interpreter source, so the seam is a narrow,
 * byte-guarded rewrite of the one installed `dist/bundle/browser.js`. Every
 * replacement is asserted by exact count; the pristine bundle is identified by
 * its SHA-256 and the result must equal {@link PATCHED_SHA256}. A different
 * version, licence or byte image is refused instead of patched heuristically.
 *
 * The patch is idempotent. `plugins/package.json` runs it after `npm ci`
 * (postinstall) and before typecheck/test, and the image packer imports it
 * before staging just-bash, so a fresh install cannot build an unpatched
 * Worker.
 *
 * Provenance and the Apache-2.0 notice are recorded in
 * `shell-ext/THIRD_PARTY.md` and `plugins/THIRD_PARTY.md`.
 */
import { createHash } from 'node:crypto'
import { existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const pluginsRoot = resolve(here, '..', '..')
const packageRoot = join(pluginsRoot, 'node_modules', 'just-bash')
const packageFile = join(packageRoot, 'package.json')
const bundleFile = join(packageRoot, 'dist', 'bundle', 'browser.js')

/** The exact npm image this patch was written against. */
const ORIGINAL_SHA256 = '38f1ad1e3283980ecdf68cede8a4eed028c6dff6e8c31793dec1e0af529c446e'
/** The deterministic result of applying every replacement below. */
const PATCHED_SHA256 = '124182d76319a5a7c542f4014362f0eba7aa66af9f0a1665574594f0c628e018'
/** Marker that must exist exactly once in a patched bundle. */
const PATCH_MARKER = 'const __pdshTerminalFormat="just-bash-terminal/1";'

/** One stable file hash. */
function sha256(text) {
  return createHash('sha256').update(text).digest('hex')
}

/** A patch error that the installer reports without a stack trace. */
class PatchError extends Error {}

/** Fail with a precise guard mismatch. */
function refuse(message) {
  throw new PatchError(message)
}

/**
 * Apply one literal replacement and assert its occurrence count.
 * @param {string} source - current bundle text (closed over by the caller).
 * @param {string} label - human-readable replacement name.
 * @param {string} from - exact pristine text.
 * @param {string} to - replacement text.
 * @param {number} count - required occurrence count.
 * @returns {string} the rewritten bundle.
 */
function replace(source, label, from, to, count = 1) {
  const found = source.split(from).length - 1
  if (found !== count) {
    refuse(`${label}: expected ${String(count)} exact occurrence(s), found ${String(found)}`)
  }
  return source.split(from).join(to)
}

/** The seam helper functions appended before the public export. */
const HELPER = String.raw`
const __pdshTerminalKey=Symbol.for("@phone-dsh/just-bash/terminal-state/v1");
const __pdshCauseKey=Symbol.for("@phone-dsh/just-bash/terminal-cause/v1");
const __pdshPipelineKey=Symbol.for("@phone-dsh/just-bash/last-pipeline/v1");
const __pdshTruncKey=Symbol.for("@phone-dsh/just-bash/output-truncation/v1");
const __pdshSeedKey=Symbol.for("@phone-dsh/just-bash/terminal-seed/v1");
const __pdshTerminalFormat="just-bash-terminal/1";
function __pdshMergeStream(a,b){if(!a)return b;if(!b)return a;return {dropped:a.dropped+b.dropped,markerBytes:a.markerBytes+b.markerBytes}}
function __pdshMergeTrunc(a,b){if(!a)return b;if(!b)return a;const o={stdout:__pdshMergeStream(a.stdout,b.stdout),stderr:__pdshMergeStream(a.stderr,b.stderr)};return o.stdout||o.stderr?o:void 0}
let __pdshTrapScopeSeq=0;function __pdshNextTrapScope(){return "stage-"+(++__pdshTrapScopeSeq).toString(36)}function __pdshScopeId(e){return e.__pdshTrapScope?e.__pdshTrapScope+(e.bashPid===e.virtualPid?"":":"+String(e.bashPid)):e.bashPid===e.virtualPid?"root":String(e.bashPid)}
function __pdshClassifyError(e){if(e instanceof RangeError)return "engine-range";const n=e&&e.name;if(n==="ExecutionLimitError")return "execution-limit";if(n==="ExecutionAbortedError")return "aborted";if(n==="SecurityViolationError")return "security";if(n==="ParseException"||n==="LexerError")return "parse";if(n==="ExitError")return "exit";if(n==="PosixFatalError")return "posix-fatal";if(n==="ArithmeticError")return "arithmetic-fatal";if(n==="NounsetError")return "nounset";if(n==="BadSubstitutionError")return "bad-substitution";if(n==="BraceExpansionError")return "brace-expansion";if(n==="ErrexitError")return "errexit";return "engine-error"}
function __pdshRootCause(c){return ["readonly-fatal","expansion-fatal","posix-fatal","nounset","bad-substitution","arithmetic-fatal","brace-expansion","errexit","execution-limit","aborted"].includes(c)?c:"exit"}
function __pdshSnapshot(e){return {env:[...e.env.entries()],arrays:qn(e.arrays),cwd:e.cwd,previousDir:e.previousDir,functions:new Map(e.functions),options:{...e.options},shoptOptions:{...e.shoptOptions},exportedVars:[...(e.exportedVars||[])],readonlyVars:[...(e.readonlyVars||[])],associativeArrays:[...(e.associativeArrays||[])],integerVars:[...(e.integerVars||[])],lowercaseVars:[...(e.lowercaseVars||[])],uppercaseVars:[...(e.uppercaseVars||[])],namerefs:[...(e.namerefs||[])],boundNamerefs:[...(e.boundNamerefs||[])],invalidNamerefs:[...(e.invalidNamerefs||[])],declaredVars:[...(e.declaredVars||[])],fullyUnsetLocals:e.fullyUnsetLocals?new Map(e.fullyUnsetLocals):void 0,directoryStack:[...(e.directoryStack||[])],lastExitCode:e.lastExitCode,lastArg:e.lastArg,bashPid:e.bashPid,hashTable:e.hashTable?new Map(e.hashTable):void 0}}
function __pdshArrays(e){const o=Object.create(null);if(!e||!e.arrays)return o;for(const [n,a] of e.arrays)o[n]={kind:a.kind,values:[...a.elements.entries()].map(([k,v])=>[k,typeof v==="string"?v:String(v)])};return o}
function __pdshChooseCause(instance,stateCause){const serious=new Set(["security","parse","execution-limit","aborted","engine-range","engine-error"]);if(instance&&serious.has(instance))return instance;return stateCause||instance||"root-return"}
function __pdshTerminalResult(result,state,instanceCause){if(!result||typeof result!=="object")return result;const stateCause=state&&state[__pdshCauseKey];const cause=__pdshChooseCause(instanceCause,stateCause);const unwound=!!state&&(state.localScopes?.length??0)===0&&(state.callDepth??0)===0;const tempPending=!!state&&((state.tempEnvBindings?.length??0)>0||(state.mutatedTempEnvVars?.size??0)>0);const authoritative=!!state&&unwound&&!tempPending;const last=state&&state[__pdshPipelineKey];let pipeStatus=Array.isArray(last?.statuses)?[...last.statuses]:[];if(!pipeStatus.length&&state&&state.arrays?.get("PIPESTATUS"))pipeStatus=[...state.arrays.get("PIPESTATUS").elements.entries()].sort((a,b)=>Number(a[0])-Number(b[0])).map(([,v])=>Number.parseInt(v,10)||0);const fatal=["expansion-fatal","readonly-fatal","nounset","bad-substitution","arithmetic-fatal","brace-expansion","posix-fatal"].includes(cause);const stale=cause==="completed"&&!!last&&typeof last.status==="number"&&last.status!==result.exitCode;if(fatal||stale||!pipeStatus.length)pipeStatus=[result.exitCode];const pipeline={statuses:pipeStatus,status:result.exitCode,negated:!!last?.negated};const terminal={format:__pdshTerminalFormat,authority:"engine",engine:{name:"just-bash",version:"3.6.0",seam:"phone-dsh/terminal-state/1"},authoritative,cause,termination:cause==="completed"?"completed":cause==="errexit"?"errexit":cause==="exit"?"explicit-exit":["security","parse","execution-limit","aborted","engine-range","engine-error","cleanup-failed"].includes(cause)?"not-ordinary":"fatal-unwind",status:result.exitCode,cwd:state?state.cwd:void 0,pwdVariable:state?state.env.get("PWD"):void 0,env:state?Object.fromEntries(state.env):void 0,options:state?{...state.options}:void 0,shopt:state?{...state.shoptOptions}:void 0,functions:state?[...state.functions.keys()].sort():[],arrays:__pdshArrays(state),pipeline,lastExitCode:state?state.lastExitCode:void 0,unwound,unsupportedReason:authoritative?void 0:state?tempPending?"temporary command environment was not unwound":"terminal state still has an active function/local scope":"engine returned before the root execution state existed"};const metadata=result.metadata&&typeof result.metadata==="object"?{...result.metadata}:{};metadata.terminal=terminal;const out=authoritative?{...result,env:terminal.env,metadata}:{...result,metadata};const snapshot=state?__pdshSnapshot(state):void 0;if(snapshot)Object.defineProperty(out,__pdshTerminalKey,{value:snapshot,enumerable:false,configurable:false});return out}
`

/** The exact pristine-to-patched transform list. */
function patchBundle(source) {
  let text = source
  text = replace(text, 'declare local execution state', 'let a=f=>l?this.logResult(f):f', 'let m,a=f=>l?this.logResult(f):f')
  // A cloned shell state must carry the terminal cause too. Command
  // substitution, subshells, source/eval and pipeline stages all use `th`;
  // without this, a typed fatal that a child catches would survive its own
  // unwind and later turn the root's explicit `exit N` into fatal-unwind.
  text = replace(text, 'carry the terminal cause through state clones', 'function th(e){let t={env:e.env,arrays:e.arrays,', 'function th(e){let t={env:e.env,arrays:e.arrays,[__pdshCauseKey]:e[__pdshCauseKey],')

  text = replace(text, 'fatal returns use the local state', 'env:Nn(this.state.env,u.env)', 'env:Nn(m?m.env:this.state.env,u.env)', 12)

  const stateBefore = 'let m={...this.state,env:h,arrays:u.replaceEnv?new Map:qn(this.state.arrays),cwd:p,previousDir:u.env?.OLDPWD??this.state.previousDir,functions:new Map(this.state.functions),localScopes:[...this.state.localScopes],options:{...this.state.options},hashTable:this.state.hashTable,groupStdin:m$(u.stdin,u.stdinKind,this.limits.maxInputBytes,this.limits.maxStringLength,r,o),signal:u.signal,extraArgs:u.args}'
  const stateAfter = `m={...this.state,env:h,arrays:u.replaceEnv?new Map:qn(this.state.arrays),cwd:p,previousDir:u.env?.OLDPWD??this.state.previousDir,functions:new Map(this.state.functions),localScopes:[...this.state.localScopes],options:{...this.state.options},hashTable:this.state.hashTable,groupStdin:m$(u.stdin,u.stdinKind,this.limits.maxInputBytes,this.limits.maxStringLength,r,o),signal:u.signal,extraArgs:u.args};if(s===0){this.__pdshTerminalState=m;this.__pdshTerminalCause="root-return";const __ts=n&&n[__pdshTerminalKey];if(__ts){m.env=new Map(__ts.env);m.arrays=qn(__ts.arrays);m.cwd=__ts.cwd;m.previousDir=__ts.previousDir;m.functions=new Map(__ts.functions);m.options={...__ts.options};m.shoptOptions={...__ts.shoptOptions};m.exportedVars=new Set(__ts.exportedVars);m.readonlyVars=new Set(__ts.readonlyVars);m.associativeArrays=new Set(__ts.associativeArrays);m.integerVars=new Set(__ts.integerVars);m.lowercaseVars=new Set(__ts.lowercaseVars);m.uppercaseVars=new Set(__ts.uppercaseVars);m.namerefs=new Set(__ts.namerefs);m.boundNamerefs=new Set(__ts.boundNamerefs);m.invalidNamerefs=new Set(__ts.invalidNamerefs);m.declaredVars=new Set(__ts.declaredVars);m.fullyUnsetLocals=__ts.fullyUnsetLocals;m.directoryStack=[...(__ts.directoryStack||[])];m.lastExitCode=__ts.lastExitCode;m.lastArg=__ts.lastArg;m.bashPid=__ts.bashPid??m.bashPid;m.localScopes=[];m.localArrayScopes=[];m.localVarDepth=void 0;m.localVarStack=void 0;m.localExportedVars=void 0;m.tempExportedVars=void 0;m.tempEnvBindings=void 0;m.mutatedTempEnvVars=void 0;m.accessedTempEnvVars=void 0;m.hashTable=__ts.hashTable?new Map(__ts.hashTable):m.hashTable;}const __seed=n&&n[__pdshSeedKey];if(__seed){__seed.sourceStagePath!==void 0&&(m.__pdshSourceStagePath=__seed.sourceStagePath);if(typeof __seed.status==="number"){m.lastExitCode=__seed.status;m.env.set("?",String(__seed.status));if(Array.isArray(__seed.pipeStatus)){m.arrays=qn(m.arrays);const __pa={kind:"indexed",elements:new Map()};for(let __i=0;__i<__seed.pipeStatus.length;__i++)__pa.elements.set(String(__i),String(__seed.pipeStatus[__i]));m.arrays.set("PIPESTATUS",__pa)}}if(__seed.options)Object.assign(m.options,__seed.options);if(__seed.shopt)Object.assign(m.shoptOptions,__seed.shopt);}}`
  text = replace(text, 'capture root state and restore a handler snapshot', stateBefore, stateAfter)
  text = replace(text, 'derive the statement list after the state', ',g=t;u.rawScript', ';let g=t;u.rawScript')

  text = replace(text, 'reset the per-exec terminal capture', 'async exec(t,n){let r=new kl(this.limits,n?.signal),s;', 'async exec(t,n){this.__pdshTerminalState=void 0;this.__pdshTerminalCause=t.trim()?"root-return":"empty-script";let r=new kl(this.limits,n?.signal),s;')
  text = replace(text, 'attach terminal metadata to the root result', 'return t.trim()?this.logResult(i):i}', 'return __pdshTerminalResult(t.trim()?this.logResult(i):i,this.__pdshTerminalState??(t.trim()?void 0:this.state),this.__pdshTerminalCause)}')

  text = replace(text, 'classify the inner root catch', '}catch(w){if(w instanceof ge)return', '}catch(w){this.__pdshTerminalCause=__pdshClassifyError(w);if(w instanceof ge)return')
  text = replace(text, 'classify the outer root catch', '}catch(f){if(f instanceof Me)return', '}catch(f){this.__pdshTerminalCause=__pdshClassifyError(f);if(f instanceof Me)return')

  // A root `exit N` always wins. Only a typed fatal that is unwinding the
  // current root (the readonly/expansion markers set before the throw) keeps
  // its cause; a stale child marker restored by a clone must not.
  text = replace(text, 'record explicit exit/errexit/fatal causes in executeScript', 'if(i instanceof ge)throw i.prependOutput', 'if(i instanceof ge)throw this.ctx.state[__pdshCauseKey]=__pdshRootCause(this.ctx.state[__pdshCauseKey]),i.prependOutput')
  text = replace(text, 'record typed executeScript causes', 'if(i instanceof dn)return', 'i instanceof dn?this.ctx.state[__pdshCauseKey]="posix-fatal":i instanceof C?this.ctx.state[__pdshCauseKey]="execution-limit":i instanceof Qt?this.ctx.state[__pdshCauseKey]="errexit":i instanceof Yt?this.ctx.state[__pdshCauseKey]="nounset":i instanceof tn?this.ctx.state[__pdshCauseKey]="bad-substitution":i instanceof Ve?this.ctx.state[__pdshCauseKey]="arithmetic-fatal":i instanceof si?this.ctx.state[__pdshCauseKey]="brace-expansion":i instanceof Me?this.ctx.state[__pdshCauseKey]="aborted":0;if(i instanceof dn)return')
  text = replace(text, 'mark a completed root script', 'return{...r.build(n),env:Wt(this.ctx.state.env)}}async executeUserScript', 'return this.ctx.state[__pdshCauseKey]="completed",{...r.build(n),env:Wt(this.ctx.state.env)}}async executeUserScript')

  text = replace(text, 'restore a command-prefix environment before a fatal throw', '}catch(N){if(N instanceof Kt||N instanceof Xt)E=N,S=Le;else throw N}', '}catch(N){if(N instanceof Kt||N instanceof Xt)E=N,S=Le;else{for(let[__n,__v]of i)__v===void 0?this.ctx.state.env.delete(__n):this.ctx.state.env.set(__n,__v);if(this.ctx.state.tempExportedVars)for(let __n of i.keys())this.ctx.state.tempExportedVars.delete(__n);i.size>0&&this.ctx.state.tempEnvBindings&&this.ctx.state.tempEnvBindings.pop();throw N}}')

  text = replace(text, 'restore a command-prefix environment when argument expansion fails', '}else for(let N of t.args){let $=await dr(this.ctx,N);for(let T of $.values)p(T,$.quoted)}let m=t.name.parts.every', '}else try{for(let N of t.args){let $=await dr(this.ctx,N);for(let T of $.values)p(T,$.quoted)}}catch(__e){l();throw __e}let m=t.name.parts.every')

  text = replace(text, 'mark readonly fatal before throw', 'function st(e,t,n="bash"){if(un(e,t)){let r=`${n}: ${t}: readonly variable\n`;throw new ge(1,"",r)}return null}', 'function st(e,t,n="bash"){if(un(e,t)){let r=`${n}: ${t}: readonly variable\n`;e.state[__pdshCauseKey]="readonly-fatal";throw new ge(1,"",r)}return null}')
  text = replace(text, 'mark expansion fatal before throw', 'let o=n.word?await s(e,n.word.parts,r.inDoubleQuotes):`${t}: parameter null or not set`;throw new ge(1,"",`bash: ${o}\n`)}return r.effectiveValue}async function Dw', 'let o=n.word?await s(e,n.word.parts,r.inDoubleQuotes):`${t}: parameter null or not set`;e.state[__pdshCauseKey]="expansion-fatal";throw new ge(1,"",`bash: ${o}\n`)}return r.effectiveValue}async function Dw')
  text = replace(text, 'mark cannot-assign fatal before throw', 'function Pd(e){if(/^(?:\\d+|[@*#?$!-])$/.test(e))throw new ge(1,"",`bash: $${e}: cannot assign in this way\n`)}', 'function Pd(e,t){if(/^(?:\\d+|[@*#?$!-])$/.test(e)){t.state[__pdshCauseKey]="expansion-fatal";throw new ge(1,"",`bash: $${e}: cannot assign in this way\n`)}}')
  text = replace(text, 'pass the execution state to the cannot-assign fatal in assign-default', '(i&&Pd(t),i&&n.word)', '(i&&Pd(t,e),i&&n.word)')
  text = replace(text, 'pass the execution state to the cannot-assign fatal in use-alternative', 'n.type==="AssignDefault"&&Pd(t.parameter)', 'n.type==="AssignDefault"&&Pd(t.parameter,e)')

  // Command substitution is a real subshell for the shell namespace too. The
  // engine saved only env/arrays/cwd, so functions, options, shopt, readonly
  // attributes and local scopes previously survived `$(...)` and let the EXIT
  // snapshot inherit child state. `th` is the engine's own full
  // beginIsolatedShellState clone/rollback; it covers all of those maps while
  // leaving process-wide execution accounting shared.
  text = replace(text, 'isolate command substitution namespace state', 'let s=e.state.bashPid;e.state.bashPid=e.state.nextVirtualPid++;let i=new Map(e.state.env),o=qn(e.state.arrays),l=e.state.cwd,a=e.state.suppressVerbose;', 'let __pdshRestore=th(e.state),s=e.state.bashPid,a=e.state.suppressVerbose;e.state.bashPid=e.state.nextVirtualPid++;')
  text = replace(text, 'restore command substitution namespace state', 'e.state.env=i,e.state.arrays=o,e.state.cwd=l,e.state.suppressVerbose=a,ls(e.state,u)', '__pdshRestore(),e.state.suppressVerbose=a,ls(e.state,u)')
  text = replace(text, 'restore command substitution namespace state on error', 'if(e.state.env=i,e.state.arrays=o,e.state.cwd=l,e.state.bashPid=s,e.state.suppressVerbose=a,c instanceof C)', 'if(__pdshRestore(),e.state.suppressVerbose=a,c instanceof C)')
  text = replace(text, 'isolate command substitution namespace before changing shell pid', 'let a=e.state.bashPid;e.state.bashPid=e.state.nextVirtualPid++;let c=new Map(e.state.env),u=qn(e.state.arrays),f=e.state.cwd,d=e.state.suppressVerbose;', 'let __pdshRestore=th(e.state),a=e.state.bashPid;e.state.bashPid=e.state.nextVirtualPid++;let d=e.state.suppressVerbose;')
  text = replace(text, 'restore command substitution namespace state in the interpreter', 'e.state.env=c,e.state.arrays=u,e.state.cwd=f,e.state.suppressVerbose=d,ls(e.state,h)', '__pdshRestore(),e.state.suppressVerbose=d,ls(e.state,h)')
  text = replace(text, 'restore command substitution namespace state in the interpreter error path', 'if(e.state.env=c,e.state.arrays=u,e.state.cwd=f,e.state.bashPid=a,e.substitutionDepth=l,e.state.suppressVerbose=d,p instanceof C)throw p;', 'if(__pdshRestore(),e.state.suppressVerbose=d,e.substitutionDepth=l,p instanceof C)throw p;')

  // A plain `local B` (no assignment, no -a) must still snapshot the array
  // cell. Otherwise `local B; B=(secret)` writes into the global array map and
  // the function return/fatal unwind cannot restore the caller's array.
  text = replace(text, 'snapshot a local array for a plain local declaration', 'r.set(p,x),c&&i(p)', 'r.set(p,x),i(p)')
  text = replace(text, 'snapshot a local array for a plain declare/typeset declaration', 'if(r||s?E(O):S(O),a){', 'if(E(O),a){')

  // Give the trap builtin a real shell-scope identity. The root state keeps
  // the constructor pid; every subshell, background job and command
  // substitution gets a fresh bashPid, while a function call keeps the
  // current shell's pid. This is engine state, not user-visible text/env.
  text = replace(text, 'expose the shell scope to the trap builtin', 'invokeTool:i.invokeTool},g=u.internalOriginalCommand', 'invokeTool:i.invokeTool,[Symbol.for("@phone-dsh/just-bash/trap-scope/v1")]:__pdshScopeId(i.state)},g=u.internalOriginalCommand')

  // Every non-lastpipe stage of a multi-command pipeline is a subshell in
  // POSIX, including a stage whose command word is only known at expansion
  // time (`$g | cat`) or a known builtin shadowed by eval/source. The engine
  // used to snapshot only env/arrays, so cwd/options/shopt/functions/local
  // scopes leaked to the parent and the EXIT handler could run in the child's
  // cwd. Use the engine's own full state clone (`th`) for each such stage and
  // restore it in the finally clause. The last stage stays shared when
  // lastpipe is enabled, preserving lastpipe's variable/cwd semantics. A
  // separate trap scope keeps a dynamic stage from clearing the root handler.
  text = replace(text, 'begin an isolated state for each pipeline stage', 'let E=u&&(!x||!e.state.shoptOptions.lastpipe),A=E?new Map(e.state.env):null,I=E?qn(e.state.arrays):null,R,N=e.executionScope.outputBytesUsed;', 'let E=u&&(!x||!e.state.shoptOptions.lastpipe),__pstate=E?th(e.state):null,R,N=e.executionScope.outputBytesUsed;')
  // Typed fatals only become an ordinary stage result in a stage that really
  // runs in a child shell. The last `lastpipe` stage and a single-command
  // pipeline execute in the root shell; their fatal must unwind the root.
  // POSIX special-builtin failures are the same child-local case, with the
  // engine-provided exit code and diagnostic preserved.
  text = replace(text, 'contain typed pipeline-stage fatals', 'catch($){if($ instanceof tn)R={stdout:$.stdout,stderr:$.stderr,exitCode:1};else if($ instanceof ge&&t.commands.length>1)R={stdout:$.stdout,stderr:$.stderr,exitCode:$.exitCode};else if($ instanceof Qt&&t.commands.length>1)R={stdout:$.stdout,stderr:$.stderr,exitCode:$.exitCode};else throw A&&(e.state.env=A,e.state.arrays=I??new Map),$}', 'catch($){if(E&&t.commands.length>1&&$ instanceof tn)R={stdout:$.stdout,stderr:$.stderr,exitCode:1};else if(E&&t.commands.length>1&&$ instanceof Yt)R={stdout:$.stdout,stderr:$.stderr,exitCode:127};else if(E&&t.commands.length>1&&$ instanceof Ve)R={stdout:$.stdout,stderr:$.stderr,exitCode:1};else if(E&&t.commands.length>1&&$ instanceof si)R={stdout:$.stdout,stderr:$.stderr,exitCode:1};else if(E&&t.commands.length>1&&$ instanceof dn)R={stdout:$.stdout,stderr:$.stderr,exitCode:$.exitCode};else if(E&&t.commands.length>1&&$ instanceof ge)R={stdout:$.stdout,stderr:$.stderr,exitCode:e.state[__pdshCauseKey]==="expansion-fatal"||e.state[__pdshCauseKey]==="nounset"?127:$.exitCode};else if(E&&t.commands.length>1&&$ instanceof Qt)R={stdout:$.stdout,stderr:$.stderr,exitCode:$.exitCode};else throw $}')
  text = replace(text, 'start an isolated trap scope for each pipeline stage', 'R,N=e.executionScope.outputBytesUsed;try{', 'R,N=e.executionScope.outputBytesUsed,__ptrap=e.state.__pdshTrapScope;E&&(e.state.__pdshTrapScope=__pdshNextTrapScope());try{')
  text = replace(text, 'restore the full pipeline stage state and trap scope', 'finally{u&&(S&&(d=e.state.groupStdin,p=e.state.groupStdinSourceFd),e.state.groupStdin=d,e.state.groupStdinSourceFd=p)}', 'finally{__pstate&&__pstate(),e.state.__pdshTrapScope=__ptrap,u&&(S&&(d=e.state.groupStdin,p=e.state.groupStdinSourceFd),e.state.groupStdin=d,e.state.groupStdinSourceFd=p)}')
  text = replace(text, 'drop the per-stage env/array restore', 'if(A&&(e.state.env=A,e.state.arrays=I??new Map),R=e.executionScope.accountResult', 'if(R=e.executionScope.accountResult')

  text = replace(text, 'record the last completed pipeline', 'i=e.executionScope.accountResult(i,"pipeline");let{internalPipeStatusOverride:g,...b}=i;return b}', 'e.state[__pdshPipelineKey]={statuses:[...l],status:i.exitCode,negated:t.negated===!0};i=e.executionScope.accountResult(i,"pipeline");let{internalPipeStatusOverride:g,...b}=i;return b}')

  // Producer-owned output facts travel with the result object and are folded
  // only into builders whose bytes really reach the final stream. User text
  // that looks like a marker is ordinary text.
  text = replace(text, 'accumulate trusted truncation facts in a result builder', 'this.append("stderr",t.stderr,t.internalOutputAccounting?.stderr??0)}build(t,n){return{', 'this.append("stderr",t.stderr,t.internalOutputAccounting?.stderr??0);const __tr=t&&t[__pdshTruncKey];__tr&&(this.__pdshTrunc=__pdshMergeTrunc(this.__pdshTrunc,__tr))}build(t,n){let __b={')
  text = replace(text, 'return trusted truncation facts from a result builder', 'internalOutputAccounting:{stdout:this.stdoutBytes,stderr:this.stderrBytes}}}get stdout()', 'internalOutputAccounting:{stdout:this.stdoutBytes,stderr:this.stderrBytes}};return this.__pdshTrunc&&(__b[__pdshTruncKey]=this.__pdshTrunc),__b}get stdout()')
  text = replace(text, 'drop truncation facts from redirected streams', 'else t.internalOutputAccounting&&(y.internalOutputAccounting=t.internalOutputAccounting);return y}', 'else t.internalOutputAccounting&&(y.internalOutputAccounting=t.internalOutputAccounting);const __tr=t[__pdshTruncKey];if(__tr){const __c={};__tr.stdout&&y.stdout!==""&&(__c.stdout=__tr.stdout);__tr.stderr&&y.stderr!==""&&(__c.stderr=__tr.stderr);(__c.stdout||__c.stderr)&&(y[__pdshTruncKey]=__c)}return y}')

  // A pass-through pipeline stage (e.g. `cat`) forwards the previous stage's
  // trusted facts; a transforming stage drops them. Stderr accumulates.
  text = replace(text, 'track pipeline pass-through accounting', 'p=e.state.groupStdinSourceFd;for(let y=0;y<t.commands.length;y++){let w=t.commands[y],x=y===t.commands.length-1,S=y===0;', 'p=e.state.groupStdinSourceFd,__pt=null,__pe=null,__own,__out;for(let y=0;y<t.commands.length;y++){let __pin=s,__ptr=__pt,w=t.commands[y],x=y===t.commands.length-1,S=y===0;')
  text = replace(text, 'merge pass-through pipeline accounting', 'R=e.executionScope.accountResult(R,"pipeline",e.executionScope.outputBytesUsed-N),!x){', '__own=R&&R[__pdshTruncKey],__pe=__pdshMergeTrunc(__pe,__own&&__own.stderr?{stderr:__own.stderr}:void 0),__out=__own&&__own.stdout?{stdout:__own.stdout}:void 0,Vr(R)===__pin&&(__out=__pdshMergeTrunc(__ptr,__out)),__pt=__out,x&&(__own=__pdshMergeTrunc(__out,__pe),__own&&(R[__pdshTruncKey]=__own)),!x){')

  // Compound constructs collect their body in a builder. The statement
  // collector already forwarded trusted facts, but the simpler compound
  // builder did not, so `if`/loops/case dropped a producer's facts even though
  // its bytes reached the live stream. Give that builder the same
  // result-aware append path.
  text = replace(text, 'carry trusted facts in the compound output builder', 'var bs=class{ctx;stdoutChunks=[];stderrChunks=[];totalBytes=0;', 'var bs=class{ctx;stdoutChunks=[];stderrChunks=[];totalBytes=0;__pdshTrunc;')
  text = replace(text, 'append a result with trusted facts to a compound builder', 'appendUnaccounted(t,n){', 'appendResult(t,n=t.stdout){this.append(n,t.stderr);const __tr=t&&t[__pdshTruncKey];__tr&&(this.__pdshTrunc=__pdshMergeTrunc(this.__pdshTrunc,__tr))}replaceResult(t){this.stdoutChunks=[],this.stderrChunks=[],this.totalBytes=0,this.__pdshTrunc=void 0,this.appendResult(t)}appendUnaccounted(t,n){')
  text = replace(text, 'return trusted facts from a compound builder', 'build(t){let n=this.stdout,r=this.stderr;return{stdout:n,stderr:r,exitCode:t,internalOutputAccounting:{stdout:M(n),stderr:M(r)}}}};async function Yp', 'build(t){let n=this.stdout,r=this.stderr,__b={stdout:n,stderr:r,exitCode:t,internalOutputAccounting:{stdout:M(n),stderr:M(r)}};return this.__pdshTrunc&&(__b[__pdshTruncKey]=this.__pdshTrunc),__b}};async function Yp')
  text = replace(text, 'forward trusted facts from a compound body', 'n.append(i.stdout,i.stderr),r=i.exitCode', 'n.appendResult(i),r=i.exitCode')
  text = replace(text, 'forward trusted facts from an if condition', 'n.append(s.stdout,s.stderr)', 'n.appendResult(s)')
  text = replace(text, 'forward trusted facts from a for body', 'n.append(a.stdout,a.stderr),r=a.exitCode', 'n.appendResult(a),r=a.exitCode')
  text = replace(text, 'forward trusted facts from a C-style for body', 'r.append(l.stdout,l.stderr),s=l.exitCode', 'r.appendResult(l),s=l.exitCode')
  text = replace(text, 'forward trusted facts from a while condition', 's.append(h.stdout,h.stderr),c=h.exitCode', 's.appendResult(h),c=h.exitCode')
  text = replace(text, 'forward trusted facts from a while body', 's.append(h.stdout,h.stderr),i=h.exitCode', 's.appendResult(h),i=h.exitCode')
  text = replace(text, 'forward trusted facts from a loop break/continue', 's.append(p.stdout,p.stderr)', 's.appendResult(p)', 2)
  text = replace(text, 'forward trusted facts from an until condition', 's.append(c.stdout,c.stderr),c.exitCode===0', 's.appendResult(c),c.exitCode===0')
  text = replace(text, 'forward trusted facts from an until body', 's.append(f.stdout,f.stderr),i=f.exitCode', 's.appendResult(f),i=f.exitCode')
  text = replace(text, 'replace a case body with its trusted facts', 'if(n.replace(c.stdout,c.stderr),r=c.exitCode', 'if(n.replaceResult(c),r=c.exitCode')

  // The patched source/eval builtins apply this shell's transform plugins to
  // their own text, so no hidden prepare command/variable or extra xtrace line
  // is needed. The source builtin also stages the transformed text at the
  // per-execution private path supplied by the terminal seed.
  text = replace(text, 'pass transformText through the interpreter context', 'requireDefenseContext:t.requireDefenseContext??!1,jsBootstrapCode:t.jsBootstrapCode,invokeTool:t.invokeTool}}', 'requireDefenseContext:t.requireDefenseContext??!1,jsBootstrapCode:t.jsBootstrapCode,invokeTool:t.invokeTool,transformText:t.transformText}}')
  text = replace(text, 'supply transformText to interpreter contexts', 'requireDefenseContext:b?.isEnabled()===!0,jsBootstrapCode:this.jsBootstrapCode,invokeTool:this.invokeToolFn}', 'requireDefenseContext:b?.isEnabled()===!0,jsBootstrapCode:this.jsBootstrapCode,invokeTool:this.invokeToolFn,transformText:(__t)=>this.transform(__t).script}')
  text = replace(text, 'transform sourced text and stage it privately', 'if(i===null)return K(`bash: ${r}: No such file or directory\n`);let o=new Map;', 'if(i!==null&&e.transformText){try{i=e.transformText(i)}catch(__e){if(__e.name==="ParseException")return K(`bash: ${r}: ${__e.message}\n`);throw __e}}if(i!==null&&e.state.__pdshSourceStagePath){try{await e.fs.mkdir("/dsh/tmp",{recursive:!0}),await e.fs.writeFile(e.state.__pdshSourceStagePath,i,"utf8")}catch(__e){return K(`bash: ${r}: ${__e instanceof Error?__e.message:String(__e)}\n`,1)}}if(i===null)return K(`bash: ${r}: No such file or directory\n`);let o=new Map;')
  text = replace(text, 'transform eval text before parsing', 'let i=s.join(" ");if(i.trim()==="")return Le;let o=e.state.groupStdin', 'let i=s.join(" ");if(i.trim()==="")return Le;if(e.transformText){try{i=e.transformText(i)}catch(__e){if(__e.name==="ParseException")return K(`bash: eval: ${__e.message}\n`);throw __e}}let o=e.state.groupStdin')

  text = replace(text, 'install the terminal-state helper', 'export{ch as Bash,', HELPER + 'export{ch as Bash,')
  return text
}

/** Verify the installed package identity before touching bytes. */
function verifyPackage() {
  if (!existsSync(packageFile)) {
    refuse(`just-bash is not installed at ${packageRoot}; run npm ci before patching`)
  }
  const manifest = JSON.parse(readFileSync(packageFile, 'utf8'))
  if (manifest.name !== 'just-bash' || manifest.version !== '3.6.0' || manifest.license !== 'Apache-2.0') {
    refuse(`unexpected just-bash image: name=${String(manifest.name)} version=${String(manifest.version)} license=${String(manifest.license)}; expected just-bash 3.6.0 Apache-2.0`)
  }
}

/** Apply or verify the patch, returning whether bytes were written. */
function main() {
  verifyPackage()
  const source = readFileSync(bundleFile, 'utf8')
  const hash = sha256(source)
  if (hash === PATCHED_SHA256) {
    if (source.split(PATCH_MARKER).length - 1 !== 1) {
      refuse('patched just-bash is missing or duplicates the terminal-state marker')
    }
    process.stdout.write('shell-ext: just-bash terminal-state seam already applied\n')
    return
  }
  if (hash !== ORIGINAL_SHA256) {
    refuse(`unexpected just-bash bundle sha256 ${hash}; expected pristine ${ORIGINAL_SHA256} or patched ${PATCHED_SHA256}`)
  }
  const patched = patchBundle(source)
  const result = sha256(patched)
  if (result !== PATCHED_SHA256) {
    refuse(`patch produced sha256 ${result}; expected ${PATCHED_SHA256}; refusing to write an unverified bundle`)
  }
  const temporary = `${bundleFile}.phone-dsh-patch`
  writeFileSync(temporary, patched, 'utf8')
  renameSync(temporary, bundleFile)
  process.stdout.write('shell-ext: applied just-bash terminal-state seam\n')
}

try {
  main()
} catch (error) {
  if (error instanceof PatchError) {
    process.stderr.write(`shell-ext: ${error.message}\n`)
    process.exit(1)
  }
  throw error
}
