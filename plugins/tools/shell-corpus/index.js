// SPDX-License-Identifier: MIT
/**
 * Compatibility entry point for `node --test tools/shell-corpus/`.
 *
 * Older Node releases expand a directory positional into its `*.test.mjs`
 * files. Current Node resolves the directory to this module instead, so the
 * module loads the same test files. On the older behaviour this file is never
 * executed.
 */

import './extract.test.mjs'
import './classify.test.mjs'
import './runners.test.mjs'
import './corpus.test.mjs'
import './interpreter-invocation.test.mjs'
import './bash-invocation.test.mjs'
import './golden.test.mjs'
import './cmp-golden.test.mjs'
import './contract.test.mjs'
import './probe-budget.test.mjs'
