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

/// Request sent from SourceKit-LSP to the build system to get the targets a source file belongs to. A source file might belong to multiple targets.
///
/// The targets are considered up-to-date and can be cached by SourceKit-LSP until a `DidChangeTargetsNotification` is sent.
public struct TextDocumentTargetsRequest: RequestType, Hashable {
  public typealias Response = TextDocumentTargetsResponse

  public static let method: String = "textDocument/targets"

  public var uri: DocumentURI

  public init(uri: DocumentURI) {
    self.uri = uri
  }
}

public struct TextDocumentTargetsResponse: ResponseType {
  public var targets: [ConfiguredTarget]

  public init(targets: [ConfiguredTarget]) {
    self.targets = targets
  }
}

public struct DidChangeTextDocumentTargetsNotification: NotificationType {
  public static let method: String = "textDocument/didChangeTargets"

  /// The documents for which the targets might have changed.
  ///
  /// If `nil`, the targets of all source files might have changed.
  public var uris: [DocumentURI]?

  public init(uris: [DocumentURI]? = nil) {
    self.uris = uris
  }
}
