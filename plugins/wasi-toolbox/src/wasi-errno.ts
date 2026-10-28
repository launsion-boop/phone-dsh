// SPDX-License-Identifier: MIT
/**
 * WASI preview1 constants and the errno translation the host uses. Numbers are
 * the ones `wasi_snapshot_preview1` defines; they are ABI, not choices.
 * @module @phone-dsh/dsh-wasi-toolbox/wasi-errno
 */
import { errorCodeOf } from './errors.ts'

/** WASI preview1 errno values. */
export const WASI_ERRNO = {
  SUCCESS: 0,
  ACCES: 2,
  AGAIN: 6,
  BADF: 8,
  EXIST: 20,
  FAULT: 21,
  FBIG: 22,
  INVAL: 28,
  IO: 29,
  ISDIR: 31,
  LOOP: 32,
  MFILE: 33,
  NAMETOOLONG: 37,
  NOENT: 44,
  NOMEM: 48,
  NOSPC: 51,
  NOSYS: 52,
  NOTDIR: 54,
  NOTEMPTY: 55,
  NOTSUP: 58,
  PERM: 63,
  PIPE: 64,
  ROFS: 69,
  SPIPE: 70,
  TIMEDOUT: 73,
  NOTCAPABLE: 76,
} as const

/** WASI file types. */
export const WASI_FILETYPE = {
  UNKNOWN: 0,
  BLOCK_DEVICE: 1,
  CHARACTER_DEVICE: 2,
  DIRECTORY: 3,
  REGULAR_FILE: 4,
  SOCKET_DGRAM: 5,
  SOCKET_STREAM: 6,
  SYMBOLIC_LINK: 7,
} as const

/** WASI `oflags` bits accepted by `path_open`. */
export const WASI_OFLAGS = {
  CREAT: 1,
  DIRECTORY: 2,
  EXCL: 4,
  TRUNC: 8,
} as const

/** WASI `fdflags` bits. */
export const WASI_FDFLAGS = {
  APPEND: 1,
  DSYNC: 2,
  NONBLOCK: 4,
  RSYNC: 8,
  SYNC: 16,
} as const

/** WASI rights bits the host answers with (all granted inside a preopen). */
export const WASI_RIGHTS = {
  FD_DATASYNC: 1n << 0n,
  FD_READ: 1n << 1n,
  FD_SEEK: 1n << 2n,
  FD_FDSTAT_SET_FLAGS: 1n << 3n,
  FD_SYNC: 1n << 4n,
  FD_TELL: 1n << 5n,
  FD_WRITE: 1n << 6n,
  FD_ADVISE: 1n << 7n,
  FD_ALLOCATE: 1n << 8n,
  FD_FILESTAT_GET: 1n << 21n,
  FD_FILESTAT_SET_SIZE: 1n << 22n,
  FD_FILESTAT_SET_TIMES: 1n << 23n,
  PATH_CREATE_DIRECTORY: 1n << 9n,
  PATH_CREATE_FILE: 1n << 10n,
  PATH_LINK_SOURCE: 1n << 11n,
  PATH_LINK_TARGET: 1n << 12n,
  PATH_OPEN: 1n << 13n,
  PATH_READLINK: 1n << 14n,
  PATH_RENAME_SOURCE: 1n << 15n,
  PATH_RENAME_TARGET: 1n << 16n,
  PATH_FILESTAT_GET: 1n << 17n,
  PATH_FILESTAT_SET_SIZE: 1n << 18n,
  PATH_FILESTAT_SET_TIMES: 1n << 19n,
  PATH_SYMLINK: 1n << 20n,
  PATH_REMOVE_DIRECTORY: 1n << 24n,
  PATH_UNLINK_FILE: 1n << 25n,
  POLL_FD_READWRITE: 1n << 27n,
  SOCK_SHUTDOWN: 1n << 28n,
  SOCK_ACCEPT: 1n << 29n,
} as const

/** Every right the host grants; a preopen is the capability boundary. */
export const ALL_RIGHTS: bigint = Object.values(WASI_RIGHTS).reduce((mask, bit) => mask | bit, 0n)

/** Translate an errno-style code to its WASI value. */
export function errnoFor(code: string | undefined): number {
  switch (code) {
    case undefined:
    case 'SUCCESS':
      return WASI_ERRNO.SUCCESS
    case 'EACCES':
      return WASI_ERRNO.ACCES
    case 'EAGAIN':
      return WASI_ERRNO.AGAIN
    case 'EBADF':
      return WASI_ERRNO.BADF
    case 'EEXIST':
      return WASI_ERRNO.EXIST
    case 'EFAULT':
      return WASI_ERRNO.FAULT
    case 'EFBIG':
      return WASI_ERRNO.FBIG
    case 'EINVAL':
      return WASI_ERRNO.INVAL
    case 'EIO':
      return WASI_ERRNO.IO
    case 'EISDIR':
      return WASI_ERRNO.ISDIR
    case 'ELOOP':
      return WASI_ERRNO.LOOP
    case 'EMFILE':
      return WASI_ERRNO.MFILE
    case 'ENAMETOOLONG':
      return WASI_ERRNO.NAMETOOLONG
    case 'ENOENT':
      return WASI_ERRNO.NOENT
    case 'ENOMEM':
      return WASI_ERRNO.NOMEM
    case 'ENOSPC':
    // WASI preview1 has no quota errno; a host quota refusal is a space
    // condition, so the guest sees the same bounded-resource failure as ENOSPC
    // instead of an opaque EIO (a VFS_REFUSED may carry EDQUOT).
    case 'EDQUOT':
      return WASI_ERRNO.NOSPC
    case 'ENOSYS':
      return WASI_ERRNO.NOSYS
    case 'ENOTDIR':
      return WASI_ERRNO.NOTDIR
    case 'ENOTEMPTY':
      return WASI_ERRNO.NOTEMPTY
    case 'ENOTSUP':
    case 'EOPNOTSUPP':
      return WASI_ERRNO.NOTSUP
    case 'ENOTCAPABLE':
      return WASI_ERRNO.NOTCAPABLE
    case 'EPERM':
      return WASI_ERRNO.PERM
    case 'EPIPE':
      return WASI_ERRNO.PIPE
    case 'EROFS':
      return WASI_ERRNO.ROFS
    case 'ESPIPE':
      return WASI_ERRNO.SPIPE
    case 'ETIMEDOUT':
      return WASI_ERRNO.TIMEDOUT
    default:
      return WASI_ERRNO.IO
  }
}

/** Translate any thrown value to a WASI errno, without swallowing traps. */
export function errnoFromError(error: unknown): number {
  return errnoFor(errorCodeOf(error))
}
