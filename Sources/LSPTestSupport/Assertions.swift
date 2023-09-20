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

/// Same as `XCTAssertThrows` but executes the trailing closure.
public func assertThrowsError<T>(
  _ expression: @autoclosure () async throws -> T,
  _ message: @autoclosure () -> String = "",
  file: StaticString = #filePath,
  line: UInt = #line,
  _ errorHandler: (_ error: Error) -> Void = { _ in }
) async {
  let didThrow: Bool
  do {
    _ = try await expression()
    didThrow = false
  } catch {
    errorHandler(error)
    didThrow = true
  }
  if !didThrow {
    XCTFail("Expression was expected to throw but did not throw", file: file, line: line)
  }
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

/// Same as `XCTAssertNil` but doesn't take autoclosures and thus `expression`
/// can contain `await`.
public func assertNil<T: Equatable>(
  _ expression: T?,
  _ message: @autoclosure () -> String = "",
  file: StaticString = #filePath,
  line: UInt = #line
) {
  XCTAssertNil(expression, message(), file: file, line: line)
}


/// Same as `XCTAssertNotNil` but doesn't take autoclosures and thus `expression`
/// can contain `await`.
public func assertNotNil<T: Equatable>(
  _ expression: T?,
  _ message: @autoclosure () -> String = "",
  file: StaticString = #filePath,
  line: UInt = #line
) {
  XCTAssertNotNil(expression, message(), file: file, line: line)
}


extension XCTestCase {
  private struct ExpectationNotFulfilledError: Error, CustomStringConvertible {
    var description: String {
      return "Expectation not fulfilled within timeout"
    }
  }

  /// Wait for the given expectations to be fulfilled. If the expectations aren't 
  /// fulfilled within `timeout`, throw an error, aborting the test execution.
  public func fulfillmentOfOrThrow(
    _ expectations: [XCTestExpectation],
    timeout: TimeInterval = defaultTimeout,
    enforceOrder enforceOrderOfFulfillment: Bool = false
  ) async throws {
    let started = await XCTWaiter.fulfillment(of: expectations, timeout: timeout, enforceOrder: enforceOrderOfFulfillment)
    if started != .completed {
      throw ExpectationNotFulfilledError()
    }
  }
}
