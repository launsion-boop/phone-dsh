// SPDX-License-Identifier: MIT
// Directory entry for `node --test scripts/`: Node versions that load a
// directory argument as a module get every test file registered here. Other
// versions discover `*.test.mjs` directly and ignore this file.
import './dsh-checkout.test.mjs'
import './dispose-compat.test.mjs'
import './pack-overlay.test.mjs'
import './profile.test.mjs'
import './pack-image.test.mjs'
import './provenance.test.mjs'
