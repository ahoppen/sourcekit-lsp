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

/// Notification sent from the build system to SourceKit-LSP to inform SourceKit-LSP that the dependencies of the
/// given files have changed and that ASTs may need to be refreshed.
public struct DidUpdateTextDocumentDependenciesNotification: NotificationType {
  public static let method: String = "textDocument/didUpdateDependencies"

  /// An opaque identifier that identifies the task producing this message. A task may, for example, be the preparation of a single target.
  public var documents: [DocumentURI]

  public init(documents: [DocumentURI]) {
    self.documents = documents
  }
}
