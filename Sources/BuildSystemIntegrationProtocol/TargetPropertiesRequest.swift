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

/// Request sent from SourceKit-LSP to the build system to get properties of the target as a key-value list.
/// This allows the user to pick the target they want to use to receive semantic functionality for a file.
public struct TargetPropertiesRequest: RequestType {
  public typealias Response = TargetPropertiesResponse

  public static let method: String = "target/properties"

  public var target: ConfiguredTarget

  public init(target: ConfiguredTarget) {
    self.target = target
  }
}

public struct TargetPropertiesResponse: ResponseType {
  public var properties: [String: String]

  public init(properties: [String: String]) {
    self.properties = properties
  }
}
