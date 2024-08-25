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

    /// The toolchain that should be used to build this target. The URI should point to the directory that contains the
    /// `usr` directory. On macOS, this is typically a bundle ending in `.xctoolchain`. If the toolchain is installed to
    /// `/` on Linux, the toolchain URI would point to `/`.
    ///
    /// If no toolchain is given, SourceKit-LSP will pick a toolchain to use for this target.
    public var toolchain: DocumentURI?

    public init(dependents: [ConfiguredTarget], toolchain: DocumentURI?) {
      self.dependents = dependents
      self.toolchain = toolchain
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
