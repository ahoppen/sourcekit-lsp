//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import BuildServerProtocol
import BuildSystemIntegrationProtocol
import Foundation
import LanguageServerProtocol
import SKLogging
import SKOptions
import SKSupport
import SwiftExtensions
import ToolchainRegistry

import struct TSCBasic.AbsolutePath
import struct TSCBasic.RelativePath

/// An error build systems can throw from `prepare` if they don't support preparation of targets.
package struct PrepareNotSupportedError: Error, CustomStringConvertible {
  package init() {}

  package var description: String { "Preparation not supported" }
}

/// Provider of FileBuildSettings and other build-related information.
///
/// The primary role of the build system is to answer queries for
/// FileBuildSettings and to notify its delegate when they change. The
/// BuildSystem is also the source of related information, such as where the
/// index datastore is located.
///
/// For example, a SwiftPMWorkspace provides compiler arguments for the files
/// contained in a SwiftPM package root directory.
package protocol BuiltInBuildSystem: AnyObject, Sendable {
  /// When opening an LSP workspace at `workspaceFolder`, determine the directory in which a project of this build system
  /// starts. For example, a user might open the `Sources` folder of a SwiftPM project, then the project root is the
  /// directory containing `Package.swift`.
  ///
  /// Returns `nil` if the build system can't handle the given workspace folder
  static func projectRoot(for workspaceFolder: AbsolutePath, options: SourceKitLSPOptions) -> AbsolutePath?

  /// The root of the project that this build system manages. For example, for SwiftPM packages, this is the folder
  /// containing Package.swift. For compilation databases it is the root folder based on which the compilation database
  /// was found.
  var projectRoot: AbsolutePath { get async }

  /// The path to the raw index store data, if any.
  var indexStorePath: AbsolutePath? { get async }

  /// The path to put the index database, if any.
  var indexDatabasePath: AbsolutePath? { get async }

  /// Whether the build system is capable of preparing a target for indexing, ie. if the `prepare` methods has been
  /// implemented.
  var supportsPreparation: Bool { get }

  func buildSettings(request: BuildSettingsRequest) async throws -> BuildSettingsResponse?

  func textDocumentTargets(request: TextDocumentTargetsRequest) async throws -> TextDocumentTargetsResponse

  /// Wait until the build graph has been loaded.
  func waitForUpBuildSystemUpdates(request: WaitForBuildSystemUpdatesRequest) async -> VoidResponse

  /// Prepare the given targets for indexing and semantic functionality. This should build all swift modules of target
  /// dependencies.
  func prepare(request: PrepareTargetsRequest) async throws -> VoidResponse

  /// Called when files in the project change.
  func didChangeWatchedFiles(notification: BuildSystemIntegrationProtocol.DidChangeWatchedFilesNotification) async

  /// Returns the list of source files in the project.
  ///
  /// Header files should not be considered as source files because they cannot be compiled.
  func sourceFiles(request: WorkspaceSourceFilesRequest) async -> WorkspaceSourceFilesResponse

  func workspaceTargets(request: WorkspaceTargetsRequest) async -> WorkspaceTargetsResponse
}

/// Create a build system of the given type.
private func createBuildSystem(
  buildSystemKind: BuildSystemKind,
  options: SourceKitLSPOptions,
  buildSystemTestHooks: BuildSystemTestHooks,
  toolchainRegistry: ToolchainRegistry,
  connectionToSourceKitLSP: any Connection
) async -> BuiltInBuildSystem? {
  switch buildSystemKind {
  case .buildServer(let projectRoot):
    return await BuildServerBuildSystem(projectRoot: projectRoot, connectionToSourceKitLSP: connectionToSourceKitLSP)
  case .compilationDatabase(let projectRoot):
    return CompilationDatabaseBuildSystem(
      projectRoot: projectRoot,
      searchPaths: (options.compilationDatabase.searchPaths ?? []).compactMap { try? RelativePath(validating: $0) },
      connectionToSourceKitLSP: connectionToSourceKitLSP
    )
  case .swiftPM(let projectRoot):
    return await SwiftPMBuildSystem(
      projectRoot: projectRoot,
      toolchainRegistry: toolchainRegistry,
      options: options,
      connectionToSourceKitLSP: connectionToSourceKitLSP,
      testHooks: buildSystemTestHooks.swiftPMTestHooks
    )
  case .testBuildSystem(let projectRoot):
    return TestBuildSystem(projectRoot: projectRoot, connectionToSourceKitLSP: connectionToSourceKitLSP)
  }
}

package enum BuildSystemKind {
  case buildServer(projectRoot: AbsolutePath)
  case compilationDatabase(projectRoot: AbsolutePath)
  case swiftPM(projectRoot: AbsolutePath)
  case testBuildSystem(projectRoot: AbsolutePath)

  package var projectRoot: AbsolutePath {
    switch self {
    case .buildServer(let projectRoot): return projectRoot
    case .compilationDatabase(let projectRoot): return projectRoot
    case .swiftPM(let projectRoot): return projectRoot
    case .testBuildSystem(let projectRoot): return projectRoot
    }
  }
}

/// A type that outwardly acts as a build server conforming to the Build System Integration Protocol and internally uses
/// a `BuiltInBuildSystem` to satisfy the requests.
package actor BuiltInBuildSystemAdapter: MessageHandler {
  /// The underlying build system.
  // FIXME: This should be private, all messages should go through BSIP. Only accessible from the outside for transition
  // purposes.
  private(set) package var underlyingBuildSystem: BuiltInBuildSystem!
  private let connectionToSourceKitLSP: LocalConnection

  // FIXME: Can we have more fine-grained dependency tracking here?
  private let messageHandlingQueue = AsyncQueue<Serial>()

  init?(
    buildSystemKind: BuildSystemKind?,
    toolchainRegistry: ToolchainRegistry,
    options: SourceKitLSPOptions,
    buildSystemTestHooks: BuildSystemTestHooks,
    connectionToSourceKitLSP: LocalConnection
  ) async {
    guard let buildSystemKind else {
      return nil
    }
    self.connectionToSourceKitLSP = connectionToSourceKitLSP

    let buildSystem = await createBuildSystem(
      buildSystemKind: buildSystemKind,
      options: options,
      buildSystemTestHooks: buildSystemTestHooks,
      toolchainRegistry: toolchainRegistry,
      connectionToSourceKitLSP: connectionToSourceKitLSP
    )
    guard let buildSystem else {
      return nil
    }

    self.underlyingBuildSystem = buildSystem
  }

  private func initialize(
    request: BuildSystemIntegrationProtocol.InitializeRequest
  ) async -> BuildSystemIntegrationProtocol.InitializeResponse {
    return await BuildSystemIntegrationProtocol.InitializeResponse(
      indexStorePath: underlyingBuildSystem.indexStorePath?.pathString,
      indexDatabasePath: underlyingBuildSystem.indexDatabasePath?.pathString,
      watchers: [],
      capabilities: BuildSystemCapabilities(supportsPreparation: underlyingBuildSystem.supportsPreparation)
    )
  }

  nonisolated package func handle(_ notification: some NotificationType) {
    let signposter = Logger(subsystem: LoggingScope.subsystem, category: "build-system-message-handling")
      .makeSignposter()
    let signpostID = signposter.makeSignpostID()
    let state = signposter.beginInterval("Notification", id: signpostID, "\(type(of: notification))")
    messageHandlingQueue.async {
      signposter.emitEvent("Start handling", id: signpostID)
      await self.handleImpl(notification)
      signposter.endInterval("Notification", state, "Done")
    }
  }

  private func handleImpl(_ notification: some NotificationType) async {
    switch notification {
    case let notification as DidChangeWatchedFilesNotification:
      await self.underlyingBuildSystem.didChangeWatchedFiles(notification: notification)
    default:
      logger.error("Ignoring unknown notification \(type(of: notification).method) from SourceKit-LSP")
    }
  }

  package nonisolated func handle<R: RequestType>(
    _ params: R,
    id: RequestID,
    reply: @Sendable @escaping (LSPResult<R.Response>) -> Void
  ) {
    // FIXME: Can we share this between the different message handler implementations?
    let signposter = Logger(subsystem: LoggingScope.subsystem, category: "build-system-message-handling")
      .makeSignposter()
    let signpostID = signposter.makeSignpostID()
    let state = signposter.beginInterval("Request", id: signpostID, "\(R.self)")

    messageHandlingQueue.async {
      signposter.emitEvent("Start handling", id: signpostID)
      await withTaskCancellationHandler {
        await self.handleImpl(params, id: id, reply: reply)
        signposter.endInterval("Request", state, "Done")
      } onCancel: {
        signposter.emitEvent("Cancelled", id: signpostID)
      }
    }
  }

  private func handleImpl<Request: RequestType>(
    _ request: Request,
    id: RequestID,
    reply: @escaping @Sendable (LSPResult<Request.Response>) -> Void
  ) async {
    let startDate = Date()

    let request = RequestAndReply(request) { result in
      reply(result)
      let endDate = Date()
      Task {
        switch result {
        case .success(let response):
          logger.log(
            """
            Succeeded (took \(endDate.timeIntervalSince(startDate) * 1000, privacy: .public)ms)
            \(Request.method, privacy: .public)
            \(response.forLogging)
            """
          )
        case .failure(let error):
          logger.log(
            """
            Failed (took \(endDate.timeIntervalSince(startDate) * 1000, privacy: .public)ms)
            \(Request.method, privacy: .public)(\(id, privacy: .public))
            \(error.forLogging, privacy: .private)
            """
          )
        }
      }
    }

    switch request {
    case let request as RequestAndReply<BuildSettingsRequest>:
      await request.reply { try await underlyingBuildSystem.buildSettings(request: request.params) }
    case let request as RequestAndReply<BuildSystemIntegrationProtocol.InitializeRequest>:
      await request.reply { await self.initialize(request: request.params) }
    case let request as RequestAndReply<TextDocumentTargetsRequest>:
      await request.reply { try await underlyingBuildSystem.textDocumentTargets(request: request.params) }
    case let request as RequestAndReply<PrepareTargetsRequest>:
      await request.reply { try await underlyingBuildSystem.prepare(request: request.params) }
    case let request as RequestAndReply<WaitForBuildSystemUpdatesRequest>:
      await request.reply { await underlyingBuildSystem.waitForUpBuildSystemUpdates(request: request.params) }
    case let request as RequestAndReply<WorkspaceSourceFilesRequest>:
      await request.reply { await underlyingBuildSystem.sourceFiles(request: request.params) }
    case let request as RequestAndReply<WorkspaceTargetsRequest>:
      await request.reply { await underlyingBuildSystem.workspaceTargets(request: request.params) }
    default:
      await request.reply { throw ResponseError.methodNotFound(Request.method) }
    }
  }
}
