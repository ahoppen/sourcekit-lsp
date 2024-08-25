//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import BuildSystemIntegration
import IndexStoreDB
import LanguageServerProtocol
import SKLogging
import SKOptions
import SKSupport
import SemanticIndex
import SwiftExtensions
import ToolchainRegistry

import struct TSCBasic.AbsolutePath
import struct TSCBasic.RelativePath

/// Same as `??` but allows the right-hand side of the operator to 'await'.
fileprivate func firstNonNil<T>(_ optional: T?, _ defaultValue: @autoclosure () async throws -> T) async rethrows -> T {
  if let optional {
    return optional
  }
  return try await defaultValue()
}

fileprivate func firstNonNil<T>(
  _ optional: T?,
  _ defaultValue: @autoclosure () async throws -> T?
) async rethrows -> T? {
  if let optional {
    return optional
  }
  return try await defaultValue()
}

/// Represents the configuration and state of a project or combination of projects being worked on
/// together.
///
/// In LSP, this represents the per-workspace state that is typically only available after the
/// "initialize" request has been made.
///
/// Typically a workspace is contained in a root directory.
package final class Workspace: Sendable {

  /// The root directory of the workspace.
  package let rootUri: DocumentURI?

  /// Tracks dynamically registered server capabilities as well as the client's capabilities.
  package let capabilityRegistry: CapabilityRegistry

  /// The build system manager to use for documents in this workspace.
  package let buildSystemManager: BuildSystemManager

  let options: SourceKitLSPOptions

  /// The source code index, if available.
  ///
  /// Usually a checked index (retrieved using `index(checkedFor:)`) should be used instead of the unchecked index.
  private let _uncheckedIndex: ThreadSafeBox<UncheckedIndex?>

  package var uncheckedIndex: UncheckedIndex? {
    return _uncheckedIndex.value
  }

  /// The index that syntactically scans the workspace for tests.
  let syntacticTestIndex = SyntacticTestIndex()

  /// Documents open in the SourceKitLSPServer. This may include open documents from other workspaces.
  private let documentManager: DocumentManager

  /// Language service for an open document, if available.
  private let documentService: ThreadSafeBox<[DocumentURI: LanguageService]> = ThreadSafeBox(initialValue: [:])

  /// The `SemanticIndexManager` that keeps track of whose file's index is up-to-date in the workspace and schedules
  /// indexing and preparation tasks for files with out-of-date index.
  ///
  /// `nil` if background indexing is not enabled.
  let semanticIndexManager: SemanticIndexManager?

  private init(
    documentManager: DocumentManager,
    rootUri: DocumentURI?,
    capabilityRegistry: CapabilityRegistry,
    options: SourceKitLSPOptions,
    testHooks: TestHooks,
    buildSystemManager: BuildSystemManager,
    index uncheckedIndex: UncheckedIndex?,
    indexDelegate: SourceKitIndexDelegate?,
    indexTaskScheduler: TaskScheduler<AnyIndexTaskDescription>,
    logMessageToIndexLog: @escaping @Sendable (_ taskID: IndexTaskID, _ message: String) -> Void,
    indexTasksWereScheduled: @escaping @Sendable (Int) -> Void,
    indexProgressStatusDidChange: @escaping @Sendable () -> Void
  ) async {
    self.documentManager = documentManager
    self.rootUri = rootUri
    self.capabilityRegistry = capabilityRegistry
    self.options = options
    self._uncheckedIndex = ThreadSafeBox(initialValue: uncheckedIndex)
    self.buildSystemManager = buildSystemManager
    if options.backgroundIndexingOrDefault, let uncheckedIndex, await buildSystemManager.supportsPreparation {
      self.semanticIndexManager = SemanticIndexManager(
        index: uncheckedIndex,
        buildSystemManager: buildSystemManager,
        updateIndexStoreTimeout: options.index.updateIndexStoreTimeoutOrDefault,
        testHooks: testHooks.indexTestHooks,
        indexTaskScheduler: indexTaskScheduler,
        logMessageToIndexLog: logMessageToIndexLog,
        indexTasksWereScheduled: indexTasksWereScheduled,
        indexProgressStatusDidChange: indexProgressStatusDidChange
      )
    } else {
      self.semanticIndexManager = nil
    }
    await indexDelegate?.addMainFileChangedCallback { [weak self] in
      await self?.buildSystemManager.mainFilesChanged()
    }
    // Trigger an initial population of `syntacticTestIndex`.
    let testFiles = await orLog("Getting test files") { try await self.buildSystemManager.testFiles() } ?? []
    await syntacticTestIndex.listOfTestFilesDidChange(testFiles)
    if let semanticIndexManager {
      await semanticIndexManager.scheduleBuildGraphGenerationAndBackgroundIndexAllFiles(
        filesToIndex: nil,
        indexFilesWithUpToDateUnit: false
      )
    }
  }

  /// Creates a workspace for a given root `DocumentURI`, inferring the `ExternalWorkspace` if possible.
  ///
  /// - Parameters:
  ///   - url: The root directory of the workspace, which must be a valid path.
  ///   - clientCapabilities: The client capabilities provided during server initialization.
  ///   - toolchainRegistry: The toolchain registry.
  convenience init(
    documentManager: DocumentManager,
    rootUri: DocumentURI?,
    capabilityRegistry: CapabilityRegistry,
    buildSystemKind: BuildSystemKind?,
    toolchainRegistry: ToolchainRegistry,
    options: SourceKitLSPOptions,
    testHooks: TestHooks,
    indexTaskScheduler: TaskScheduler<AnyIndexTaskDescription>,
    buildSystemManagerDelegate: BuildSystemManagerDelegate,
    logMessageToIndexLog: @escaping @Sendable (_ taskID: IndexTaskID, _ message: String) -> Void,
    indexTasksWereScheduled: @Sendable @escaping (Int) -> Void,
    indexProgressStatusDidChange: @Sendable @escaping () -> Void,
    reloadPackageStatusCallback: @Sendable @escaping (ReloadPackageStatus) async -> Void
  ) async {
    let buildSystemManager = await BuildSystemManager(
      buildSystemKind: buildSystemKind,
      toolchainRegistry: toolchainRegistry,
      options: options,
      swiftpmTestHooks: testHooks.swiftpmTestHooks,
      delegate: buildSystemManagerDelegate,
      reloadPackageStatusCallback: reloadPackageStatusCallback
    )
    let buildSystem = await buildSystemManager.buildSystem?.underlyingBuildSystem

    let buildSystemType =
      if let buildSystem {
        String(describing: type(of: buildSystem))
      } else {
        "<fallback build system>"
      }
    logger.log(
      "Created workspace at \(rootUri.forLogging) as \(buildSystemType, privacy: .public) with project root \(buildSystemKind?.projectRoot.pathString ?? "<nil>")"
    )

    var index: IndexStoreDB? = nil
    var indexDelegate: SourceKitIndexDelegate? = nil

    let indexOptions = options.index
    let indexStorePath = await firstNonNil(
      AbsolutePath(validatingOrNil: indexOptions.indexStorePath),
      await AbsolutePath(validatingOrNil: buildSystemManager.indexStorePath)
    )
    let indexDatabasePath = await firstNonNil(
      AbsolutePath(validatingOrNil: indexOptions.indexDatabasePath),
      await AbsolutePath(validatingOrNil: buildSystemManager.indexDatabasePath)
    )
    if let indexStorePath, let indexDatabasePath, let libPath = await toolchainRegistry.default?.libIndexStore {
      do {
        let lib = try IndexStoreLibrary(dylibPath: libPath.pathString)
        indexDelegate = SourceKitIndexDelegate()
        let prefixMappings =
          indexOptions.indexPrefixMap?.map { PathPrefixMapping(original: $0.key, replacement: $0.value) } ?? []
        index = try IndexStoreDB(
          storePath: indexStorePath.pathString,
          databasePath: indexDatabasePath.pathString,
          library: lib,
          delegate: indexDelegate,
          prefixMappings: prefixMappings.map { PathMapping(original: $0.original, replacement: $0.replacement) }
        )
        logger.debug("Opened IndexStoreDB at \(indexDatabasePath) with store path \(indexStorePath)")
      } catch {
        logger.error("Failed to open IndexStoreDB: \(error.localizedDescription)")
      }
    }

    await buildSystemManager.setMainFilesProvider(UncheckedIndex(index))

    await self.init(
      documentManager: documentManager,
      rootUri: rootUri,
      capabilityRegistry: capabilityRegistry,
      options: options,
      testHooks: testHooks,
      buildSystemManager: buildSystemManager,
      index: UncheckedIndex(index),
      indexDelegate: indexDelegate,
      indexTaskScheduler: indexTaskScheduler,
      logMessageToIndexLog: logMessageToIndexLog,
      indexTasksWereScheduled: indexTasksWereScheduled,
      indexProgressStatusDidChange: indexProgressStatusDidChange
    )
  }

  package static func forTesting(
    options: SourceKitLSPOptions,
    testHooks: TestHooks,
    buildSystemManager: BuildSystemManager,
    indexTaskScheduler: TaskScheduler<AnyIndexTaskDescription>
  ) async -> Workspace {
    return await Workspace(
      documentManager: DocumentManager(),
      rootUri: nil,
      capabilityRegistry: CapabilityRegistry(clientCapabilities: ClientCapabilities()),
      options: options,
      testHooks: testHooks,
      buildSystemManager: buildSystemManager,
      index: nil,
      indexDelegate: nil,
      indexTaskScheduler: indexTaskScheduler,
      logMessageToIndexLog: { _, _ in },
      indexTasksWereScheduled: { _ in },
      indexProgressStatusDidChange: {}
    )
  }

  /// Returns a `CheckedIndex` that verifies that all the returned entries are up-to-date with the given
  /// `IndexCheckLevel`.
  func index(checkedFor checkLevel: IndexCheckLevel) -> CheckedIndex? {
    return _uncheckedIndex.value?.checked(for: checkLevel)
  }

  /// Write the index to disk.
  ///
  /// After this method is called, the workspace will no longer have an index associated with it. It should only be
  /// called when SourceKit-LSP shuts down.
  func closeIndex() {
    _uncheckedIndex.value = nil
  }

  package func filesDidChange(_ events: [FileEvent]) async {
    await buildSystemManager.filesDidChange(events)
    await syntacticTestIndex.filesDidChange(events)
    await semanticIndexManager?.filesDidChange(events)
  }

  func documentService(for uri: DocumentURI) -> LanguageService? {
    return documentService.value[uri.primaryFile ?? uri]
  }

  /// Set a language service for a document uri and returns if none exists already.
  /// If a language service already exists for this document, eg. because two requests start creating a language
  /// service for a document and race, `newLanguageService` is dropped and the existing language service for the
  /// document is returned.
  func setDocumentService(for uri: DocumentURI, _ newLanguageService: any LanguageService) -> LanguageService {
    return documentService.withLock { service in
      if let languageService = service[uri] {
        return languageService
      }

      service[uri] = newLanguageService
      return newLanguageService
    }
  }
}

/// Wrapper around a workspace that isn't being retained.
struct WeakWorkspace {
  weak var value: Workspace?

  init(_ value: Workspace? = nil) {
    self.value = value
  }
}
