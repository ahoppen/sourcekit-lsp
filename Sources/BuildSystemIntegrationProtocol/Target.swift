//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

public struct ConfiguredTarget: Codable, Sendable {
  /// An opaque string that represents the target, including the destination that the target should be built for.
  public var identifier: String

  public init(identifier: String) {
    self.identifier = identifier
  }
}
