// SPDX-License-Identifier: MIT
/**
 * Gate entry for G2-FIX-78.
 *
 * The tests live next to the other cross-package tests in
 * `wasi-python-subprocess.test.ts`; this file is the exact command the work
 * package names:
 *
 * `node --test plugins/tests/wasi-python-subprocess.test.mjs`
 *
 * It only loads the implementation so the two entry points cannot drift.
 * @module @phone-dsh/dsh-tests/wasi-python-subprocess-gate
 */
import './wasi-python-subprocess.test.ts'
