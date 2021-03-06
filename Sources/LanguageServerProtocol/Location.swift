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

import SKSupport

/// Range within a particular document.
///
/// For a location where the document is implied, use `Position` or `Range<Position>`.
public struct Location: ResponseType, Hashable {

  public var url: URL

  @CustomCodable<PositionRange>
  public var range: Range<Position>

  public init(url: URL, range: Range<Position>) {
    self.url = url
    self.range = range
  }
}

// Encode using the key "uri" to match LSP.
extension Location: Codable {
  private enum CodingKeys: String, CodingKey {
    case url = "uri"
    case range
  }
}
