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

public struct SourceKitLSPCapabilities: Sendable, Codable {
  public init() {}
}

public struct InitializeRequest: RequestType {
  public static let method = "initialize"

  public typealias Response = InitializeResponse

  /// The root URI of the project, determined by SourceKit-LSP, ie. this must always point to the directory containing
  /// Package.swift, compile_commands.json etc.
  public var rootUri: String

  public var capabilities: SourceKitLSPCapabilities

  public init(rootUri: String, capabilities: SourceKitLSPCapabilities) {
    self.rootUri = rootUri
    self.capabilities = capabilities
  }
}
public struct BuildSystemCapabilities: Sendable, Codable {
  /// Whether the build system is capable of preparing a target for indexing, ie. if the `prepare` methods has been
  /// implemented.
  public var supportsPreparation: Bool

  public init(supportsPreparation: Bool) {
    self.supportsPreparation = supportsPreparation
  }
}

public struct InitializeResponse: ResponseType {
  /// The path to the raw index store data, if any.
  public var indexStorePath: String?

  /// The path to put the index database, if any.
  public var indexDatabasePath: String?

  /// The file changes to watch for.
  public var watchers: [LanguageServerProtocol.FileSystemWatcher]

  public var capabilities: BuildSystemCapabilities

  public init(
    indexStorePath: String? = nil,
    indexDatabasePath: String? = nil,
    watchers: [FileSystemWatcher],
    capabilities: BuildSystemCapabilities
  ) {
    self.indexStorePath = indexStorePath
    self.indexDatabasePath = indexDatabasePath
    self.watchers = watchers
    self.capabilities = capabilities
  }

}
