// SPDX-License-Identifier: MIT
/**
 * Small TypeScript-AST readers for the contract's source-level seams.
 *
 * Interface member names, function signatures and argv arrays are read from
 * the checkout's own sources. Using the TypeScript parser keeps the tests
 * indifferent to formatting and comments; the observed values stay stable
 * enough to diff the pin against master.
 * @module @phone-dsh/dsh-contract-tests/ast
 */
import ts from 'typescript'

/** One interface property signature, in declaration order. */
export interface InterfaceMember {
  readonly name: string
  readonly optional: boolean
  readonly type: string
}

/** One `git.run([...])` argument vector found in a source file. */
export interface RunArgv {
  readonly subcommand: string
  readonly argv: readonly string[]
}

/**
 * Parse TypeScript source text.
 * @param fileName - name used in diagnostics.
 * @param text - source text.
 * @returns the parsed source file.
 */
export function parseText(fileName: string, text: string): ts.SourceFile {
  return ts.createSourceFile(fileName, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS)
}

/**
 * Depth-first walk over every node.
 * @param node - root node.
 * @param visit - called once per node in source order.
 */
export function walk(node: ts.Node, visit: (node: ts.Node) => void): void {
  visit(node)
  ts.forEachChild(node, child => { walk(child, visit) })
}

/**
 * Read a declaration name as text.
 * @param name - declaration name node.
 * @returns the name text, or undefined for a computed name that is not a simple literal.
 */
function nameText(name: ts.DeclarationName | undefined): string | undefined {
  if (name === undefined) return undefined
  if (ts.isIdentifier(name) || ts.isStringLiteral(name) || ts.isNumericLiteral(name)) return name.text
  return undefined
}

/**
 * Find an interface declaration by name.
 * @param source - parsed source file.
 * @param name - interface name.
 * @returns the declaration, or undefined when absent.
 */
export function findInterface(source: ts.SourceFile, name: string): ts.InterfaceDeclaration | undefined {
  let found: ts.InterfaceDeclaration | undefined
  walk(source, node => {
    if (found === undefined && ts.isInterfaceDeclaration(node) && node.name.text === name) found = node
  })
  return found
}

/**
 * Read an interface's property and method signatures.
 * @param source - parsed source file.
 * @param name - interface name.
 * @returns every named member in declaration order.
 * @throws when the interface is absent, which is itself a seam break.
 */
export function interfaceMembers(source: ts.SourceFile, name: string): InterfaceMember[] {
  const declaration = findInterface(source, name)
  if (declaration === undefined) throw new Error(`interface ${name} not found in the checkout`)
  const members: InterfaceMember[] = []
  for (const member of declaration.members) {
    if (!ts.isPropertySignature(member) && !ts.isMethodSignature(member)) continue
    const memberName = nameText(member.name)
    if (memberName === undefined) continue
    members.push({
      name: memberName,
      optional: member.questionToken !== undefined,
      type: member.type?.getText(source) ?? '',
    })
  }
  return members
}

/**
 * Find a function declaration by name.
 * @param source - parsed source file.
 * @param name - function name.
 * @returns the declaration, or undefined when absent.
 */
export function findFunction(source: ts.SourceFile, name: string): ts.FunctionDeclaration | undefined {
  let found: ts.FunctionDeclaration | undefined
  walk(source, node => {
    if (found === undefined && ts.isFunctionDeclaration(node) && node.name?.text === name) found = node
  })
  return found
}

/**
 * Find a class method declaration by name.
 * @param source - parsed source file.
 * @param name - method name.
 * @returns the declaration, or undefined when absent.
 */
export function findMethod(source: ts.SourceFile, name: string): ts.MethodDeclaration | undefined {
  let found: ts.MethodDeclaration | undefined
  walk(source, node => {
    if (found === undefined && ts.isMethodDeclaration(node) && nameText(node.name) === name) found = node
  })
  return found
}

/**
 * Find the initializer of a variable declaration by name.
 * @param root - subtree to search.
 * @param name - variable name.
 * @returns the initializer expression, or undefined when absent.
 */
export function findVariableInitializer(root: ts.Node, name: string): ts.Expression | undefined {
  let found: ts.Expression | undefined
  walk(root, node => {
    if (
      found === undefined
      && ts.isVariableDeclaration(node)
      && ts.isIdentifier(node.name)
      && node.name.text === name
    ) {
      found = node.initializer
    }
  })
  return found
}

/**
 * Collect every call expression's callee text, in source order.
 * @param root - subtree to search.
 * @param source - parsed source file supplying text.
 * @returns callee expressions such as `appBoot.loadProfile` and `join`.
 */
export function callCalleeTexts(root: ts.Node, source: ts.SourceFile): string[] {
  const calls: string[] = []
  walk(root, node => {
    if (ts.isCallExpression(node)) calls.push(node.expression.getText(source))
  })
  return calls
}

/**
 * Collect the case labels of every switch inside a method.
 * @param source - parsed source file.
 * @param methodName - method whose switch cases are read.
 * @returns unique label texts in source order.
 * @throws when the method is absent.
 */
export function switchCaseLabelsInMethod(source: ts.SourceFile, methodName: string): string[] {
  const method = findMethod(source, methodName)
  if (method === undefined) throw new Error(`method ${methodName} not found in the checkout`)
  const labels: string[] = []
  walk(method, node => {
    if (!ts.isSwitchStatement(node)) return
    for (const clause of node.caseBlock.clauses) {
      if (!ts.isCaseClause(clause)) continue
      const label = clause.expression
      const text = ts.isStringLiteralLike(label) ? label.text : label.getText(source)
      if (!labels.includes(text)) labels.push(text)
    }
  })
  return labels
}

/**
 * Whether a declaration carries the `export` modifier.
 * @param node - declaration node.
 * @returns true for exported declarations.
 */
function hasExport(node: ts.Node): boolean {
  if (!ts.canHaveModifiers(node)) return false
  return ts.getModifiers(node)?.some(modifier => modifier.kind === ts.SyntaxKind.ExportKeyword) === true
}

/**
 * Collect the names a module exports (named re-exports and exported declarations).
 * @param source - parsed source file.
 * @returns sorted unique export names.
 */
export function exportedNames(source: ts.SourceFile): string[] {
  const names = new Set<string>()
  walk(source, node => {
    if (ts.isExportDeclaration(node)) {
      if (node.exportClause !== undefined && ts.isNamedExports(node.exportClause)) {
        for (const element of node.exportClause.elements) names.add(element.name.text)
      }
      return
    }
    if (ts.isVariableStatement(node)) {
      if (!hasExport(node)) return
      for (const declaration of node.declarationList.declarations) {
        if (ts.isIdentifier(declaration.name)) names.add(declaration.name.text)
      }
      return
    }
    if (
      ts.isFunctionDeclaration(node)
      || ts.isClassDeclaration(node)
      || ts.isInterfaceDeclaration(node)
      || ts.isTypeAliasDeclaration(node)
      || ts.isEnumDeclaration(node)
    ) {
      if (hasExport(node) && node.name !== undefined) names.add(node.name.text)
    }
  })
  return [...names].sort()
}

/**
 * Render one array element for observation.
 * @param source - parsed source file supplying text.
 * @param element - array element.
 * @returns a literal string, or a stable placeholder for an expression.
 */
function elementText(source: ts.SourceFile, element: ts.Expression): string {
  if (ts.isStringLiteralLike(element)) return element.text
  if (ts.isSpreadElement(element)) return `...${element.expression.getText(source)}`
  return element.getText(source)
}

/**
 * Render an array literal's elements.
 * @param source - parsed source file supplying text.
 * @param array - array literal.
 * @returns element texts in order.
 */
export function arrayElements(source: ts.SourceFile, array: ts.ArrayLiteralExpression): string[] {
  return array.elements.map(element => elementText(source, element))
}

/**
 * Collect every `git.run([...])` call's argument vector.
 * @param source - parsed source file.
 * @returns vectors in source order, each starting with its git subcommand.
 */
export function gitRunArgvs(source: ts.SourceFile): RunArgv[] {
  const runs: RunArgv[] = []
  walk(source, node => {
    if (!ts.isCallExpression(node)) return
    const callee = node.expression
    if (!ts.isPropertyAccessExpression(callee) || callee.name.text !== 'run') return
    if (!ts.isIdentifier(callee.expression) || callee.expression.text !== 'git') return
    const first = node.arguments[0]
    if (first === undefined || !ts.isArrayLiteralExpression(first)) return
    const argv = arrayElements(source, first)
    const subcommand = argv[0]
    if (subcommand === undefined || subcommand === '') return
    runs.push({ subcommand, argv })
  })
  return runs
}

/**
 * Collect the ripgrep flag literals a function builds.
 *
 * Initial array elements and later pushes are both included, in source order;
 * template heads such as `--glob=${name}` report the literal `--glob=` part.
 * @param source - parsed source file.
 * @param functionName - function to inspect.
 * @returns unique flag literals in source order.
 * @throws when the function is absent.
 */
export function flagLiteralsInFunction(source: ts.SourceFile, functionName: string): string[] {
  const declaration = findFunction(source, functionName)
  if (declaration === undefined) throw new Error(`function ${functionName} not found in the checkout`)
  const flags: string[] = []
  const push = (flag: string): void => {
    if (!flags.includes(flag)) flags.push(flag)
  }
  walk(declaration, node => {
    if (ts.isStringLiteralLike(node)) {
      if (node.text === '--' || node.text.startsWith('--')) push(node.text)
      return
    }
    if (ts.isTemplateExpression(node)) {
      const head = node.head.text
      if (head === '--' || head.startsWith('--')) push(head)
    }
  })
  return flags
}

/**
 * Render the array initializer of the first object property with a given name.
 * @param source - parsed source file.
 * @param propertyName - property name to find.
 * @returns the array's element texts, or undefined when absent.
 */
export function arrayPropertyElements(source: ts.SourceFile, propertyName: string): string[] | undefined {
  let found: string[] | undefined
  walk(source, node => {
    if (found !== undefined || !ts.isPropertyAssignment(node)) return
    if (nameText(node.name) !== propertyName) return
    if (!ts.isArrayLiteralExpression(node.initializer)) return
    found = arrayElements(source, node.initializer)
  })
  return found
}

/**
 * Resolve a string or template literal whose substitutions are known names.
 * @param node - expression to resolve.
 * @param names - expression-text to value map (for example `IMAGE_HOME_DIRECTORY`).
 * @returns the resolved text, or undefined when the expression is unsupported.
 */
export function resolveTemplate(node: ts.Expression, names: ReadonlyMap<string, string>): string | undefined {
  if (ts.isStringLiteralLike(node)) return node.text
  if (!ts.isTemplateExpression(node)) return undefined
  let result = node.head.text
  for (const span of node.templateSpans) {
    const value = names.get(span.expression.getText())
    if (value === undefined) return undefined
    result += value + span.literal.text
  }
  return result
}
