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
public struct WorkspaceTargetsRequest: RequestType {
  public typealias Response = WorkspaceTargetsResponse

  public static let method: String = "workspace/targets"
}

public struct WorkspaceTargetsResponse: ResponseType {
  public struct TargetInfo: Sendable, Codable {
    public var target: ConfiguredTarget

    /// The direct (non-transitive) dependencies of `target`.
    public var dependencies: [ConfiguredTarget]

    /// `true` if this file belongs to the root project that the user is working on. It is false, if the file belongs
    /// to a dependency of the project.
    public var isPartOfRootProject: Bool

    /// Whether the file might contain test cases. This property is an over-approximation. It might be true for files
    /// from non-test targets or files that don't actually contain any tests. Keeping this list of files with
    /// `mayContainTets` minimal as possible helps reduce the amount of work that the syntactic test indexer needs to
    /// perform.
    public var mayContainTests: Bool

    public var sourceFiles: [DocumentURI]

    public init(
      target: ConfiguredTarget,
      dependencies: [ConfiguredTarget],
      isPartOfRootProject: Bool,
      mayContainTests: Bool,
      sourceFiles: [DocumentURI]
    ) {
      self.target = target
      self.dependencies = dependencies
      self.isPartOfRootProject = isPartOfRootProject
      self.mayContainTests = mayContainTests
      self.sourceFiles = sourceFiles
    }

  }

  public var targets: [TargetInfo]

  public init(targets: [WorkspaceTargetsResponse.TargetInfo]) {
    self.targets = targets
  }
}

/// Request sent from the build system to SourceKit-LSP to indicate that the targets in the project or their dependencies have changed.
public struct DidChangeTargetsNotification: NotificationType {
  public static let method: String = "workspace/didChangeTargets"
}
