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

import CAtomics
import Foundation
import LSPLogging
import LanguageServerProtocol
import SKCore

import struct TSCBasic.AbsolutePath
import class TSCBasic.Process

private var preparationIDForLogging = AtomicUInt32(initialValue: 1)

/// Describes a task to index a set of source files.
///
/// This task description can be scheduled in a `TaskScheduler`.
public struct PreparationTaskDescription: TaskDescriptionProtocol {
  public let id = preparationIDForLogging.fetchAndIncrement()

  /// The files that should be indexed.
  private let targetsToPrepare: Set<ConfiguredTarget>

  /// The build system manager that is used to get the toolchain and build settings for the files to index.
  private let buildSystemManager: BuildSystemManager

  /// A callback that is called when the task finishes.
  ///
  /// Intended for testing purposes.
  private let didFinishCallback: @Sendable (PreparationTaskDescription) -> Void

  /// The task is idempotent because indexing the same file twice produces the same result as indexing it once.
  public var isIdempotent: Bool { true }

  public var estimatedCPUCoreCount: Int { 1 }

  public var description: String {
    return self.redactedDescription
  }

  public var redactedDescription: String {
    return "preparation-\(id)"
  }

  init(
    targetsToPrepare: Set<ConfiguredTarget>,
    buildSystemManager: BuildSystemManager,
    didFinishCallback: @escaping @Sendable (PreparationTaskDescription) -> Void
  ) {
    self.targetsToPrepare = targetsToPrepare
    self.buildSystemManager = buildSystemManager
    self.didFinishCallback = didFinishCallback
  }

  public func execute() async {
    defer {
      didFinishCallback(self)
    }
    // Only use the last two digits of the preparation ID for the logging scope to avoid creating too many scopes.
    // See comment in `withLoggingScope`.
    // The last 2 digits should be sufficient to differentiate between multiple concurrently running preparation operations
    await withLoggingScope("preparation-\(id % 100)") {
      let startDate = Date()
      let targetsToPrepareDescription = targetsToPrepare.map { $0.targetID }.joined(separator: ", ")
      logger.log(
        "Starting preparation with priority \(Task.currentPriority.rawValue, privacy: .public): \(targetsToPrepareDescription)"
      )
      let targetsToPrepare = targetsToPrepare.sorted(by: {
        ($0.targetID, $0.runDestinationID) < ($1.targetID, $1.runDestinationID)
      })
      do {
        try await buildSystemManager.prepare(targets: targetsToPrepare)
      } catch {
        logger.error(
          "Preparation failed: \(error.forLogging)"
        )
      }
      logger.log(
        "Finished preparation in \(Date().timeIntervalSince(startDate) * 1000, privacy: .public)ms: \(targetsToPrepareDescription)"
      )
    }
  }

  public func dependencies(
    to currentlyExecutingTasks: [PreparationTaskDescription]
  ) -> [TaskDependencyAction<PreparationTaskDescription>] {
    return currentlyExecutingTasks.compactMap { (other) -> TaskDependencyAction<PreparationTaskDescription>? in
      if other.targetsToPrepare.count > self.targetsToPrepare.count {
        // If there is an prepare operation with more targets already running, suspend it.
        // The most common use case for this is if we prepare all targets simultaneously during the initial preparation
        // when a project is opened and need a single target indexed for user interaction. We should suspend the
        // workspace-wide preparation and just prepare the currently needed target.
        return .cancelAndRescheduleDependency(other)
      }
      return .waitAndElevatePriorityOfDependency(other)
    }
  }
}
