//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import XCTest

/// Same as `XCTAssertThrows` but executes the trailing closure.
public func assertNoThrow<T>(
  _ expression: () throws -> T,
  _ message: @autoclosure () -> String = "",
  file: StaticString = #filePath,
  line: UInt = #line
) {
  XCTAssertNoThrow(try expression(), message(), file: file, line: line)
}

/// Same as `XCTAssertEqual` but doesn't take autoclosures and thus `expression1`
/// and `expression2` can contain `await`.
public func assertEqual<T: Equatable>(
  _ expression1: T,
  _ expression2: T,
  _ message: @autoclosure () -> String = "",
  file: StaticString = #filePath,
  line: UInt = #line
) {
  XCTAssertEqual(expression1, expression2, message(), file: file, line: line)
}
