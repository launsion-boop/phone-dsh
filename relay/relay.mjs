#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// PCLink v1 public relay entry point (P28).

import process from 'node:process'
import { run } from './src/cli.mjs'

process.exitCode = await run(process.argv.slice(2), process.env)
