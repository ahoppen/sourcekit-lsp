//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import Crypto

import os // os_log


/// Log levels (from https://developer.apple.com/wwdc20/10168?time=604)
///  - Debug: Useful only during debugging (only logged during debugging)
///  - Info: Helpful but not essential for troubleshooting (not persisted, logged to memory)
///  - Notice/log (Default): Essential for troubleshooting
///  - Error: Error seen during execution
///  - Fault: Bug in program

public protocol LogPrintable {
  var description: String { get }
  var redactedDescription: String { get }
}

extension LogPrintable {
  public var loggable: LogPrintableWrapper {
    return LogPrintableWrapper(self)
  }
}

public class LogPrintableWrapper: NSObject {
  private let underlyingObject: any LogPrintable

  fileprivate init(_ underlyingObject: any LogPrintable) {
    self.underlyingObject = underlyingObject
  }

  public override var description: String {
    return underlyingObject.description
  }

  @objc public var redactedDescription: String {
    underlyingObject.redactedDescription
  }
}

extension CustomStringConvertible {
  public var hashForLog: String {
    guard let data = self.description.data(using: .utf8) else {
      return "invalid data"
    }
    return SHA256.hash(data: data).description
  }
}

struct MaskedError: LogPrintable {
  let underlyingError: any Error

  init(_ underlyingError: any Error) {
    self.underlyingError = underlyingError
  }

  var description: String {
    return "\(underlyingError)"
  }

  var redactedDescription: String {
    let error = underlyingError as NSError
    return "\(error.code): \(error.hashForLog)"
  }
}

extension Error {
  public var loggable: LogPrintableWrapper {
    if let error = self as? LogPrintable {
      return error.loggable
    } else {
      return MaskedError(self).loggable
    }
  }
}

/// Create a new logging scope, which will be used as the category in any log
/// messages created from the operation.
///
/// If a scope already exists, `scope` is appended.
///
/// `scope` should not contain any `.` because `.` is used to denote sub-scopes.
public func withLoggingScope<Result>(
  _ scope: String,
  
  _ operation: () throws -> Result
) rethrows -> Result {
  let newScope: String
  if let existingScope = LoggingScope.scope {
    newScope = "\(existingScope).\(scope)"
  } else {
    newScope = scope
  }
  return try LoggingScope.$scope.withValue(newScope, operation: operation)
}

public func withLoggingScope<Result>(_ scope: String, _ operation: () async throws -> Result) async rethrows -> Result {
  let newScope: String
  if let existingScope = LoggingScope.scope {
    newScope = "\(existingScope).\(scope)"
  } else {
    newScope = scope
  }
  return try await LoggingScope.$scope.withValue(newScope, operation: operation)
}

public final class LoggingScope {
  @TaskLocal public static var scope: String?
}

public let subsystem = "org.swift.sourcekit-lsp"

public var logger: os.Logger {
  os.Logger(subsystem: subsystem, category: LoggingScope.scope ?? "default")
}



/// Like `try?`, but logs the error on failure.
public func orLog<R>(
  _ prefix: String = "",
  level: OSLogType = .error,
  _ block: () throws -> R?) -> R?
{
  do {
    return try block()
  } catch {
    logger.log(level: level, "\(prefix, privacy: .public)\(prefix.isEmpty ? "" : " ", privacy: .public)\(error.loggable)")
    return nil
  }
}

/// Like `try?`, but logs the error on failure.
public func orLog<R>(
  _ prefix: String = "",
  level: OSLogType = .error,
  _ block: () async throws -> R?) async -> R?
{
  do {
    return try await block()
  } catch {
    logger.log(level: level, "\(prefix, privacy: .public)\(prefix.isEmpty ? "" : " ", privacy: .public)\(error.loggable)")
    return nil
  }
}
