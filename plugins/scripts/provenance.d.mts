// SPDX-License-Identifier: MIT
export interface ImageProvenance {
  schema: 1
  phone_source_sha256: string
  dsh_commit: string
  image_sha256: string
  python: boolean
}

export interface BundleProvenance extends ImageProvenance {
  bundle_files: Array<{ path: string; sha256: string }>
}

export function writeImageProvenance(
  imageOutput: string,
  options: { dshCommit: string; sourceRoot?: string },
): ImageProvenance

export function createBundleProvenance(options: {
  imageOutput: string
  output: string
  sourceRoot?: string
}): BundleProvenance
