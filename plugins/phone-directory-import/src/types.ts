// SPDX-License-Identifier: MIT
/**
 * Wire vocabulary shared by the native iPhone Files importer, the phone Worker
 * Remote and the Files-panel client action.
 *
 * The native side keeps byte-identical defaults in
 * `WebEngineDirectoryImportLimits.default`; a host that changes either set of
 * numbers must change both. All paths in the manifest are relative to the
 * session workspace root and use `/` separators.
 *
 * @module @phone-dsh/dsh-phone-directory-import/types
 */

/** Deployment caps; the native `WebEngineDirectoryImportLimits.default` mirrors them. */
export const DIRECTORY_IMPORT_LIMITS = {
  maxFiles: 500,
  maxDirectories: 2000,
  maxTotalBytes: 128 * 1024 * 1024,
  maxFileBytes: 64 * 1024 * 1024,
  chunkBytes: 1024 * 1024,
  maxPathBytes: 1024,
  maxEntryNameLength: 128,
} as const

/** One file in a native manifest. */
export interface DirectoryImportFile {
  /** `/`-separated path relative to the session workspace root. */
  readonly path: string
  /** Exact byte size the native side staged. */
  readonly size: number
}

/** `phone/importBegin` request. */
export interface DirectoryImportBeginRequest {
  readonly v: 1
  readonly sessionId: string
  /** Existing directory inside the session workspace that receives `imports/<name>`. */
  readonly targetDirectory: string
  /** Selected source directory name, used as the final import directory name. */
  readonly entryName: string
  /** Relative directories to create, including empty ones. */
  readonly directories: readonly string[]
  readonly files: readonly DirectoryImportFile[]
  readonly totalBytes: number
}

/** `phone/importBegin` response. */
export interface DirectoryImportBeginResponse {
  readonly importId: string
}

/** `phone/importWrite` request. */
export interface DirectoryImportWriteRequest {
  readonly v: 1
  readonly sessionId: string
  readonly importId: string
  /** Manifest file path. */
  readonly path: string
  /** Byte offset this chunk starts at; must equal the bytes already received. */
  readonly offset: number
  /** One chunk, base64 encoded; at most `DIRECTORY_IMPORT_LIMITS.chunkBytes`. */
  readonly dataBase64: string
}

/** `phone/importWrite` response. */
export interface DirectoryImportWriteResponse {
  readonly received: number
}

/** `phone/importCommit` request. */
export interface DirectoryImportCommitRequest {
  readonly v: 1
  readonly sessionId: string
  readonly importId: string
}

/** `phone/importCommit` response. */
export interface DirectoryImportCommitResponse {
  /** Path relative to the session workspace root, for example `imports/notes`. */
  readonly workspacePath: string
  /** Absolute path in the Worker VFS. */
  readonly absolutePath: string
  readonly fileCount: number
  readonly totalBytes: number
}

/** `phone/importAbort` request. */
export interface DirectoryImportAbortRequest {
  readonly v: 1
  readonly sessionId: string
  readonly importId: string
}

/** `phone/importAbort` response. */
export interface DirectoryImportAbortResponse {
  readonly aborted: boolean
}

/** Failure codes a service maps to the existing Gateway/session vocabulary. */
export type WorkspaceImportErrorCode = 'bad-request' | 'not-found' | 'internal'

/** Failure codes the native side reports back to the page. */
export type NativeDirectoryImportErrorCode =
  | 'cancelled'
  | 'security-scope-denied'
  | 'not-a-folder'
  | 'not-regular-file'
  | 'symlink'
  | 'limit-exceeded'
  | 'unsafe-path'
  | 'copy-failed'
  | 'busy'
  | 'sink-failed'
  | 'presenter-unavailable'
  | 'invalid-message'
  | 'internal'
