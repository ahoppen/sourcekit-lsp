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

/// Request sent from SourceKit-LSP to the build system to get all targets within the project and their dependencies.
public struct WorkspaceTargetsRequest: RequestType, Hashable {
  public typealias Response = WorkspaceTargetsResponse

  public static let method: String = "workspace/targets"

  public init() {}
}

public struct WorkspaceTargetsResponse: ResponseType, Hashable {
  public struct TargetInfo: Sendable, Codable, Hashable {
    /// The targets that depend on this target
    public var dependents: [ConfiguredTarget]

    public init(dependents: [ConfiguredTarget]) {
      self.dependents = dependents
    }
  }

  public var targets: [ConfiguredTarget: TargetInfo]

  public init(targets: [ConfiguredTarget: TargetInfo]) {
    self.targets = targets
  }
}

/// Request sent from the build system to SourceKit-LSP to indicate that the targets in the project or their dependencies have changed.
public struct DidChangeWorkspaceTargetsNotification: NotificationType {
  public static let method: String = "workspace/didChangeTargets"

  public init() {}
}
