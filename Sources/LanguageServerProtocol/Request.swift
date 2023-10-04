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

/// A request object, wrapping the parameters of a `RequestType` and tracking its state.
public final class Request<R: RequestType> {

  public typealias Params = R

  public typealias Response = R.Response

  /// The request id from the client.
  public let id: RequestID

  /// The request parameters.
  public let params: Params

  private var replyBlock: (LSPResult<Response>) -> Void

  /// Whether a reply has been made. Every request must reply exactly once.
  private var replied: Bool = false {
    willSet {
      precondition(replied == false, "replied to \(id) more than once")
    }
  }

  public init(_ request: Params, id: RequestID, reply: @escaping (LSPResult<Response>) -> Void) {
    self.id = id
    self.params = request
    self.replyBlock = reply
  }

  deinit {
    precondition(replied, "request \(id) never received a reply")
  }

  /// Reply to the request with `result`.
  ///
  /// This must be called exactly once for each request.
  public func reply(_ result: LSPResult<Response>) {
    replied = true
    replyBlock(result)
  }

  /// Reply to the request with `.success(result)`.
  public func reply(_ result: Response) {
    reply(.success(result))
  }
}

/// A request object, wrapping the parameters of a `NotificationType`.
public final class Notification<N: NotificationType> {

  public typealias Params = N

  /// The request parameters.
  public let params: Params

  public init(_ notification: Params) {
    self.params = notification
  }
}

extension Request: CustomStringConvertible {
  public var description: String {
    return """
    Request<\(R.method)>(
      id: \(id),
      params: \(params)
    )
    """
  }
}

extension Notification: CustomStringConvertible {
  public var description: String {
    return """
    Notification<\(N.method)>(
      params: \(params)
    )
    """
  }
}
