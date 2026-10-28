// SPDX-License-Identifier: MIT
/**
 * Entry for the documented package gate `node --test git/tests`.
 *
 * Newer Node releases treat an explicit positional path as a file, not as a
 * directory to search, so the gate needs a directory index. Each import
 * registers that module's tests on the same runner; the files remain runnable
 * one at a time with `node --test git/tests/<name>.test.ts`.
 */
import './command.test.ts'
import './compress.test.ts'
import './glob-pathspec.test.ts'
import './golden-fidelity.test.ts'
import './golden.test.ts'
import './history-options.test.ts'
import './ignore.test.ts'
import './no-node-zlib.test.ts'
import './pack-window.test.ts'
import './pack.test.ts'
import './pathspec.test.ts'
import './porcelain-corpus.test.ts'
import './porcelain.test.ts'
import './profile.test.ts'
import './restore-amend.test.ts'
import './rev-list.test.ts'
import './remote.test.ts'
import './unsupported.test.ts'
import './wiring.test.ts'

import './reflog.test.ts'
import './tag.test.ts'
