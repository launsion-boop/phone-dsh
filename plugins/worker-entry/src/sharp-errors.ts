// SPDX-License-Identifier: MIT
/**
 * Errors raised by the Worker-side `sharp` shim.
 *
 * Three classes, deliberately distinct:
 *
 *  - {@link SharpInputError} means the bytes are not a decodable image. DSH's
 *    attachment admission folds it into its own `INVALID_IMAGE`; that is the
 *    correct outcome for genuinely malformed or unsupported bytes.
 *  - {@link SharpUnsupportedOperationError} means this shim (or the WebKit
 *    primitive behind it) does not implement an operation the caller reached.
 *    It carries Node's `ERR_FEATURE_UNAVAILABLE_ON_PLATFORM`-style code and
 *    names the operation, so a caller receives a distinct, loud backend-gap
 *    error instead of a second "malformed image" report.
 *  - {@link SharpEncoderOutputError} means the platform encoder returned bytes
 *    that fail the JPEG structure checks. It is an internal backend failure, not
 *    a judgement about the caller's input image.
 * @module @phone-dsh/dsh-worker-entry/sharp-errors
 */

/** Machine-readable code carried by {@link SharpInputError}. */
export const SHARP_INVALID_IMAGE_CODE = 'SHARP_INVALID_IMAGE'

/** Machine-readable code carried by {@link SharpUnsupportedOperationError}. */
export const SHARP_UNSUPPORTED_OPERATION_CODE = 'SHARP_UNSUPPORTED_OPERATION'

/** Machine-readable code carried by {@link SharpEncoderOutputError}. */
export const SHARP_ENCODER_OUTPUT_CODE = 'SHARP_ENCODER_OUTPUT'

/** The bytes handed to `sharp()` are not a complete, supported image. */
export class SharpInputError extends Error {
  /** Node errno-shaped code for classification. */
  readonly code: string = SHARP_INVALID_IMAGE_CODE

  constructor(detail: string, options?: { cause?: unknown }) {
    super(`xl sharp shim: input is not a decodable image: ${detail}`, options)
    this.name = 'SharpInputError'
  }
}

/** A reachable sharp operation this shim does not implement. */
export class SharpUnsupportedOperationError extends Error {
  /** Node errno-shaped code for classification. */
  readonly code: string = SHARP_UNSUPPORTED_OPERATION_CODE
  /** The sharp operation name that was reached, e.g. `sharp.webp`. */
  readonly operation: string

  constructor(operation: string, detail: string) {
    const message = `xl sharp shim: ${operation} is not implemented in the phone Worker: ${detail}`
    super(message)
    this.name = 'SharpUnsupportedOperationError'
    this.operation = operation
    // Loud on the Worker console the moment an unsupported path is reached;
    // callers routinely wrap this error far from its cause.
    console.error(message)
  }
}

/** The platform encoder returned bytes this shim cannot safely pass on. */
export class SharpEncoderOutputError extends Error {
  /** Node errno-shaped code for classification. */
  readonly code: string = SHARP_ENCODER_OUTPUT_CODE
  /** The sharp operation whose encoder produced the bytes. */
  readonly operation: string

  constructor(operation: string, detail: string) {
    super(`xl sharp shim: ${operation} encoder returned an unusable image: ${detail}`)
    this.name = 'SharpEncoderOutputError'
    this.operation = operation
  }
}

/**
 * Whether a value is one of this shim's own errors.
 * @param value - value thrown by a shim call.
 * @returns true for a {@link SharpInputError}, {@link SharpUnsupportedOperationError}, or {@link SharpEncoderOutputError}.
 */
export function isSharpShimError(
  value: unknown,
): value is SharpInputError | SharpUnsupportedOperationError | SharpEncoderOutputError {
  return value instanceof SharpInputError
    || value instanceof SharpUnsupportedOperationError
    || value instanceof SharpEncoderOutputError
}
