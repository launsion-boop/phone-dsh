# PR14 bounded Linux owner-permission proof

Date: 2026-11-03. Status: ready_for_review for the bounded Linux test-process
adapter only. This is an isolated follow-up to runtime CODE3286, not a restart or
cancellation of campaign `12fd46f595df45f68c2531630d2b57ef` and not full PR14/UI
acceptance.

Review verdict: **APPROVE** (no findings). Test verdict: **PASS** (9 passed,
0 skipped, 0 failures/errors).

## Source binding

- Candidate source commit: `467d1ac886d79a2bbee5f02746853231a19a56d5`
  (`fix(android): preserve capability words and verify owner-permission fallback`),
  parent `a66eeb471490d1ffc547bd22eda4ab847ba3042a`.
- `android/tools/with-owner-fs-permissions.py`: blob
  `36be6f4bfa1f208e41e17643975d02d19eef4cce`, SHA-256
  `aca5d5e72c0e4cd6ee6e54ea1582e7b74f9e19709a4ac1de57dfe3a07426d693`.
- `android/tools/test_with_owner_fs_permissions.py`: amended follow-up blob
  `128fbe8dc0ab6cc2a68ba2e58459b7eccb732936`, SHA-256
  `81e5e1dd1c229ab62fd01a208eefe1dea891b7cf868e92d7eeab61fcd475aca5`.
  The helper blob above is unchanged from candidate `467d1ac`; only this test
  file was strengthened after independent review.
- Original helper before the correction: `90556dac`, blob
  `acfe5c6cd3cfd2e8696c98d4aeec502322baf00c`.
- Only the three approved paths were changed. Independent review found no helper
  defect; the only follow-up code change is the approved test-file strengthening,
  and this receipt is the only new file. The repository has no tracked `AGENTS.md`
  at this candidate; `CONTRIBUTING.md` and the task boundaries were followed.
- No Android toolchain or Rust rebuild was needed for this stdlib-Python-only
  change. No full JVM/Rust suite was rerun here; the old Linux 1204 JVM/53 Rust
  evidence remains historical and unrelated.

## Corrected behavior

1. **Per-word capset preservation.** `_capability_word_without_dac` selects one
   32-bit word by index and clears `CAP_DAC_OVERRIDE` (1) and
   `CAP_DAC_READ_SEARCH` (2) only when those bits belong to that word. Word 0
   loses bits 1/2; word 1 loses nothing, so unrelated high capabilities 33/34 at
   word-1 bits 1/2 (and every other non-DAC bit) are preserved. `_drop_dac_with_capset`
   builds the actual `capset` payload for CapEff, CapPrm and CapInh word by word,
   using Linux capability version 3.
2. **Self-contained fallback safety.** When `PR_CAPBSET_DROP` is denied,
   `_establish_no_new_privs` calls `PR_SET_NO_NEW_PRIVS` with 1, then
   `PR_GET_NO_NEW_PRIVS`, and requires the observed value to be exactly 1 before
   the fallback `capset` and exec. A prctl error or an unset value raises and the
   wrapper exits 2; the proof is never skipped.
3. **Command/stdio/exit semantics.** The wrapper still execs a single
   `--verify-owner-permissions` child after the capability reduction, proves
   chmod 0500 write denial there, prints the verification line to stderr, and
   then execs the requested command unchanged. `--verify-owner-permissions` on an
   undemoted root fails closed with exit 2 and no child command output.

## Required checks on actual Linux UID 0

Platform: Debian GNU/Linux 12 (bookworm), Linux
`6.11.0-29-generic #29-Ubuntu SMP PREEMPT_DYNAMIC` x86_64, UID 0/GID 0,
`CapEff=CapPrm=CapBnd=0xcb`, `NoNewPrivs=1`, `Seccomp=2`.

| Command | Exit | Result |
| --- | --- | --- |
| `python3 android/tools/test_with_owner_fs_permissions.py -v` | 0 | 9 tests run, 9 passed, 0 skipped, 0 failures/errors |
| `python3 -m py_compile android/tools/with-owner-fs-permissions.py android/tools/test_with_owner_fs_permissions.py` | 0 | both files compile |
| `git diff --check` | 0 | no whitespace errors |

Both the owner run and the independent run produced 9 passed / 0 skipped. The
earlier Mac source-bound run was 7 passed with 2 Linux-root-only skips and is not
reported here as 9 Linux passes.

## Actual kernel evidence

All checks used real Linux UID 0 child processes and a fresh `chmod 0500`
directory. No test assertion was weakened or skipped during these kernel checks,
and no capability was added; the test file was only strengthened after review
while the helper stayed byte-identical.

- **Normal root CLI.** The wrapper took the capset fallback because
  `PR_CAPBSET_DROP` is denied in this container (rc `-1`, errno `1`/`EPERM` for
  both DAC capabilities). The post-exec child reported:

  ```
  NO_NEW_PRIVS=1
  CAP_EFF=00000000000000c9
  CAP_PRM=00000000000000c9
  CAP_BND=00000000000000cb
  WRITE_DENIED (EACCES)
  COMMAND_RAN
  ```

  stderr was `test permissions: verified ordinary owner write denial`; exit was
  0 and the target file was absent. CapBnd still contains the DAC bits, but
  verified `no_new_privs` plus the current-set capset prevents the exec'd child
  from regaining them.
- **Direct `--verify-owner-permissions` on undemoted root.** Exit 2, stderr
  `test permissions: test process still bypasses read-only owner permissions`,
  stdout empty, and `COMMAND_RAN` absent. It fails closed as intended.
- **Forced-capset child.** Calling `_drop_dac_with_capset()` then exec'ing the
  reporting child changed CapPrm/CapEff from `0xcb` to `0xc9`; the child reported
  `NoNewPrivs=1`, CapEff/CapPrm `00000000000000c9` (both DAC bits clear), exit 0,
  `WRITE_DENIED (EACCES)`, `COMMAND_RAN`, and no file in the 0500 directory.
- **High-word preservation.** Because this container does not hold capabilities
  33/34, this is proved deterministically by the captured-payload regression
  rather than a local kernel fact. Its sample is
  `DAC_BITS | (1 << 33) | (1 << 34) | (1 << 40)`; the captured capset E/P/I words
  are `[(0, 0, 0), (0x106, 0x106, 0x106)]`, preserving word-1 bits 1, 2 and 8
  while clearing only the DAC bits in word 0. The same regression records the
  prctl/capset call order, requires SET then GET exactly before capset, and proves
  capset is not attempted when `PR_GET_NO_NEW_PRIVS` returns 0 or an error.
- **Writable-directory behavior.** The pass-through regression writes into a
  fresh owner `0700` directory after the adapter runs: `WRITE_SUCCEEDED`,
  exit 0, and the file exists, so ordinary owner writes are not broken.

## Independent verification

- **REVIEW:** APPROVE. Independent read-only review inspected the exact helper,
  the tests and the `90556dac` baseline. It initially found a test-coverage gap:
  the fake prctl did not prove `PR_SET_NO_NEW_PRIVS` then `PR_GET_NO_NEW_PRIVS`
  happened before capset. The approved test-only amendment now records and
  asserts that order, covers GET values 0 and -1, and asserts capset is never
  attempted on failure. Re-review of the amended worktree returned APPROVE with
  no helper defect and no further code/test change required. A second independent
  source review also returned APPROVE.
- **TEST:** Independent rerun on the amended worktree tied to candidate
  `467d1ac` returned PASS. The helper stayed byte-identical; both required test
  and compile commands exited 0 with exactly 9 passed / 0 skipped, and
  `git diff --check` exited 0. A disposable `/tmp` mutation that removed
  `_establish_no_new_privs(library.prctl)` from a copied helper made exactly the
  strengthened regression fail on the expected call-order assertion, while the
  repository helper was unchanged. The only generated artifact was gitignored
  `android/tools/__pycache__/`, which was removed before this receipt commit.

## Fleet stage result

- At commit `928a501a8af836dc305fc21446d2c30a73359e53`, the Fleet test stage
  exited 0: all three required commands exited 0 and the Linux suite was 9 passed
  / 0 skipped.
- The Fleet review stage produced a PASS report with no findings, but its wrapper
  exited 1 with `Review did not return a verdict`. That was a verdict-emission /
  formatting failure, not a source or test finding. The explicit bounded verdict
  is **APPROVE**; this receipt-only follow-up records it without changing the
  helper or the tests.

## Boundaries

This receipt claims only the bounded owner-permission adapter proof. It does not
claim full PR14 `8c2` feature review, UI/device/model acceptance, production
filesystem policy, or any Android/Rust build result. No push, PR, main merge,
deploy, CI workflow, image/service/admin, ownership or shared-cache change was
made; no credentials were read and no provider/network call was used.
