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

import LSPLogging
import LanguageServerProtocol
import SKSupport

import enum PackageLoading.Platform
import struct TSCBasic.AbsolutePath
import protocol TSCBasic.FileSystem
import var TSCBasic.localFileSystem

/// A Toolchain is a collection of related compilers and libraries meant to be used together to
/// build and edit source code.
///
/// This can be an explicit toolchain, such as an xctoolchain directory on Darwin, or an implicit
/// toolchain, such as the contents from `/usr/bin`.
public final class Toolchain: Sendable {

  /// The unique toolchain identifier.
  ///
  /// For an xctoolchain, this is a reverse domain name e.g. "com.apple.dt.toolchain.XcodeDefault".
  /// Otherwise, it is typically derived from `path`.
  public let identifier: String

  /// The human-readable name for the toolchain.
  public let displayName: String

  /// The path to this toolchain, if applicable.
  ///
  /// For example, this may be the path to an ".xctoolchain" directory.
  public let path: AbsolutePath?

  // MARK: Tool Paths

  /// The path to the Clang compiler if available.
  public let clang: AbsolutePath?

  /// The path to the Swift driver if available.
  public let swift: AbsolutePath?

  /// The path to the Swift compiler if available.
  public let swiftc: AbsolutePath?

  /// The path to the swift-format executable, if available.
  public let swiftFormat: AbsolutePath?

  /// The path to the clangd language server if available.
  public let clangd: AbsolutePath?

  /// The path to the Swift language server if available.
  public let sourcekitd: AbsolutePath?

  /// The path to the indexstore library if available.
  public let libIndexStore: AbsolutePath?

  public init(
    identifier: String,
    displayName: String,
    path: AbsolutePath? = nil,
    clang: AbsolutePath? = nil,
    swift: AbsolutePath? = nil,
    swiftc: AbsolutePath? = nil,
    swiftFormat: AbsolutePath? = nil,
    clangd: AbsolutePath? = nil,
    sourcekitd: AbsolutePath? = nil,
    libIndexStore: AbsolutePath? = nil
  ) {
    self.identifier = identifier
    self.displayName = displayName
    self.path = path
    self.clang = clang
    self.swift = swift
    self.swiftc = swiftc
    self.swiftFormat = swiftFormat
    self.clangd = clangd
    self.sourcekitd = sourcekitd
    self.libIndexStore = libIndexStore
  }

  /// Returns `true` if this toolchain has strictly more tools than `other`.
  ///
  /// ### Examples
  /// - A toolchain that contains both `swiftc` and  `clangd` is a superset of one that only contains `swiftc`.
  /// - A toolchain that contains only `swiftc`, `clangd` is not a superset of a toolchain that contains `swiftc` and
  ///   `libIndexStore`. These toolchains are not comparable.
  /// - Two toolchains that both contain `swiftc` and `clangd` are supersets of each other.
  func isSuperset(of other: Toolchain) -> Bool {
    func isSuperset(for tool: KeyPath<Toolchain, AbsolutePath?>) -> Bool {
      if self[keyPath: tool] == nil && other[keyPath: tool] != nil {
        // This toolchain doesn't contain the tool but the other toolchain does. It is not a superset.
        return false
      } else {
        return true
      }
    }
    return isSuperset(for: \.clang) && isSuperset(for: \.swift) && isSuperset(for: \.swiftc)
      && isSuperset(for: \.clangd) && isSuperset(for: \.sourcekitd) && isSuperset(for: \.libIndexStore)
  }

  /// Same as `isSuperset` but returns `false` if both toolchains have the same set of tools.
  func isProperSuperset(of other: Toolchain) -> Bool {
    return self.isSuperset(of: other) && !other.isSuperset(of: self)
  }
}

extension Toolchain {
  /// Create a toolchain for the given path, if it contains at least one tool, otherwise return nil.
  ///
  /// This initializer looks for a toolchain using the following basic layout:
  ///
  /// ```
  /// bin/clang
  ///    /clangd
  ///    /swiftc
  /// lib/sourcekitd.framework/sourcekitd
  ///    /libsourcekitdInProc.{so,dylib}
  ///    /libIndexStore.{so,dylib}
  /// ```
  ///
  /// The above directory layout can found relative to `path` in the following ways:
  /// * `path` (=bin), `path/../lib`
  /// * `path/bin`, `path/lib`
  /// * `path/usr/bin`, `path/usr/lib`
  ///
  /// If `path` contains an ".xctoolchain", we try to read an Info.plist file to provide the
  /// toolchain identifier, etc.  Otherwise this information is derived from the path.
  convenience public init?(_ path: AbsolutePath, _ fileSystem: FileSystem = localFileSystem) {
    // Properties that need to be initialized
    let identifier: String
    let displayName: String
    let toolchainPath: AbsolutePath?
    var clang: AbsolutePath? = nil
    var clangd: AbsolutePath? = nil
    var swift: AbsolutePath? = nil
    var swiftc: AbsolutePath? = nil
    var swiftFormat: AbsolutePath? = nil
    var sourcekitd: AbsolutePath? = nil
    var libIndexStore: AbsolutePath? = nil

    if let (infoPlist, xctoolchainPath) = containingXCToolchain(path, fileSystem) {
      identifier = infoPlist.identifier
      displayName = infoPlist.displayName ?? xctoolchainPath.basenameWithoutExt
      toolchainPath = xctoolchainPath
    } else {
      identifier = path.pathString
      displayName = path.basename
      toolchainPath = path
    }

    // Find tools in the toolchain

    var foundAny = false
    let searchPaths = [path, path.appending(components: "bin"), path.appending(components: "usr", "bin")]
    for binPath in searchPaths {
      let libPath = binPath.parentDirectory.appending(component: "lib")

      guard fileSystem.isDirectory(binPath) || fileSystem.isDirectory(libPath) else { continue }

      let execExt = Platform.currentConcurrencySafe?.executableExtension ?? ""

      let clangPath = binPath.appending(component: "clang\(execExt)")
      if fileSystem.isExecutableFile(clangPath) {
        clang = clangPath
        foundAny = true
      }
      let clangdPath = binPath.appending(component: "clangd\(execExt)")
      if fileSystem.isExecutableFile(clangdPath) {
        clangd = clangdPath
        foundAny = true
      }

      let swiftPath = binPath.appending(component: "swift\(execExt)")
      if fileSystem.isExecutableFile(swiftPath) {
        swift = swiftPath
        foundAny = true
      }

      let swiftcPath = binPath.appending(component: "swiftc\(execExt)")
      if fileSystem.isExecutableFile(swiftcPath) {
        swiftc = swiftcPath
        foundAny = true
      }

      let swiftFormatPath = binPath.appending(component: "swift-format\(execExt)")
      if fileSystem.isExecutableFile(swiftFormatPath) {
        swiftFormat = swiftFormatPath
        foundAny = true
      }

      // If 'currentPlatform' is nil it's most likely an unknown linux flavor.
      let dylibExt: String
      if let dynamicLibraryExtension = Platform.currentConcurrencySafe?.dynamicLibraryExtension {
        dylibExt = dynamicLibraryExtension
      } else {
        logger.fault("Could not determine host OS. Falling back to using '.so' as dynamic library extension")
        dylibExt = ".so"
      }

      let sourcekitdPath = libPath.appending(components: "sourcekitd.framework", "sourcekitd")
      if fileSystem.isFile(sourcekitdPath) {
        sourcekitd = sourcekitdPath
        foundAny = true
      } else {
        #if os(Windows)
        let sourcekitdPath = binPath.appending(component: "sourcekitdInProc\(dylibExt)")
        #else
        let sourcekitdPath = libPath.appending(component: "libsourcekitdInProc\(dylibExt)")
        #endif
        if fileSystem.isFile(sourcekitdPath) {
          sourcekitd = sourcekitdPath
          foundAny = true
        }
      }

      #if os(Windows)
      let libIndexStorePath = binPath.appending(components: "libIndexStore\(dylibExt)")
      #else
      let libIndexStorePath = libPath.appending(components: "libIndexStore\(dylibExt)")
      #endif
      if fileSystem.isFile(libIndexStorePath) {
        libIndexStore = libIndexStorePath
        foundAny = true
      }

      if foundAny {
        break
      }
    }
    if !foundAny {
      return nil
    }

    self.init(
      identifier: identifier,
      displayName: displayName,
      path: toolchainPath,
      clang: clang,
      swift: swift,
      swiftc: swiftc,
      swiftFormat: swiftFormat,
      clangd: clangd,
      sourcekitd: sourcekitd,
      libIndexStore: libIndexStore
    )
  }
}

/// Find a containing xctoolchain with plist, if available.
func containingXCToolchain(
  _ path: AbsolutePath,
  _ fileSystem: FileSystem
) -> (XCToolchainPlist, AbsolutePath)? {
  var path = path
  while !path.isRoot {
    if path.extension == "xctoolchain" {
      if let infoPlist = orLog("", { try XCToolchainPlist(fromDirectory: path, fileSystem) }) {
        return (infoPlist, path)
      }
      return nil
    }
    path = path.parentDirectory
  }
  return nil
}
