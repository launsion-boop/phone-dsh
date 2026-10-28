// SPDX-License-Identifier: MIT
/** CSS Modules are bundled by the DSH client build; only the class map is visible here. */
declare module '*.module.css' {
  const classes: Readonly<Record<string, string>>
  export default classes
}
