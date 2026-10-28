// SPDX-License-Identifier: MIT
import { parseArgs } from 'node:util'
import { createBundleProvenance, verifyBundleProvenance } from './provenance.mjs'

try {
  const { values } = parseArgs({
    options: {
      create: { type: 'boolean', default: false },
      'image-out': { type: 'string' },
      bundle: { type: 'string' },
      image: { type: 'string' },
      provenance: { type: 'string' },
      out: { type: 'string' },
      python: { type: 'string', default: 'any' },
      jq: { type: 'string', default: 'any' },
    },
    allowPositionals: false,
  })
  if (values.create) {
    if (!values['image-out'] || !values.out) {
      throw new Error('usage: verify-bundle.mjs --create --image-out DIR --out BUNDLE_DIR')
    }
    const record = createBundleProvenance({
      imageOutput: values['image-out'],
      output: values.out,
    })
    process.stdout.write(`bundle provenance: created (${record.phone_source_sha256.slice(0, 12)})\n`)
  } else {
    if (!values.bundle || !values.provenance) {
      throw new Error('usage: verify-bundle.mjs --bundle DIR --provenance FILE [--image FILE] [--python yes|no|any] [--jq yes|no|any]')
    }
    const record = verifyBundleProvenance({
      bundleRoot: values.bundle,
      imageOverride: values.image,
      provenance: values.provenance,
      expectPython: values.python,
      expectJq: values.jq,
    })
    process.stdout.write(`bundle provenance: OK (${record.dsh_commit.slice(0, 12)}, python=${String(record.python)}, jq=${String(record.jq)})\n`)
  }
} catch (error) {
  process.stderr.write(`verify-bundle: ${error instanceof Error ? error.message : String(error)}\n`)
  process.exitCode = 1
}
