/** Minimal JSON-Schema subset used by the frozen PCLink v1 schemas. */

import { jsonEquals } from './json.mjs'
import { validateName } from './encoding.mjs'

/** One schema-validation failure. */
export class SchemaError extends Error {
  constructor(message) {
    super(message)
    this.name = 'SchemaError'
  }
}

function fail(where, message) {
  throw new SchemaError(`${where}: ${message}`)
}

function typeOf(value) {
  if (value === null) return 'null'
  if (Array.isArray(value)) return 'array'
  if (typeof value === 'number') return Number.isInteger(value) ? 'integer' : 'number'
  return typeof value
}

function matchesType(value, type) {
  const actual = typeOf(value)
  if (type === 'number') return actual === 'integer' || actual === 'number'
  return actual === type
}

function validate(value, schema, where, root) {
  if (schema === true || schema === undefined) return
  if (schema === false) fail(where, 'schema is false')
  if (typeof schema !== 'object' || schema === null) fail(where, 'schema is not an object')
  if (schema.$ref !== undefined) fail(where, 'unsupported $ref')
  if (schema.const !== undefined && !jsonEquals(value, schema.const)) fail(where, `expected const ${JSON.stringify(schema.const)}`)
  if (schema.enum !== undefined && !schema.enum.some(candidate => jsonEquals(value, candidate))) {
    fail(where, `expected one of ${JSON.stringify(schema.enum)}`)
  }
  if (schema.type !== undefined) {
    const types = Array.isArray(schema.type) ? schema.type : [schema.type]
    if (!types.some(type => matchesType(value, type))) fail(where, `expected type ${types.join('|')}, got ${typeOf(value)}`)
  }
  if (typeof value === 'string') {
    const length = Array.from(value).length
    if (schema.minLength !== undefined && length < schema.minLength) fail(where, `string shorter than ${String(schema.minLength)}`)
    if (schema.maxLength !== undefined && length > schema.maxLength) fail(where, `string longer than ${String(schema.maxLength)}`)
    if (schema.pattern !== undefined) {
      let expression
      try {
        expression = new RegExp(schema.pattern, 'u')
      } catch (error) {
        fail(where, `invalid schema pattern: ${String(error)}`)
      }
      if (!expression.test(value)) fail(where, `string does not match ${schema.pattern}`)
    }
  }
  if (typeof value === 'number') {
    if (schema.minimum !== undefined && value < schema.minimum) fail(where, `number below ${String(schema.minimum)}`)
    if (schema.maximum !== undefined && value > schema.maximum) fail(where, `number above ${String(schema.maximum)}`)
  }
  if (Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) fail(where, `fewer than ${String(schema.minItems)} items`)
    if (schema.maxItems !== undefined && value.length > schema.maxItems) fail(where, `more than ${String(schema.maxItems)} items`)
    if (schema.uniqueItems === true) {
      for (let left = 0; left < value.length; left += 1) {
        for (let right = left + 1; right < value.length; right += 1) {
          if (jsonEquals(value[left], value[right])) fail(where, 'items are not unique')
        }
      }
    }
    if (schema.items !== undefined) {
      value.forEach((item, index) => validate(item, schema.items, `${where}[${String(index)}]`, root))
    }
  }
  if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
    if (Array.isArray(schema.required)) {
      for (const name of schema.required) {
        if (!Object.prototype.hasOwnProperty.call(value, name)) fail(where, `missing required member ${name}`)
      }
    }
    if (schema.dependentRequired !== undefined) {
      for (const [name, dependencies] of Object.entries(schema.dependentRequired)) {
        if (Object.prototype.hasOwnProperty.call(value, name)) {
          for (const dependency of dependencies) {
            if (!Object.prototype.hasOwnProperty.call(value, dependency)) {
              fail(where, `member ${name} requires ${dependency}`)
            }
          }
        }
      }
    }
    const properties = schema.properties ?? {}
    for (const name of Object.keys(value)) {
      if (Object.prototype.hasOwnProperty.call(properties, name)) {
        validate(value[name], properties[name], `${where}.${name}`, root)
      } else if (schema.additionalProperties === false) {
        fail(where, `unknown member ${name}`)
      }
    }
  }
  if (schema.oneOf !== undefined) {
    let matched = 0
    let lastError
    for (const [index, branch] of schema.oneOf.entries()) {
      try {
        validate(value, branch, where, root)
        matched += 1
      } catch (error) {
        if (!(error instanceof SchemaError)) throw error
        lastError = error
      }
      if (matched > 1) break
    }
    if (matched !== 1) {
      fail(where, `oneOf matched ${String(matched)} branches${lastError === undefined ? '' : ` (${lastError.message})`}`)
    }
  }
}

/**
 * Validate one value against the frozen JSON-Schema subset.
 * @param {unknown} value Parsed JSON value.
 * @param {object} schema Schema object.
 * @param {string} [where] Location label for errors.
 * @returns {true} true when valid.
 */
export function validateJsonSchema(value, schema, where = '$') {
  validate(value, schema, where, schema)
  return true
}

/**
 * Enforce the normative §2.1 name rule on every `name`/`peerName` string in a value.
 * @param {unknown} value Parsed JSON value.
 * @param {string} [where] Location label.
 * @returns {void}
 */
export function assertDisplayNames(value, where = '$') {
  if (Array.isArray(value)) {
    value.forEach((child, index) => assertDisplayNames(child, `${where}[${String(index)}]`))
    return
  }
  if (value === null || typeof value !== 'object') return
  for (const [key, child] of Object.entries(value)) {
    if (key === 'name' || key === 'peerName') {
      try {
        validateName(child, key)
      } catch (error) {
        throw new SchemaError(`${where}.${key}: ${error.message}`)
      }
    }
    assertDisplayNames(child, `${where}.${key}`)
  }
}
