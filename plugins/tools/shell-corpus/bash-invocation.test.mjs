// SPDX-License-Identifier: MIT
/**
 * Gate entry for the G2-FIX-89 component regression.
 *
 * The assertions live next to the code they drive
 * (`plugins/shell-ext/test/bash-invocation.test.ts`, runnable on its own
 * with `node --test`); `plugins`'s `npm test` glob only reaches
 * `tools/shell-corpus/*.test.mjs`, so this module loads the same suite instead
 * of keeping a second copy. Importing a test file registers its tests in this
 * runner.
 */
import '../../shell-ext/test/bash-invocation.test.ts'
