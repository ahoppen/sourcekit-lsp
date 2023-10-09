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

import LSPLogging

public enum EditorPlaceholder: Hashable {
  case basic(String)
  case typed(displayName: String, type: String, typeForExpansion: String)

  static let placeholderPrefix: String = "<#"
  static let placeholderSuffix: String = "#>"

  public init?(_ skPlaceholder: String) {
    guard skPlaceholder.hasPrefix(EditorPlaceholder.placeholderPrefix) &&
          skPlaceholder.hasSuffix(EditorPlaceholder.placeholderSuffix) else {
      return nil
    }
    var skPlaceholder = skPlaceholder.dropFirst(2).dropLast(2)
    guard skPlaceholder.hasPrefix("T##") else {
      self = .basic(String(skPlaceholder))
      return
    }
    skPlaceholder = skPlaceholder.dropFirst(3)
    guard let end = skPlaceholder.range(of: "##") else {
      let type = String(skPlaceholder)
      self = .typed(displayName: type, type: type, typeForExpansion: type)
      return
    }
    let displayName = String(skPlaceholder[skPlaceholder.startIndex..<end.lowerBound])
    skPlaceholder = skPlaceholder[end.upperBound...]
    if let end = skPlaceholder.range(of: "##") {
      let type = String(skPlaceholder[skPlaceholder.startIndex..<end.lowerBound])
      let typeForExpansion = String(skPlaceholder[end.upperBound...])
      self = .typed(displayName: displayName, type: type, typeForExpansion: typeForExpansion)
    } else {
      let type = String(skPlaceholder)
      self = .typed(displayName: displayName, type: type, typeForExpansion: type)
    }
  }

  public var displayName: String {
    switch self {
    case .basic(let displayName), .typed(let displayName, _, _):
      return displayName
    }
  }
}

func rewriteSourceKitPlaceholders(inString string: String, clientSupportsSnippets: Bool) -> String {
  var result = string
  var index = 1
  while let start = result.range(of: EditorPlaceholder.placeholderPrefix) {
    guard let end = result[start.upperBound...].range(of: EditorPlaceholder.placeholderSuffix) else {
      logger.error("invalid placeholder in \(string)")
      return string
    }
    let rawPlaceholder = String(result[start.lowerBound..<end.upperBound])
    guard let displayName = EditorPlaceholder(rawPlaceholder)?.displayName else {
      logger.error("failed to decode placeholder \(rawPlaceholder) in \(string)")
      return string
    }
    let placeholder = clientSupportsSnippets ? "${\(index):\(displayName)}" : ""
    result.replaceSubrange(start.lowerBound..<end.upperBound, with: placeholder)
    index += 1
  }
  return result
}
