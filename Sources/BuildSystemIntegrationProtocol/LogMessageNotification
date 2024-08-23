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

public struct LogMessageNotification: NotificationType {
  public static let method: String = "window/logMessage"

  /// An opaque identifier that identifies the task producing this message. A task may, for example, be the preparation of a single target.
  public var task: String

  /// The kind of log message.
  public var type: WindowMessageType

  /// The contents of the message.
  public var message: String

  public init(task: String, type: WindowMessageType, message: String) {
    self.task = task
    self.type = type
    self.message = message
  }
}
