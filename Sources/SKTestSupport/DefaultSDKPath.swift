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

import class TSCBasic.Process

private func xcrunSDKPath() -> String {
  var path = try! Process.checkNonZeroExit(arguments: ["/usr/bin/xcrun", "--show-sdk-path", "--sdk", "macosx"])
  if path.last == "\n" {
    path = String(path.dropLast())
  }
  return path
}

/// The default sdk path to use.
public let defaultSDKPath: String? = {
  #if os(macOS)
  return xcrunSDKPath()
  #else
  return ProcessInfo.processInfo.environment["SDKROOT"]
  #endif
}()
