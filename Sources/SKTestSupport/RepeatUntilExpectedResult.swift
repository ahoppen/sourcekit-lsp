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

#if compiler(>=6)
package import XCTest
#else
import XCTest
#endif

/// Runs the body repeatedly once per second until it returns `true`, giving up after `timeout`.
///
/// This is useful to test some request that requires global state to be updated but will eventually converge on the
/// correct result.
package func repeatUntilExpectedResult(
  timeout: TimeInterval = defaultTimeout,
  _ body: () async throws -> Bool,
  file: StaticString = #filePath,
  line: UInt = #line
) async throws {
  for _ in 0..<Int(timeout) {
    if try await body() {
      return
    }
    try await Task.sleep(for: .seconds(1))
  }
  XCTFail("Failed to get expected result", file: file, line: line)
}
