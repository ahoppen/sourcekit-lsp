//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation

struct FailedToConstructDocumentURIFromStringError: Error, CustomStringConvertible {
  let string: String

  var description: String {
    return "Failed to construct DocumentURI from '\(string)'"
  }
}

public struct DocumentURI: Codable, Hashable, Sendable {
  /// The URL that store the URIs value
  private let storage: URL

  public var description: String {
    return storage.description
  }

  public var fileURL: URL? {
    if storage.isFileURL {
      return storage
    } else {
      return nil
    }
  }

  /// The document's URL scheme, if present.
  public var scheme: String? {
    return storage.scheme
  }

  /// Returns a filepath if the URI is a URL. If the URI is not a URL, returns
  /// the full URI as a fallback.
  /// This value is intended to be used when interacting with sourcekitd which
  /// expects a file path but is able to handle arbitrary strings as well in a
  /// fallback mode that drops semantic functionality.
  public var pseudoPath: String {
    if storage.isFileURL {
      return storage.withUnsafeFileSystemRepresentation { filePathPtr in
        guard let filePathPtr else {
          return ""
        }
        let filePath = String(cString: filePathPtr)
        #if os(Windows)
        // VS Code spells file paths with a lowercase drive letter, while the rest of Windows APIs use an uppercase
        // drive letter. Normalize the drive letter spelling to be uppercase.
        if filePath.first?.isASCII ?? false, filePath.first?.isLetter ?? false, filePath.first?.isLowercase ?? false,
          filePath.count > 1, filePath[filePath.index(filePath.startIndex, offsetBy: 1)] == ":"
        {
          return filePath.first!.uppercased() + filePath.dropFirst()
        }
        #endif
        return filePath
      }
    } else {
      return storage.absoluteString
    }
  }

  /// Returns the URI as a string.
  public var stringValue: String {
    return storage.absoluteString
  }

  /// Construct a DocumentURI from the given URI string, automatically parsing
  ///  it either as a URL or an opaque URI.
  public init(string: String) throws {
    guard let url = URL(string: string) else {
      throw FailedToConstructDocumentURIFromStringError(string: string)
    }
    self.init(url)
  }

  public init(_ url: URL) {
    self.storage = url
    assert(self.storage.scheme != nil, "Received invalid URI without a scheme '\(self.storage.absoluteString)'")
  }

  public init(filePath: String, isDirectory: Bool) {
    self.init(URL(fileURLWithPath: filePath, isDirectory: isDirectory))
  }

  public init(from decoder: Decoder) throws {
    try self.init(string: decoder.singleValueContainer().decode(String.self))
  }

  /// Equality check to handle escape sequences in file URLs.
  public static func == (lhs: DocumentURI, rhs: DocumentURI) -> Bool {
    return lhs.storage.scheme == rhs.storage.scheme && lhs.pseudoPath == rhs.pseudoPath
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(self.storage.scheme)
    hasher.combine(self.pseudoPath)
  }

  public func encode(to encoder: Encoder) throws {
    try storage.absoluteString.encode(to: encoder)
  }
}
