//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for Swift project authors
//

import SwiftSyntax
import SwiftSyntaxMacros

/// Emit a diagnostic if an expression resolves to a trivial boolean literal
/// (e.g. `#expect(true)`.)
///
/// - Parameters:
///   - expr: The condition expression to parse.
///   - macro: The macro expression being expanded.
///   - context: The macro context in which the expression is being parsed.
///
/// If `expr` is a trivial boolean expression, a diagnostic is emitted on the
/// assumption that this is not what the developer intended.
private func _diagnoseTrivialBooleanValue(from expr: ExprSyntax, for macro: some FreestandingMacroExpansionSyntax, in context: some MacroExpansionContext) {
  if let literal = expr.as(BooleanLiteralExprSyntax.self) {
    switch literal.literal.tokenKind {
    case .keyword(.true):
      context.diagnose(.condition(expr, isAlways: true, in: macro))
    case .keyword(.false):
      context.diagnose(.condition(expr, isAlways: false, in: macro))
    default:
      break
    }
  } else if let literal = _negatedExpression(expr)?.as(BooleanLiteralExprSyntax.self) {
    // This expression is of the form !true or !false.
    switch literal.literal.tokenKind {
    case .keyword(.true):
      context.diagnose(.condition(expr, isAlways: !true, in: macro))
    case .keyword(.false):
      context.diagnose(.condition(expr, isAlways: !false, in: macro))
    default:
      break
    }
  }
}

/// Extract the expression negated by another expression, assuming that the
/// input expression is the negation operator (`!`).
///
/// - Parameters:
///   - expr: The negation expression.
///
/// - Returns: The expression negated by `expr`, or `nil` if `expr` is not a
///   negation expression.
///
/// This function handles expressions such as `!foo` or `!(bar)`.
private func _negatedExpression(_ expr: ExprSyntax) -> ExprSyntax? {
  let expr = removeParentheses(from: expr) ?? expr
  if let op = expr.as(PrefixOperatorExprSyntax.self),
     op.operator.tokenKind == .prefixOperator("!") {
    if let negatedExpr = removeParentheses(from: op.expression) {
      return negatedExpr
    } else {
      return op.expression
    }
  }

  return nil
}

/// Remove the parentheses surrounding an expression, if present.
///
/// - Parameters:
///   - expr: The parenthesized expression.
///
/// - Returns: The expression parenthesized by `expr`, or `nil` if it wasn't
///   parenthesized.
///
/// This function handles expressions such as `(foo)` or `((foo, bar))`. It does
/// not remove interior parentheses (e.g. `(foo, (bar))`.)
func removeParentheses(from expr: ExprSyntax) -> ExprSyntax? {
  if let tuple = expr.as(TupleExprSyntax.self),
     tuple.elements.count == 1,
     let elementExpr = tuple.elements.first,
     elementExpr.label == nil {
    return removeParentheses(from: elementExpr.expression) ?? elementExpr.expression
  }

  return nil
}

// MARK: - Inserting expression context callouts

/// A type that inserts calls to an `__ExpectationContext` instance into an
/// expression's syntax tree.
private final class _ContextInserter<C, M>: SyntaxRewriter where C: MacroExpansionContext, M: FreestandingMacroExpansionSyntax {
  /// The macro context in which the expression is being parsed.
  var context: C

  /// The macro expression.
  var macro: M

  /// The node to treat as the root node when expanding expressions.
  var effectiveRootNode: Syntax

  /// The name of the instance of `__ExpectationContext` to call.
  var expressionContextNameExpr: DeclReferenceExprSyntax

  /// A list of any syntax nodes that have been rewritten.
  ///
  /// The nodes in this array are the _original_ nodes, not the rewritten nodes.
  var rewrittenNodes = Set<Syntax>()

  /// The set of expanded tokens (primarily from instances of
  /// `DeclReferenceExprSyntax`) that may represent module names instead of type
  /// or variable names.
  var possibleModuleNames = Set<TokenKind>()

  /// Any postflight code the caller should insert into the closure containing
  /// the rewritten syntax tree.
  var teardownItems = [CodeBlockItemSyntax]()

  init(in context: C, for macro: M, rootedAt effectiveRootNode: Syntax, expressionContextName: TokenSyntax) {
    self.context = context
    self.macro = macro
    self.effectiveRootNode = effectiveRootNode
    self.expressionContextNameExpr = DeclReferenceExprSyntax(baseName: expressionContextName.trimmed)
    super.init()
  }

  /// Rewrite a given syntax node by inserting a call to the expression context
  /// (or rather, its `callAsFunction(_:_:)` member).
  ///
  /// - Parameters:
  ///   - node: The node to rewrite.
  ///   - originalNode: The original node in the original syntax tree, if `node`
  ///     has already been partially rewritten or substituted. If `node` has not
  ///     been rewritten, this argument should equal it.
  ///   - functionName: If not `nil`, the name of the function to call (as a
  ///     member function of the expression context.)
  ///   - additionalArguments: Any additional arguments to pass to the function.
  ///
  /// - Returns: A rewritten copy of `node` that calls into the expression
  ///   context when it is evaluated at runtime.
  private func _rewrite<E>(_ node: E, originalWas originalNode: some SyntaxProtocol, calling functionName: TokenSyntax? = nil, passing additionalArguments: [Argument] = []) -> ExprSyntax where E: ExprSyntaxProtocol {
    guard rewrittenNodes.insert(Syntax(originalNode)).inserted else {
      // If this node has already been rewritten, we don't need to rewrite it
      // again. (Currently, this can only happen when expanding binary operators
      // which need a bit of extra help.)
      return ExprSyntax(node)
    }

    let calledExpr: ExprSyntax = if let functionName {
      ExprSyntax(MemberAccessExprSyntax(base: expressionContextNameExpr, name: functionName))
    } else {
      ExprSyntax(expressionContextNameExpr)
    }

    var result = FunctionCallExprSyntax(calledExpression: calledExpr) {
      LabeledExprSyntax(expression: node.trimmed)
      LabeledExprSyntax(expression: originalNode.expressionID(rootedAt: effectiveRootNode))
      for argument in additionalArguments {
        LabeledExprSyntax(argument)
      }
    }

    result.leftParen = .leftParenToken()
    result.rightParen = .rightParenToken()
    result.leadingTrivia = originalNode.leadingTrivia
    result.trailingTrivia = originalNode.trailingTrivia

    // If the resulting expression has an optional type due to containing an
    // optional chaining expression (e.g. `foo?`) *and* its immediate parent
    // node passes through the syntactical effects of optional chaining, return
    // it as optional-chained so that it parses correctly post-expansion.
    switch node.parent?.kind {
    case .memberAccessExpr, .subscriptCallExpr:
      let optionalChainFinder = _OptionalChainFinder(viewMode: .sourceAccurate)
      optionalChainFinder.walk(node)
      if optionalChainFinder.optionalChainFound {
        return ExprSyntax(OptionalChainingExprSyntax(expression: result))
      }

    default:
      break
    }

    return ExprSyntax(result)
  }

  /// Rewrite a given syntax node by inserting a call to the expression context
  /// (or rather, its `callAsFunction(_:_:)` member).
  ///
  /// - Parameters:
  ///   - node: The node to rewrite.
  ///   - functionName: If not `nil`, the name of the function to call (as a
  ///     member function of the expression context.)
  ///   - additionalArguments: Any additional arguments to pass to the function.
  ///
  /// - Returns: A rewritten copy of `node` that calls into the expression
  ///   context when it is evaluated at runtime.
  ///
  /// This function is equivalent to `_rewrite(node, originalWas: node)`.
  private func _rewrite<E>(_ node: E, calling functionName: TokenSyntax? = nil, passing additionalArguments: [Argument] = []) -> ExprSyntax where E: ExprSyntaxProtocol {
    _rewrite(node, originalWas: node, calling: functionName, passing: additionalArguments)
  }

  /// Whether or not the parent node of the given node is capable of containing
  /// a rewritten `DeclReferenceExprSyntax` instance.
  ///
  /// - Parameters:
  ///   - node: The node that might be rewritten. It does not need to be an
  ///     instance of `DeclReferenceExprSyntax`.
  ///
  /// - Returns: Whether or not the _parent_ of `node` will still be
  ///   syntactically valid if `node` is rewritten with `_rewrite(_:)`.
  ///
  /// Instances of `DeclReferenceExprSyntax` are often present in positions
  /// where it would be syntactically invalid to extract them out as function
  /// arguments. This function is used to constrain the cases where we do so to
  /// those we know (or generally know) are "safe".
  private func _isParentOfDeclReferenceExprValidForRewriting(_ node: some SyntaxProtocol) -> Bool {
    guard let parentNode = node.parent else {
      return false
    }

    switch parentNode.kind {
    case .labeledExpr, .functionParameter,
        .prefixOperatorExpr, .postfixOperatorExpr, .infixOperatorExpr,
        .asExpr, .isExpr, .optionalChainingExpr, .forceUnwrapExpr,
        .arrayElement, .dictionaryElement:
      return true
    default:
      return false
    }
  }

  override func visit(_ node: DeclReferenceExprSyntax) -> ExprSyntax {
    // DeclReferenceExprSyntax is used for operator tokens in identifier
    // position. These generally appear when an operator function is passed to
    // a higher-order function (e.g. `sort(by: <)`) and also for the unbounded
    // range expression (`...`). Both are uninteresting to the testing library
    // and can be dropped.
    if node.baseName.isOperator {
      return ExprSyntax(node)
    }

    // A decl reference expression with argument names is generally a valid
    // expression that could be rewritten, but it's going to be a function name
    // and we aren't generally interested in those.
    if node.argumentNames != nil {
      return ExprSyntax(node)
    }

    // The base name *might* be a module name, so track it for further expansion
    // later. For the sake of optimization, we make some (possibly technically
    // invalid) assumptions:
    //
    // 1. The first character of a module name is always uppercase;
    // 2. A module name is always at least three characters long;
    // 3. A module name is always a valid Swift identifier; and
    // 4. A module name, when present in source, is always the innermost
    //    (leftmost) in a member access expression chain.
    //
    // See disableExpansion(of:into:ifCanImportAnyOf:) below to see how we avoid
    // expanding module names.
    let baseName = node.baseName.textWithoutBackticks
    if let firstCharacter = baseName.first, firstCharacter.isUppercase, // 1
       baseName.count >= 3, // 2
       baseName.isValidSwiftIdentifier(for: .memberAccess), // 3
       let memberAccessExpr = node.parent?.as(MemberAccessExprSyntax.self), // 4
       let baseExpr = memberAccessExpr.base,
       ExprSyntax(node) == (removeParentheses(from: baseExpr) ?? baseExpr) {
      possibleModuleNames.insert(node.baseName.tokenKind)
    }

    if _isParentOfDeclReferenceExprValidForRewriting(node) {
      return _rewrite(node)
    }

    // SPECIAL CASE: If this node is the base expression of a member access
    // expression, and that member access expression is the called expression of
    // a function, it is generally safe to extract out (but may need `.self`
    // added to the end.)
    if let memberAccessExpr = node.parent?.as(MemberAccessExprSyntax.self),
       ExprSyntax(node) == memberAccessExpr.base,
       let functionCallExpr = memberAccessExpr.parent?.as(FunctionCallExprSyntax.self),
       ExprSyntax(memberAccessExpr) == functionCallExpr.calledExpression {
      return _rewrite(
        MemberAccessExprSyntax(
          base: node.trimmed,
          declName: DeclReferenceExprSyntax(baseName: .keyword(.self))
        ),
        originalWas: node
      )
    }

    return ExprSyntax(node)
  }

  override func visit(_ node: TupleExprSyntax) -> ExprSyntax {
    // We are conservative when descending into tuples because they could be
    // tuple _types_ rather than _values_ (e.g. `(Int, Double)`) but those
    // cannot be distinguished with syntax alone.
    if _isParentOfDeclReferenceExprValidForRewriting(node) {
      return _rewrite(
        TupleExprSyntax {
          for element in node.elements {
            visit(element).trimmed
          }
        },
        originalWas: node
      )
    }

    return ExprSyntax(node)
  }

  override func visit(_ node: MemberAccessExprSyntax) -> ExprSyntax {
    if case .keyword = node.declName.baseName.tokenKind {
      // Likely something like Foo.self or X.Type, which we can't reasonably
      // break down further.
      return ExprSyntax(node)
    }

    // As with decl reference expressions, only certain kinds of member access
    // expressions can be directly extracted out.
    if _isParentOfDeclReferenceExprValidForRewriting(node) {
      return _rewrite(
        node.with(\.base, node.base.map(visit)),
        originalWas: node
      )
    }

    return ExprSyntax(node.with(\.base, node.base.map(visit)))
  }

  override func visit(_ node: FunctionCallExprSyntax) -> ExprSyntax {
    _rewrite(
      node
        .with(\.calledExpression, visit(node.calledExpression))
        .with(\.arguments, visit(node.arguments)),
      originalWas: node
    )
  }

  override func visit(_ node: SubscriptCallExprSyntax) -> ExprSyntax {
    _rewrite(
      node
        .with(\.calledExpression, visit(node.calledExpression))
        .with(\.arguments, visit(node.arguments)),
      originalWas: node
    )
  }

  override func visit(_ node: ClosureExprSyntax) -> ExprSyntax {
    // We do not (currently) attempt to descent into closures.
    ExprSyntax(node)
  }

  override func visit(_ node: MacroExpansionExprSyntax) -> ExprSyntax {
    // We do not attempt to descent into freestanding macros.
    ExprSyntax(node)
  }

  override func visit(_ node: FunctionDeclSyntax) -> DeclSyntax {
    // We do not (currently) attempt to descent into functions.
    DeclSyntax(node)
  }

  // MARK: - Operators

  override func visit(_ node: PrefixOperatorExprSyntax) -> ExprSyntax {
    // Special-case negative number literals as a single expression.
    if node.expression.is(IntegerLiteralExprSyntax.self) || node.expression.is(FloatLiteralExprSyntax.self) {
      if node.operator.tokenKind == .prefixOperator("-") {
        return ExprSyntax(node)
      }
    }

    return _rewrite(
      node
        .with(\.expression, visit(node.expression)),
      originalWas: node
    )
  }

  override func visit(_ node: InfixOperatorExprSyntax) -> ExprSyntax {
    if let op = node.operator.as(BinaryOperatorExprSyntax.self)?.operator.textWithoutBackticks,
       op == "==" || op == "!=" || op == "===" || op == "!==" {

      return _rewrite(
        ClosureExprSyntax {
          InfixOperatorExprSyntax(
            leftOperand: DeclReferenceExprSyntax(baseName: .dollarIdentifier("$0"))
              .with(\.trailingTrivia, .space),
            operator: BinaryOperatorExprSyntax(text: op),
            rightOperand: DeclReferenceExprSyntax(baseName: .dollarIdentifier("$1"))
              .with(\.leadingTrivia, .space)
          )
        },
        originalWas: node,
        calling: .identifier("__cmp"),
        passing: [
          Argument(expression: visit(node.leftOperand)),
          Argument(expression: node.leftOperand.expressionID(rootedAt: effectiveRootNode)),
          Argument(expression: visit(node.rightOperand)),
          Argument(expression: node.rightOperand.expressionID(rootedAt: effectiveRootNode))
        ]
      )
    }

    return _rewrite(
      node
        .with(\.leftOperand, visit(node.leftOperand))
        .with(\.rightOperand, visit(node.rightOperand)),
      originalWas: node
    )
  }

  override func visit(_ node: InOutExprSyntax) -> ExprSyntax {
    // Swift's Law of Exclusivity means that only one subexpression in the
    // expectation ought to be interacting with `value` when it is passed
    // `inout`, so it should be sufficient to capture it in a `defer` statement
    // that runs after the expression is evaluated.

    let teardownItem = CodeBlockItemSyntax(
      item: .expr(
        _rewrite(node.expression, calling: .identifier("__inoutAfter"))
      )
    )
    teardownItems.append(teardownItem)

    // The argument should not be expanded in-place as we can't return an
    // argument passed `inout` and expect it to remain semantically correct.
    return ExprSyntax(node)
  }

  // MARK: - Casts

  /// Rewrite an `is` or `as?` cast.
  ///
  /// - Parameters:
  ///   - valueExpr: The expression to cast.
  ///   - isAsKeyword: The casting keyword (either `.is` or `.as`).
  ///   - type: The type to cast `valueExpr` to.
  ///   - originalNode: The original `IsExprSyntax` or `AsExprSyntax` node in
  ///     the original syntax tree.
  ///
  /// - Returns: A function call expression equivalent to the described cast.
  private func _rewriteAsCast(_ valueExpr: ExprSyntax, _ isAsKeyword: Keyword, _ type: TypeSyntax, originalWas originalNode: some SyntaxProtocol) -> ExprSyntax {
    rewrittenNodes.insert(Syntax(type))

    return _rewrite(
      visit(valueExpr).trimmed,
      originalWas: originalNode,
      calling: .identifier("__\(isAsKeyword)"),
      passing: [
        Argument(
          expression: MemberAccessExprSyntax(
            base: TupleExprSyntax {
              LabeledExprSyntax(expression: TypeExprSyntax(type: type.trimmed))
            },
            declName: DeclReferenceExprSyntax(baseName: .keyword(.self))
          )
        ),
        Argument(expression: type.expressionID(rootedAt: effectiveRootNode))
      ]
    )
  }

  override func visit(_ node: AsExprSyntax) -> ExprSyntax {
    switch node.questionOrExclamationMark?.tokenKind {
    case .postfixQuestionMark:
      return _rewriteAsCast(node.expression, .as, node.type, originalWas: node)

    case .exclamationMark where !node.type.isNamed("Bool", inModuleNamed: "Swift") && !node.type.isOptional:
      // Warn that as! will be evaluated before #expect() or #require(), which is
      // probably not what the developer intended. We suppress the warning for
      // casts to Bool and casts to optional types. Presumably such casts are not
      // being performed for their optional-unwrapping behavior, but because the
      // developer knows the type of the expression better than we do.
      context.diagnose(.asExclamationMarkIsEvaluatedEarly(node, in: macro))
      return _rewrite(node)

    case .exclamationMark:
      // Only diagnose for `x as! T`. `x as T` is perfectly fine if it otherwise
      // compiles. For example, `#require(x as Int?)` should compile.
      return _rewrite(node)

    default:
      // This is an "escape hatch" cast. Do not attempt to process the cast.
      return ExprSyntax(node)
    }
  }

  override func visit(_ node: IsExprSyntax) -> ExprSyntax {
    _rewriteAsCast(node.expression, .is, node.type, originalWas: node)
  }

  // MARK: - Literals

  override func visit(_ node: BooleanLiteralExprSyntax) -> ExprSyntax {
    // Contrary to the comment immediately below this function, we *do* rewrite
    // boolean literals so that expressions like `#expect(true)` are expanded.
    _rewrite(node)
  }

  // We don't currently rewrite numeric/string/array/dictionary literals. We
  // could, but it's unclear what the benefit would be and it could seriously
  // impact type checker time.

#if SWT_DELVE_INTO_LITERALS
  override func visit(_ node: IntegerLiteralExprSyntax) -> ExprSyntax {
    _rewrite(node)
  }

  override func visit(_ node: FloatLiteralExprSyntax) -> ExprSyntax {
    _rewrite(node)
  }

  override func visit(_ node: StringLiteralExprSyntax) -> ExprSyntax {
    _rewrite(node)
  }

  override func visit(_ node: ArrayExprSyntax) -> ExprSyntax {
    _rewrite(
      node.with(
        \.elements, ArrayElementListSyntax {
          for element in node.elements {
            ArrayElementSyntax(expression: visit(element.expression).trimmed)
          }
        }
      ),
      originalWas: node
    )
  }

  override func visit(_ node: DictionaryExprSyntax) -> ExprSyntax {
    guard case let .elements(elements) = node.content else {
      return ExprSyntax(node)
    }
    return _rewrite(
      node.with(
        \.content, .elements(
          DictionaryElementListSyntax {
            for element in elements {
              DictionaryElementSyntax(key: visit(element.key).trimmed, value: visit(element.value).trimmed)
            }
          }
        )
      ),
      originalWas: node
    )
  }
#else
  override func visit(_ node: ArrayExprSyntax) -> ExprSyntax {
    return ExprSyntax(node)
  }

  override func visit(_ node: DictionaryExprSyntax) -> ExprSyntax {
    return ExprSyntax(node)
  }
#endif
}

struct RewrittenNodeInfo<S> where S: SyntaxProtocol {
  var originalNode: S
  var rewrittenNode: Syntax

  var rewrittenChildNodes: Set<Syntax>
  var prefixCodeBlockItems: CodeBlockItemListSyntax

  var possibleModuleNames: Set<TokenKind>
}

/// Insert calls to an expression context into a syntax tree.
///
/// - Parameters:
///   - expressionContextName: The name of the instance of
///     `__ExpectationContext` to call.
///   - node: The root of a syntax tree to rewrite. This node may not itself be
///     the root of the overall syntax tree—it's just the root of the subtree
///     that we're rewriting.
///   - macro: The macro expression.
///   - effectiveRootNode: The node to treat as the root of the syntax tree for
///     the purposes of generating expression ID values.
///   - context: The macro context in which the expression is being parsed.
///
/// - Returns: A tuple containing the rewritten copy of `node`, a list of all
///   the nodes within `node` (possibly including `node` itself) that were
///   rewritten, and a code block containing code that should be inserted into
///   the lexical scope of `node` _before_ its rewritten equivalent.
func rewrite<S>(
  _ node: S,
  usingExpressionContextNamed expressionContextName: TokenSyntax,
  for macro: some FreestandingMacroExpansionSyntax,
  rootedAt effectiveRootNode: some SyntaxProtocol,
  in context: some MacroExpansionContext
) -> RewrittenNodeInfo<S> where S: SyntaxProtocol {
  if let node = node.as(ExprSyntax.self) {
    _diagnoseTrivialBooleanValue(from: node, for: macro, in: context)
  }

  let contextInserter = _ContextInserter(in: context, for: macro, rootedAt: Syntax(effectiveRootNode), expressionContextName: expressionContextName)
  let result = contextInserter.rewrite(node)

  return RewrittenNodeInfo(
    originalNode: node,
    rewrittenNode: result,
    rewrittenChildNodes: contextInserter.rewrittenNodes,
    prefixCodeBlockItems: CodeBlockItemListSyntax {
      if !contextInserter.teardownItems.isEmpty {
        CodeBlockItemSyntax(
          item: .stmt(
            StmtSyntax(
              DeferStmtSyntax {
                contextInserter.teardownItems
              }
            )
          )
        )
      }
    }.formatted().with(\.trailingTrivia, .newline).cast(CodeBlockItemListSyntax.self),
    possibleModuleNames: contextInserter.possibleModuleNames
  )
}

// MARK: - Finding optional chains

/// A class that walks a syntax tree looking for optional chaining expressions
/// such as `a?.b.c`.
private final class _OptionalChainFinder: SyntaxVisitor {
  /// Whether or not any optional chaining was found.
  var optionalChainFound = false

  override func visit(_ node: OptionalChainingExprSyntax) -> SyntaxVisitorContinueKind {
    optionalChainFound = true
    return .skipChildren
  }
}

// MARK: - Finding effect keywords

/// A syntax visitor class that looks for effectful keywords in a given
/// expression.
private final class _EffectFinder: SyntaxAnyVisitor {
  /// The effect keywords discovered so far.
  var effectKeywords: Set<Keyword> = []

  override func visitAny(_ node: Syntax) -> SyntaxVisitorContinueKind {
    switch node.kind {
    case .tryExpr:
      effectKeywords.insert(.try)
    case .awaitExpr:
      effectKeywords.insert(.await)
    case .consumeExpr:
      effectKeywords.insert(.consume)
    case .closureExpr, .functionDecl:
      // Do not delve into closures or function declarations.
      return .skipChildren
    case .variableDecl:
      // Delve into variable declarations.
      return .visitChildren
    default:
      // Do not delve into declarations other than variables.
      if node.isProtocol((any DeclSyntaxProtocol).self) {
        return .skipChildren
      }
    }

    // Recurse into everything else.
    return .visitChildren
  }
}

/// Find effectful keywords in a syntax node.
///
/// - Parameters:
///   - node: The node to inspect.
///
/// - Returns: A set of effectful keywords such as `await` that are present in
///   `node`.
///
/// This function does not descend into function declarations or closure
/// expressions because they represent distinct lexical contexts and their
/// effects are uninteresting in the context of `node` unless they are called.
func findEffectKeywords(in node: some SyntaxProtocol) -> Set<Keyword> {
  let effectFinder = _EffectFinder(viewMode: .sourceAccurate)
  effectFinder.walk(node)
  return effectFinder.effectKeywords
}

// MARK: - Avoiding expansion of module names

/// Rewrite a previously-expanded expression as a `#if`/`#else`/`#endif`
/// declaration in order to avoid trying to expand module names as if they were
/// type or variable names.
///
/// - Parameters:
///   - node: The original node that was expanded into `codeBlockItems`.
///   - codeBlockItems: The expanded form of `node`.
///   - possibleModuleNames: A set of possible module names detected during the
///     expansion of `node`.
///
/// - Returns: A new code block item list that checks if any module names in
///   `possibleModuleNames` can be imported and falls back to a trivial
///   expansion if one can be.
func disableExpansion(
  of node: some ExprSyntaxProtocol,
  into codeBlockItems: CodeBlockItemListSyntax,
  ifCanImportAnyOf possibleModuleNames: Set<TokenKind>
) -> CodeBlockItemListSyntax {
  // Generate canImport() expressions for each of the possible module names we
  // have been given.
  let canImportNameExpr = DeclReferenceExprSyntax(baseName: .identifier("canImport"))
  let canImportExprs = possibleModuleNames
    .map { TokenSyntax($0, presence: .present) }
    .map { moduleName in
      var result = FunctionCallExprSyntax(calledExpression: canImportNameExpr) {
        LabeledExprSyntax(expression: DeclReferenceExprSyntax(baseName: moduleName))
      }
      result.leftParen = .leftParenToken()
      result.rightParen = .rightParenToken()
      return ExprSyntax(result)
    }

  // Generate an OR (||) operator to place between the canImport expressions.
  let orOperatorExpr = ExprSyntax(
    BinaryOperatorExprSyntax(operator: .binaryOperator("||"))
      .with(\.leadingTrivia, .space)
      .with(\.trailingTrivia, .space)
  )

  // Combine the canImport and || subexpressions into a single expression.
  let conditionExpr = SequenceExprSyntax(
    elements: ExprListSyntax {
      canImportExprs
        .map(CollectionOfOne.init)
        .joined(separator: CollectionOfOne(orOperatorExpr))
    }
  ).with(\.trailingTrivia, .newline)

  return CodeBlockItemListSyntax {
    CodeBlockItemSyntax(
      item: CodeBlockItemSyntax.Item(
        DeclSyntax(
          IfConfigDeclSyntax(
            clauses: IfConfigClauseListSyntax {
              IfConfigClauseSyntax(
                poundKeyword: .poundIfToken().with(\.trailingTrivia, .space),
                condition: conditionExpr,
                elements: .statements(
                  CodeBlockItemListSyntax {
                    CodeBlockItemSyntax(item: CodeBlockItemSyntax.Item(node))
                  }
                )
              )
              IfConfigClauseSyntax(
                poundKeyword: .poundElseToken()
                  .with(\.leadingTrivia, .newline)
                  .with(\.trailingTrivia, .newline),
                elements: .statements(codeBlockItems)
              )
            }
          ).with(\.trailingTrivia, .newline)
        )
      )
    )
  }
}

// MARK: - Replacing dollar identifiers

/// Rewrite a dollar identifier as a normal (non-dollar) identifier.
///
/// - Parameters:
///   - token: The dollar identifier token to rewrite.
///
/// - Returns: A copy of `token` as an identifier token.
private func _rewriteDollarIdentifier(_ token: TokenSyntax) -> TokenSyntax {
  .identifier("__renamedCapture__\(token.trimmedDescription)")
}

/// A syntax rewriter that replaces _numeric_ dollar identifiers (e.g. `$0`)
/// with normal (non-dollar) identifiers.
private final class _DollarIdentifierReplacer: SyntaxRewriter {
  /// The dollar identifier tokens that have been rewritten.
  var dollarIdentifierTokenKinds = Set<TokenKind>()

  /// The node to treat as the root node when expanding expressions.
  var effectiveRootNode: Syntax

  init(rootedAt effectiveRootNode: Syntax) {
    self.effectiveRootNode = effectiveRootNode
  }

  override func visitAny(_ node: Syntax) -> Syntax? {
    // Do not recurse into closure expressions (except the root node) because
    // they will have their own argument/capture lists that won't conflict with
    // the enclosing scope's.
    if node.is(ClosureExprSyntax.self) && node != effectiveRootNode {
      return Syntax(node)
    }

    return nil
  }

  override func visit(_ node: TokenSyntax) -> TokenSyntax {
    if case let .dollarIdentifier(id) = node.tokenKind, id.dropFirst().allSatisfy(\.isWholeNumber) {
      // This dollar identifier is numeric, so it's a closure argument.
      dollarIdentifierTokenKinds.insert(node.tokenKind)

      var result = _rewriteDollarIdentifier(node)
      result.leadingTrivia = node.leadingTrivia
      result.trailingTrivia = node.trailingTrivia
      return result
    }

    return node
  }
}

/// Rewrite any implicit closure arguments (dollar identifiers such as `$0`) in
/// the given node as normal (non-dollar) identifiers.
///
/// - Parameters:
///   - node: The syntax node to rewrite.
///
/// - Returns: A rewritten copy of `node` as well as a closure capture list that
///   can be used to transform the original dollar identifiers to their
///   rewritten counterparts in a nested closure invocation.
func rewriteClosureArguments(in node: some SyntaxProtocol) -> (rewrittenNode: Syntax, captureList: ClosureCaptureClauseSyntax)? {
  let replacer = _DollarIdentifierReplacer(rootedAt: Syntax(node))
  let result = replacer.rewrite(node)
  if replacer.dollarIdentifierTokenKinds.isEmpty {
    return nil
  }
  let captureList = ClosureCaptureClauseSyntax {
    let tokens = replacer.dollarIdentifierTokenKinds.map { tokenKind in
      TokenSyntax(tokenKind, presence: .present)
    }
    for token in tokens {
      ClosureCaptureSyntax(
        name: _rewriteDollarIdentifier(token),
        expression: DeclReferenceExprSyntax(baseName: token)
      )
    }
  }
  return (result, captureList)
}
