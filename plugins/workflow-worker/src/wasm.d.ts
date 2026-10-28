// SPDX-License-Identifier: MIT
/** esbuild's `binary` loader exposes `.wasm` imports as bytes. */
declare module '*.wasm' {
  const bytes: Uint8Array
  export default bytes
}

declare module '@jitl/quickjs-wasmfile-release-sync/wasm' {
  const bytes: Uint8Array
  export default bytes
}
