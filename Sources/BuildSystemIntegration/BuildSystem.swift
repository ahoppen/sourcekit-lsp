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
import LanguageServerProtocol
import SKLogging
import SKOptions
import SKSupport
import SwiftExtensions
import ToolchainRegistry

import struct TSCBasic.AbsolutePath
import struct TSCBasic.RelativePath

/// Defines how well a `BuildSystem` can handle a file with a given URI.
package enum FileHandlingCapability: Comparable, Sendable {
  /// The build system can't handle the file at all
  case unhandled

  /// The build system has fallback build settings for the file
  case fallback

  /// The build system knows how to handle the file
  case handled
}

package struct SourceFileInfo: Sendable {
  /// The URI of the source file.
  package let uri: DocumentURI

  /// `true` if this file belongs to the root project that the user is working on. It is false, if the file belongs
  /// to a dependency of the project.
  package let isPartOfRootProject: Bool

  /// Whether the file might contain test cases. This property is an over-approximation. It might be true for files
  /// from non-test targets or files that don't actually contain any tests. Keeping this list of files with
  /// `mayContainTets` minimal as possible helps reduce the amount of work that the syntactic test indexer needs to
  /// perform.
  package let mayContainTests: Bool

  package init(uri: DocumentURI, isPartOfRootProject: Bool, mayContainTests: Bool) {
    self.uri = uri
    self.isPartOfRootProject = isPartOfRootProject
    self.mayContainTests = mayContainTests
  }
}

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

  /// Delegate to handle any build system events such as file build settings initial reports as well as changes.
  ///
  /// The build system must not retain the delegate because the delegate can be the `BuildSystemManager`, which could
  /// result in a retain cycle `BuildSystemManager` -> `BuildSystem` -> `BuildSystemManager`.
  var delegate: BuildSystemDelegate? { get async }

  /// Set the build system's delegate.
  ///
  /// - Note: Needed so we can set the delegate from a different actor isolation
  ///   context.
  func setDelegate(_ delegate: BuildSystemDelegate?) async

  /// Whether the build system is capable of preparing a target for indexing, ie. if the `prepare` methods has been
  /// implemented.
  var supportsPreparation: Bool { get }

  func buildSettings(request: BuildSettingsRequest) async throws -> BuildSettingsResponse?

  func textDocumentTargets(_ request: TextDocumentTargetsRequest) async throws -> TextDocumentTargetsResponse

  /// Re-generate the build graph.
  func generateBuildGraph() async throws

  /// Wait until the build graph has been loaded.
  func waitForUpToDateBuildGraph() async

  /// Sort the targets so that low-level targets occur before high-level targets.
  ///
  /// This sorting is best effort but allows the indexer to prepare and index low-level targets first, which allows
  /// index data to be available earlier.
  ///
  /// `nil` if the build system doesn't support topological sorting of targets.
  func topologicalSort(of targets: [ConfiguredTarget]) async -> [ConfiguredTarget]?

  /// Returns the list of targets that might depend on the given target and that need to be re-prepared when a file in
  /// `target` is modified.
  ///
  /// The returned list can be an over-approximation, in which case the indexer will perform more work than strictly
  /// necessary by scheduling re-preparation of a target where it isn't necessary.
  ///
  /// Returning `nil` indicates that all targets should be considered depending on the given target.
  func targets(dependingOn targets: [ConfiguredTarget]) async -> [ConfiguredTarget]?

  /// Prepare the given targets for indexing and semantic functionality. This should build all swift modules of target
  /// dependencies.
  func prepare(
    targets: [ConfiguredTarget],
    logMessageToIndexLog: @escaping @Sendable (_ taskID: IndexTaskID, _ message: String) -> Void
  ) async throws

  /// If the build system has knowledge about the language that this document should be compiled in, return it.
  ///
  /// This is used to determine the language in which a source file should be background indexed.
  ///
  /// If `nil` is returned, the language based on the file's extension.
  func defaultLanguage(for document: DocumentURI) async -> Language?

  /// The toolchain that should be used to open the given document.
  ///
  /// If `nil` is returned, then the default toolchain for the given language is used.
  func toolchain(for uri: DocumentURI, _ language: Language) async -> Toolchain?

  /// Register the given file for build-system level change notifications, such
  /// as command line flag changes, dependency changes, etc.
  ///
  /// IMPORTANT: When first receiving a register request, the `BuildSystem` MUST asynchronously
  /// inform its delegate of any initial settings for the given file via the
  /// `fileBuildSettingsChanged` method, even if unavailable.
  func registerForChangeNotifications(for: DocumentURI) async

  /// Unregister the given file for build-system level change notifications,
  /// such as command line flag changes, dependency changes, etc.
  func unregisterForChangeNotifications(for: DocumentURI) async

  /// Called when files in the project change.
  func didChangeWatchedFiles(notification: BuildSystemIntegrationProtocol.DidChangeWatchedFilesNotification) async

  func fileHandlingCapability(for uri: DocumentURI) async -> FileHandlingCapability

  /// Returns the list of source files in the project.
  ///
  /// Header files should not be considered as source files because they cannot be compiled.
  func sourceFiles() async -> [SourceFileInfo]

  /// Adds a callback that should be called when the value returned by `sourceFiles()` changes.
  ///
  /// The callback might also be called without an actual change to `sourceFiles`.
  func addSourceFilesDidChangeCallback(_ callback: @Sendable @escaping () async -> Void) async
}

// FIXME: This should be a MessageHandler once we have migrated all build system queries to BSIP and can use
// LocalConnection for the communication.
protocol BuiltInBuildSystemAdapterDelegate: Sendable {
  func handle(_ notification: some NotificationType) async
  func handle<R: RequestType>(_ request: R) async throws -> R.Response
}

// FIXME: This should be a MessageHandler once we have migrated all build system queries to BSIP and can use
// LocalConnection for the communication.
package protocol BuiltInBuildSystemMessageHandler: AnyObject, Sendable {
  func handle(_ notification: some NotificationType) async
  func handle<R: RequestType>(_ request: R) async throws -> R.Response
}

/// Create a build system of the given type.
private func createBuildSystem(
  buildSystemKind: BuildSystemKind,
  options: SourceKitLSPOptions,
  swiftpmTestHooks: SwiftPMTestHooks,
  toolchainRegistry: ToolchainRegistry,
  messageHandler: BuiltInBuildSystemMessageHandler,
  reloadPackageStatusCallback: @Sendable @escaping (ReloadPackageStatus) async -> Void
) async -> BuiltInBuildSystem? {
  switch buildSystemKind {
  case .buildServer(let projectRoot):
    return await BuildServerBuildSystem(projectRoot: projectRoot, messageHandler: messageHandler)
  case .compilationDatabase(let projectRoot):
    return CompilationDatabaseBuildSystem(
      projectRoot: projectRoot,
      searchPaths: (options.compilationDatabase.searchPaths ?? []).compactMap { try? RelativePath(validating: $0) },
      messageHandler: messageHandler
    )
  case .swiftPM(let projectRoot):
    return await SwiftPMBuildSystem(
      projectRoot: projectRoot,
      toolchainRegistry: toolchainRegistry,
      options: options,
      messageHandler: messageHandler,
      reloadPackageStatusCallback: reloadPackageStatusCallback,
      testHooks: swiftpmTestHooks
    )
  case .testBuildSystem(let projectRoot):
    return TestBuildSystem(projectRoot: projectRoot, messageHandler: messageHandler)
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
package actor BuiltInBuildSystemAdapter: BuiltInBuildSystemMessageHandler {
  /// The underlying build system.
  // FIXME: This should be private, all messages should go through BSIP. Only accessible from the outside for transition
  // purposes.
  private(set) package var underlyingBuildSystem: BuiltInBuildSystem!
  private let messageHandler: any BuiltInBuildSystemAdapterDelegate

  init?(
    buildSystemKind: BuildSystemKind?,
    toolchainRegistry: ToolchainRegistry,
    options: SourceKitLSPOptions,
    swiftpmTestHooks: SwiftPMTestHooks,
    reloadPackageStatusCallback: @Sendable @escaping (ReloadPackageStatus) async -> Void,
    messageHandler: any BuiltInBuildSystemAdapterDelegate
  ) async {
    guard let buildSystemKind else {
      return nil
    }
    self.messageHandler = messageHandler

    let buildSystem = await createBuildSystem(
      buildSystemKind: buildSystemKind,
      options: options,
      swiftpmTestHooks: swiftpmTestHooks,
      toolchainRegistry: toolchainRegistry,
      messageHandler: self,
      reloadPackageStatusCallback: reloadPackageStatusCallback
    )
    guard let buildSystem else {
      return nil
    }

    self.underlyingBuildSystem = buildSystem
  }

  package func send<R: RequestType>(_ request: R) async throws -> R.Response {
    logger.info(
      """
      Received request to build system
      \(request.forLogging)
      """
    )
    /// Executes `body` and casts the result type to `R.Response`, statically checking that the return type of `body` is
    /// the response type of `request`.
    func handle<HandledRequestType: RequestType>(
      _ request: HandledRequestType,
      _ body: (HandledRequestType) async throws -> HandledRequestType.Response
    ) async throws -> R.Response {
      return try await body(request) as! R.Response
    }

    switch request {
    case let request as BuildSettingsRequest:
      return try await handle(request, underlyingBuildSystem.buildSettings)
    case let request as TextDocumentTargetsRequest:
      return try await handle(request, underlyingBuildSystem.textDocumentTargets)
    default:
      throw ResponseError.methodNotFound(R.method)
    }
  }

  package func send(_ notification: some NotificationType) async {
    logger.info(
      """
      Sending notification to build system
      \(notification.forLogging)
      """
    )
    // FIXME: These messages should be handled using a LocalConnection, which also gives us logging for the messages
    // sent. We can only do this once all requests to the build system have been migrated and we can implement proper
    // dependency management between the BSIP messages
    switch notification {
    case let notification as DidChangeWatchedFilesNotification:
      await self.underlyingBuildSystem.didChangeWatchedFiles(notification: notification)
    default:
      logger.error("Ignoring unknown notification \(type(of: notification).method) from SourceKit-LSP")
    }
  }

  package func handle(_ notification: some LanguageServerProtocol.NotificationType) async {
    logger.info(
      """
      Received notification from build system
      \(notification.forLogging)
      """
    )
    await messageHandler.handle(notification)
  }

  package func handle<R: RequestType>(_ request: R) async throws -> R.Response {
    logger.info(
      """
      Received request from build system
      \(request.forLogging)
      """
    )
    return try await messageHandler.handle(request)
  }

}
