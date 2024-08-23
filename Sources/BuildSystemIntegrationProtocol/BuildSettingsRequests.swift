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

/// Request sent from SourceKit-LSP to the build system to get the build settings for a source file.
///
/// The build settings are considered up-to-date and can be cached by SourceKit-LSP until a `DidChangeBuildSettingsNotification` is sent.
public struct BuildSettingsRequest: RequestType {
  public typealias Response = BuildSettingsResponse

  public static let method: String = "textDocument/buildSettings"

  public var uri: DocumentURI
  public var target: ConfiguredTarget
  public var language: Language?
  public init(uri: DocumentURI, target: ConfiguredTarget, language: Language? = nil) {
    self.uri = uri
    self.target = target
    self.language = language
  }
}

public struct BuildSettingsResponse: ResponseType {
  public var compilerArguments: [String]
  public var workingDirectory: String?

  public init(compilerArguments: [String], workingDirectory: String? = nil) {
    self.compilerArguments = compilerArguments
    self.workingDirectory = workingDirectory
  }
}

/// Notification sent from the build system to SourceKit-LSP to mark the build settings of the given files as out-of-date. SourceKit-LSP needs to send a new `BuildSettingsRequest` to get the new build settings.
public struct DidChangeBuildSettingsNotification: NotificationType {
  public static let method: String = "textDocument/didChangeBuildSettings"

  /// The documents for which the build settings might have changed.
  ///
  /// If `nil`, the build settings of all source files might have changed.
  public var uris: [DocumentURI]?

  public init(uris: [DocumentURI]? = nil) {
    self.uris = uris
  }
}
