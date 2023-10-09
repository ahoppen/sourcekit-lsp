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

@_exported import Csourcekitd

import SKSupport
import LSPLogging
import Dispatch
import Foundation
import os

/// Access to sourcekitd API, taking care of initialization, shutdown, and notification handler
/// multiplexing.
///
/// *Users* of this protocol should not call the api functions `initialize`, `shutdown`, or
/// `set_notification_handler`, which are global state managed internally by this class.
///
/// *Implementors* are expected to handle initialization and shutdown, e.g. during `init` and
/// `deinit` or by wrapping an existing sourcekitd session that outlives this object.
public protocol SourceKitD: AnyObject {
  /// The sourcekitd API functions.
  var api: sourcekitd_functions_t { get }

  /// Convenience for accessing known keys.
  var keys: sourcekitd_keys { get }

  /// Convenience for accessing known keys.
  var requests: sourcekitd_requests { get }

  /// Convenience for accessing known keys.
  var values: sourcekitd_values { get }

  /// Adds a new notification handler, which will be weakly referenced.
  func addNotificationHandler(_ handler: SKDNotificationHandler)

  /// Removes a previously registered notification handler.
  func removeNotificationHandler(_ handler: SKDNotificationHandler)
}

public enum SKDError: Error, Equatable {
  /// The service has crashed.
  case connectionInterrupted

  /// The request was unknown or had an invalid or missing parameter.
  case requestInvalid(String)

  /// The request failed.
  case requestFailed(String)

  /// The request was cancelled.
  case requestCancelled

  /// Loading a required symbol from the sourcekitd library failed.
  case missingRequiredSymbol(String)
}

extension SourceKitD {

  // MARK: - Convenience API for requests.

  /// Send the given request and synchronously receive a reply dictionary (or error).
  public func sendSync(_ req: SKDRequestDictionary) throws -> SKDResponseDictionary {
    logRequest(req)

    let resp = SKDResponse(api.send_request_sync(req.dict), sourcekitd: self)

    logResponse(resp)

    guard let dict = resp.value else {
      throw resp.error!
    }

    return dict
  }

  public func send(_ req: SKDRequestDictionary) async throws -> SKDResponseDictionary {
    logRequest(req)

    let handleWrapper = ThreadSafeBox<sourcekitd_request_handle_t?>(initialValue: nil as sourcekitd_request_handle_t?)

    let signposter = OSSignposter(logger: logger)
    let signpostID = signposter.makeSignpostID()
    let state = signposter.beginInterval("sourcekitd-request", id: signpostID, "Start")
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        var handle: sourcekitd_request_handle_t?
        let loggingScope = LoggingScope.scope ?? "default"
        api.send_request(req.dict, &handle) { [weak self] _resp in
          withLoggingScope(loggingScope) {
            guard let self = self else { return }

            let resp = SKDResponse(_resp, sourcekitd: self)

            if Task.isCancelled {
              continuation.resume(throwing: CancellationError())
              signposter.endInterval("sourcekitd-request", state, "Cancelled")
              return
            }

            logResponse(resp)

            guard let dict = resp.value else {
              continuation.resume(throwing: resp.error!)
              signposter.endInterval("sourcekitd-request", state, "Error")
              return
            }

            signposter.endInterval("sourcekitd-request", state, "Done")
            continuation.resume(returning: dict)
          }
        }
        handleWrapper.value = handle
      }
    } onCancel: {
      if let handle = handleWrapper.value {
        api.cancel_request(handle)
      }
    }
  }
}

private func logRequest(_ request: SKDRequestDictionary) {
  // FIXME: Ideally we could log the request key here at the info level but the dictionary is
  // readonly.
  logger.log(
    """
    Sending sourcekitd request:
    \(request.loggable)
    """
  )
}

private func logResponse(_ response: SKDResponse) {
  logger.log(
    level: (response.error == nil || response.error == .requestCancelled) ? .debug : .error,
    """
    Received sourcekitd response:
    \(response.loggable)
    """
  )
}

/// A sourcekitd notification handler in a class to allow it to be uniquely referenced.
public protocol SKDNotificationHandler: AnyObject {
  func notification(_: SKDResponse) -> Void
}
