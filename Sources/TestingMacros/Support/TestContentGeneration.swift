//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for Swift project authors
//

import SwiftSyntax
import SwiftSyntaxMacros

/// An enumeration representing the different kinds of test content known to the
/// testing library.
///
/// When adding cases to this enumeration, be sure to also update the
/// corresponding enumeration in Test+Discovery.swift and TestContent.md.
enum TestContentKind: Int32 {
  /// A test or suite declaration.
  case testDeclaration = 100

  /// An exit test.
  case exitTest = 101
}

/// The name of ELF notes generated by this code.
private let _swiftTestingELFNoteName = "Swift Testing"

/// The name of ELF notes generated by this code as a sequence of C characters.
///
/// The value of this property corresponds to the implied `n_name` field of an
/// ELF note. It includes one or more trailing null characters.
private let _swiftTestingELFNoteNameCChars: [CChar] = {
  // The size of the note name field. This value must be a multiple of the size
  // of a pointer (on the target) plus four to ensure correct alignment.
  let count = 20
  assert((count - 4) % MemoryLayout<UInt64>.stride == 0, "Swift Testing note name length must be a multiple of pointer size +4")

  // Make sure this string matches the one in Discovery.cpp!
  var name = _swiftTestingELFNoteName.utf8.map { CChar(bitPattern: $0) }
  assert(count > name.count, "Insufficient space for Swift Testing note name")

  // Pad out to the correct length with zero bytes.
  name += repeatElement(0, count: count - name.count)

  return name
}()

/// The name of ELF notes generated by this code as a tuple expression and its
/// corresponding type.
private var _swiftTestingELFNoteNameTuple: (expression: TupleExprSyntax, type: TupleTypeSyntax) {
  let name = _swiftTestingELFNoteNameCChars
  let ccharType = TupleTypeElementSyntax(type: IdentifierTypeSyntax(name: .identifier("CChar")))

  return (
    TupleExprSyntax {
      for c in name {
        LabeledExprSyntax(expression: IntegerLiteralExprSyntax(Int(c)))
      }
    },
    TupleTypeSyntax(
      elements: TupleTypeElementListSyntax {
        for _ in name {
          ccharType
        }
      }
    )
  )
}

/// Make a test content record that can be discovered at runtime by the testing
/// library.
///
/// - Parameters:
///   - name: The name of the record declaration to use in Swift source. The
///     value of this argument should be unique in the context in which the
///     declaration will be emitted.
///   - typeName: The name of the type enclosing the resulting declaration, or
///     `nil` if it will not be emitted into a type's scope.
///   - kind: The kind of note being emitted.
///   - accessorName: The Swift name of an `@convention(c)` function to emit
///     into the resulting record.
///   - flags: Flags to emit as part of this note. The value of this argument is
///     dependent on the kind of test content this instance represents.
///
/// - Returns: A variable declaration that, when emitted into Swift source, will
///   cause the linker to emit data in a location that is discoverable at
///   runtime.
///
/// When the ELF `PT_NOTE` format is in use, the `kind` argument is used as the
/// value of the note's `n_type` field.
func makeTestContentRecordDecl(named name: TokenSyntax, in typeName: TypeSyntax? = nil, ofKind kind: TestContentKind, accessingWith accessorName: TokenSyntax, flags: UInt32 = 0) -> DeclSyntax {
  let elfNoteName = _swiftTestingELFNoteNameTuple
  return """
  #if hasFeature(SymbolLinkageMarkers)
  #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
  @_section("__DATA_CONST,__swift5_tests")
  #elseif os(Linux) || os(FreeBSD) || os(Android)
  @_section(".note.swift.test")
  #elseif os(WASI)
  @_section("swift5_tests")
  #elseif os(Windows)
  @_section(".sw5test$B")
  #endif
  @_used
  @available(*, deprecated, message: "This property is an implementation detail of the testing library. Do not use it directly.")
  private \(staticKeyword(for: typeName)) let \(name): (
    namesz: Int32,
    descsz: Int32,
    type: Int32,
    name: \(elfNoteName.type),
    accessor: @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer?) -> Bool,
    flags: UInt32,
    reserved: UInt32
  ) = (
    \(raw: elfNoteName.type.elements.count),
    Int32(MemoryLayout<UnsafeRawPointer>.stride + MemoryLayout<UInt32>.stride + MemoryLayout<UInt32>.stride),
    \(raw: kind.rawValue),
    \(elfNoteName.expression), /* \(literal: _swiftTestingELFNoteName) */
    \(accessorName),
    \(raw: flags),
    0
  )
  #endif
  """
}
