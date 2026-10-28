// SPDX-License-Identifier: MIT
/**
 * `node --import` entry that installs the browser Worker's `node:zlib` stub
 * before the gzip regression probe loads any module.
 */

import { register } from 'node:module'

register('./zlib-unavailable-hooks.mjs', import.meta.url)
