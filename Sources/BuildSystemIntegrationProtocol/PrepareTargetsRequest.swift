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

import LanguageServerProtocol

/// Request sent from SourceKit-LSP to the build system to prepare targets for indexing and editor functionality.
public struct PrepareTargetsRequest: RequestType {
  public typealias Response = VoidResponse

  public static let method: String = "target/prepare"

  public var targets: [ConfiguredTarget]

  public init(targets: [ConfiguredTarget]) {
    self.targets = targets
  }
}
