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

/// Request sent from SourceKit-LSP to the build system to get all source files in a target.
public struct TargetDocumentsRequest: RequestType {
  public typealias Response = WorkspaceTargetsResponse

  public static let method: String = "target/textDocuments"

  public var target: ConfiguredTarget

  public init(target: ConfiguredTarget) {
    self.target = target
  }
}

public struct TargetDocumentsResponse: ResponseType {
  public var documents: [DocumentURI]

  public init(documents: [DocumentURI]) {
    self.documents = documents
  }
}

/// Request sent from the build system to SourceKit-LSP to indicate that the source files in a target might have changed.
public struct DidChangeTargetDocumentsNotification: NotificationType {
  public static let method: String = "target/didChangeTextDocuments"

  /// The targets for which the source files might have changed.
  ///
  /// If `nil`, the source files of all targets might have changed.
  public var targets: [ConfiguredTarget]?

  public init(targets: [ConfiguredTarget]?) {
    self.targets = targets
  }
}
