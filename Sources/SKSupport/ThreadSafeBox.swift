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

import Foundation

/// A thread safe container that contains a value of type `T`.
public class ThreadSafeBox<T> {
  private let lock = NSLock()

  private var _value: T

  public var value: T {
    get {
      return lock.withLock {
        return _value
      }
    }
    set {
      lock.withLock {
        _value = newValue
      }
    }
  }

  public init(initialValue: T) {
    _value = initialValue
  }
}
