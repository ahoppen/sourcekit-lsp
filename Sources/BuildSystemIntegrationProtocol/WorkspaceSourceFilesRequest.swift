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

/// Request sent from SourceKit-LSP to list all source files in the project.
public struct WorkspaceSourceFilesRequest: RequestType {
  public typealias Response = WorkspaceSourceFilesResponse

  public static let method: String = "workspace/sourceFiles"
}

public struct SourceFileInfo: Sendable, Codable {
  /// The URI of the source file.
  public var uri: DocumentURI

  /// `true` if this file belongs to the root project that the user is working on. It is false, if the file belongs
  /// to a dependency of the project.
  public var isPartOfRootProject: Bool?

  /// Whether the file might contain test cases. This property is an over-approximation. It might be true for files
  /// from non-test targets or files that don't actually contain any tests. Keeping this list of files with
  /// `mayContainTets` minimal as possible helps reduce the amount of work that the syntactic test indexer needs to
  /// perform.
  public var mayContainTests: Bool?

  /// The language with which this document should be processed for background functionality.
  public var language: Language?

  public init(
    uri: DocumentURI,
    isPartOfRootProject: Bool? = nil,
    mayContainTests: Bool? = nil,
    language: Language? = nil
  ) {
    self.uri = uri
    self.isPartOfRootProject = isPartOfRootProject
    self.mayContainTests = mayContainTests
    self.language = language
  }
}

public struct WorkspaceSourceFilesResponse: ResponseType {
  public var sourceFiles: [SourceFileInfo]

  public init(sourceFiles: [SourceFileInfo]) {
    self.sourceFiles = sourceFiles
  }
}

/// Request sent from the build system to SourceKit-LSP to indicate that the source files in the project might have
/// changed.
public struct DidChangeSourceFilesNotification: NotificationType {
  public static let method: String = "workspace/didChangeSourceFiles"
}
