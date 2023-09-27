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

import LanguageServerProtocol
import BuildServerProtocol
import LSPTestSupport
import SKCore
import TSCBasic
import XCTest

final class BuildSystemManagerTests: XCTestCase {

  func testMainFiles() async {
    let a = DocumentURI(string: "bsm:a")
    let b = DocumentURI(string: "bsm:b")
    let c = DocumentURI(string: "bsm:c")
    let d = DocumentURI(string: "bsm:d")

    let mainFiles = ManualMainFilesProvider()
    mainFiles.mainFiles = [
      a: Set([c]),
      b: Set([c, d]),
      c: Set([c]),
      d: Set([d]),
    ]

    let bsm = await BuildSystemManager(
      buildSystem: FallbackBuildSystem(buildSetup: .default),
      fallbackBuildSystem: nil,
      mainFilesProvider: mainFiles)
    defer { withExtendedLifetime(bsm) {} } // Keep BSM alive for callbacks.

    await assertEqual(bsm._cachedMainFile(for: a), nil)
    await assertEqual(bsm._cachedMainFile(for: b), nil)
    await assertEqual(bsm._cachedMainFile(for: c), nil)
    await assertEqual(bsm._cachedMainFile(for: d), nil)

    await bsm.registerForChangeNotifications(for: a, language: .c)
    await bsm.registerForChangeNotifications(for: b, language: .c)
    await bsm.registerForChangeNotifications(for: c, language: .c)
    await bsm.registerForChangeNotifications(for: d, language: .c)
    await assertEqual(bsm._cachedMainFile(for: a), c)
    let bMain = await bsm._cachedMainFile(for: b)
    XCTAssert(Set([c, d]).contains(bMain))
    await assertEqual(bsm._cachedMainFile(for: c), c)
    await assertEqual(bsm._cachedMainFile(for: d), d)

    mainFiles.mainFiles = [
      a: Set([a]),
      b: Set([c, d, a]),
      c: Set([c]),
      d: Set([d]),
    ]

    await assertEqual(bsm._cachedMainFile(for: a), c)
    await assertEqual(bsm._cachedMainFile(for: b), bMain)
    await assertEqual(bsm._cachedMainFile(for: c), c)
    await assertEqual(bsm._cachedMainFile(for: d), d)

    await bsm.mainFilesChangedImpl()

    await assertEqual(bsm._cachedMainFile(for: a), a)
    await assertEqual(bsm._cachedMainFile(for: b), bMain) // never changes to a
    await assertEqual(bsm._cachedMainFile(for: c), c)
    await assertEqual(bsm._cachedMainFile(for: d), d)

    await bsm.unregisterForChangeNotifications(for: a)
    await assertEqual(bsm._cachedMainFile(for: a), nil)
    await assertEqual(bsm._cachedMainFile(for: b), bMain) // never changes to a
    await assertEqual(bsm._cachedMainFile(for: c), c)
    await assertEqual(bsm._cachedMainFile(for: d), d)

    await bsm.unregisterForChangeNotifications(for: b)
    await bsm.mainFilesChangedImpl()
    await bsm.unregisterForChangeNotifications(for: c)
    await bsm.unregisterForChangeNotifications(for: d)
    await assertEqual(bsm._cachedMainFile(for: a), nil)
    await assertEqual(bsm._cachedMainFile(for: b), nil)
    await assertEqual(bsm._cachedMainFile(for: c), nil)
    await assertEqual(bsm._cachedMainFile(for: d), nil)
  }

  func testSettingsMainFile() async throws {
    let a = DocumentURI(string: "bsm:a.swift")
    let mainFiles = ManualMainFilesProvider()
    mainFiles.mainFiles = [a: Set([a])]
    let bs = ManualBuildSystem()
    let bsm = await BuildSystemManager(
      buildSystem: bs,
      fallbackBuildSystem: nil,
      mainFilesProvider: mainFiles)
    defer { withExtendedLifetime(bsm) {} } // Keep BSM alive for callbacks.
    let del = await BSMDelegate(bsm)

    bs.map[a] = FileBuildSettings(compilerArguments: ["x"])
    let initial = expectation(description: "initial settings")
    await del.setExpected([(a, .swift, bs.map[a]!, initial, #file, #line)])
    await bsm.registerForChangeNotifications(for: a, language: .swift)
    try await fulfillmentOfOrThrow([initial])

    bs.map[a] = nil
    let changed = expectation(description: "changed settings")
    await del.setExpected([(a, .swift, nil, changed, #file, #line)])
    bsm.fileBuildSettingsChanged([a])
    try await fulfillmentOfOrThrow([changed])
  }

  func testSettingsMainFileInitialNil() async throws {
    let a = DocumentURI(string: "bsm:a.swift")
    let mainFiles = ManualMainFilesProvider()
    mainFiles.mainFiles = [a: Set([a])]
    let bs = ManualBuildSystem()
    let bsm = await BuildSystemManager(
      buildSystem: bs,
      fallbackBuildSystem: nil,
      mainFilesProvider: mainFiles)
    defer { withExtendedLifetime(bsm) {} } // Keep BSM alive for callbacks.
    let del = await BSMDelegate(bsm)
    let initial = expectation(description: "initial settings")
    await del.setExpected([(a, .swift, nil, initial, #file, #line)])
    await bsm.registerForChangeNotifications(for: a, language: .swift)
    try await fulfillmentOfOrThrow([initial])

    bs.map[a] = FileBuildSettings(compilerArguments: ["x"])
    let changed = expectation(description: "changed settings")
    await del.setExpected([(a, .swift, bs.map[a]!, changed, #file, #line)])
    bsm.fileBuildSettingsChanged([a])
    try await fulfillmentOfOrThrow([changed])
  }

  func testSettingsMainFileWithFallback() async throws {
    let a = DocumentURI(string: "bsm:a.swift")
    let mainFiles = ManualMainFilesProvider()
    mainFiles.mainFiles = [a: Set([a])]
    let bs = ManualBuildSystem()
    let fallback = FallbackBuildSystem(buildSetup: .default)
    let bsm = await BuildSystemManager(
      buildSystem: bs,
      fallbackBuildSystem: fallback,
      mainFilesProvider: mainFiles)
    defer { withExtendedLifetime(bsm) {} } // Keep BSM alive for callbacks.
    let del = await BSMDelegate(bsm)
    let fallbackSettings = fallback.buildSettings(for: a, language: .swift)
    let initial = expectation(description: "initial fallback settings")
    await del.setExpected([(a, .swift, fallbackSettings, initial, #file, #line)])
    await bsm.registerForChangeNotifications(for: a, language: .swift)
    try await fulfillmentOfOrThrow([initial])

    bs.map[a] = FileBuildSettings(compilerArguments: ["non-fallback", "args"])
    let changed = expectation(description: "changed settings")
    await del.setExpected([(a, .swift, bs.map[a]!, changed, #file, #line)])
    bsm.fileBuildSettingsChanged([a])
    try await fulfillmentOfOrThrow([changed])

    bs.map[a] = nil
    let revert = expectation(description: "revert to fallback settings")
    await del.setExpected([(a, .swift, fallbackSettings, revert, #file, #line)])
    bsm.fileBuildSettingsChanged([a])
    try await fulfillmentOfOrThrow([revert])
  }

  func testSettingsMainFileInitialIntersect() async throws {
    let a = DocumentURI(string: "bsm:a.swift")
    let b = DocumentURI(string: "bsm:b.swift")
    let mainFiles = ManualMainFilesProvider()
    mainFiles.mainFiles = [a: Set([a]), b: Set([b])]
    let bs = ManualBuildSystem()
    let bsm = await BuildSystemManager(
      buildSystem: bs,
      fallbackBuildSystem: nil,
      mainFilesProvider: mainFiles)
    defer { withExtendedLifetime(bsm) {} } // Keep BSM alive for callbacks.
    let del = await BSMDelegate(bsm)

    bs.map[a] = FileBuildSettings(compilerArguments: ["x"])
    bs.map[b] = FileBuildSettings(compilerArguments: ["y"])
    let initial = expectation(description: "initial settings")
    await del.setExpected([(a, .swift, bs.map[a]!, initial, #file, #line)])
    await bsm.registerForChangeNotifications(for: a, language: .swift)
    try await fulfillmentOfOrThrow([initial])
    let initialB = expectation(description: "initial settings")
    await del.setExpected([(b, .swift, bs.map[b]!, initialB, #file, #line)])
    await bsm.registerForChangeNotifications(for: b, language: .swift)
    try await fulfillmentOfOrThrow([initialB])

    bs.map[a] = FileBuildSettings(compilerArguments: ["xx"])
    bs.map[b] = FileBuildSettings(compilerArguments: ["yy"])
    let changed = expectation(description: "changed settings")
    await del.setExpected([(a, .swift, bs.map[a]!, changed, #file, #line)])
    bsm.fileBuildSettingsChanged([a])
    try await fulfillmentOfOrThrow([changed])

    // Test multiple changes.
    bs.map[a] = FileBuildSettings(compilerArguments: ["xxx"])
    bs.map[b] = FileBuildSettings(compilerArguments: ["yyy"])
    let changedBothA = expectation(description: "changed setting a")
    let changedBothB = expectation(description: "changed setting b")
    await del.setExpected([
      (a, .swift, bs.map[a]!, changedBothA, #file, #line),
      (b, .swift, bs.map[b]!, changedBothB, #file, #line),
    ])
    bsm.fileBuildSettingsChanged([a, b])
    try await fulfillmentOfOrThrow([changedBothA, changedBothB])
  }

  func testSettingsMainFileUnchanged() async throws {
    let a = DocumentURI(string: "bsm:a.swift")
    let b = DocumentURI(string: "bsm:b.swift")
    let mainFiles = ManualMainFilesProvider()
    mainFiles.mainFiles = [a: Set([a]), b: Set([b])]
    let bs = ManualBuildSystem()
    let bsm = await BuildSystemManager(
      buildSystem: bs,
      fallbackBuildSystem: nil,
      mainFilesProvider: mainFiles)
    defer { withExtendedLifetime(bsm) {} } // Keep BSM alive for callbacks.
    let del = await BSMDelegate(bsm)

    bs.map[a] = FileBuildSettings(compilerArguments: ["a"])
    bs.map[b] = FileBuildSettings(compilerArguments: ["b"])

    let initialA = expectation(description: "initial settings a")
    await del.setExpected([(a, .swift, bs.map[a]!, initialA, #file, #line)])
    await bsm.registerForChangeNotifications(for: a, language: .swift)
    try await fulfillmentOfOrThrow([initialA])

    let initialB = expectation(description: "initial settings b")
    await del.setExpected([(b, .swift, bs.map[b]!, initialB, #file, #line)])
    await bsm.registerForChangeNotifications(for: b, language: .swift)
    try await fulfillmentOfOrThrow([initialB])

    bs.map[a] = nil
    bs.map[b] = nil
    let changed = expectation(description: "changed settings")
    await del.setExpected([(b, .swift, nil, changed, #file, #line)])
    bsm.fileBuildSettingsChanged([b])
    try await fulfillmentOfOrThrow([changed])
  }

  func testSettingsHeaderChangeMainFile() async throws {
    let h = DocumentURI(string: "bsm:header.h")
    let cpp1 = DocumentURI(string: "bsm:main.cpp")
    let cpp2 = DocumentURI(string: "bsm:other.cpp")
    let mainFiles = ManualMainFilesProvider()
    mainFiles.mainFiles = [
      h: Set([cpp1]),
      cpp1: Set([cpp1]),
      cpp2: Set([cpp2]),
    ]

    let bs = ManualBuildSystem()
    let bsm = await BuildSystemManager(
      buildSystem: bs,
      fallbackBuildSystem: nil,
      mainFilesProvider: mainFiles)
    defer { withExtendedLifetime(bsm) {} } // Keep BSM alive for callbacks.
    let del = await BSMDelegate(bsm)

    bs.map[cpp1] = FileBuildSettings(compilerArguments: ["C++ 1"])
    bs.map[cpp2] = FileBuildSettings(compilerArguments: ["C++ 2"])

    let initial = expectation(description: "initial settings via cpp1")
    await del.setExpected([(h, .c, bs.map[cpp1]!, initial, #file, #line)])
    await bsm.registerForChangeNotifications(for: h, language: .c)
    try await fulfillmentOfOrThrow([initial])

    mainFiles.mainFiles[h] = Set([cpp2])

    let changed = expectation(description: "changed settings to cpp2")
    await del.setExpected([(h, .c, bs.map[cpp2]!, changed, #file, #line)])
    await bsm.mainFilesChangedImpl()
    try await fulfillmentOfOrThrow([changed])

    let changed2 = expectation(description: "still cpp2, no update")
    changed2.isInverted = true
    await del.setExpected([(h, .c, nil, changed2, #file, #line)])
    await bsm.mainFilesChangedImpl()
    try await fulfillmentOfOrThrow([changed2], timeout: 1)

    mainFiles.mainFiles[h] = Set([cpp1, cpp2])

    let changed3 = expectation(description: "added main file, no update")
    changed3.isInverted = true
    await del.setExpected([(h, .c, nil, changed3, #file, #line)])
    await bsm.mainFilesChangedImpl()
    try await fulfillmentOfOrThrow([changed3], timeout: 1)

    mainFiles.mainFiles[h] = Set([])

    let changed4 = expectation(description: "changed settings to []")
    await del.setExpected([(h, .c, nil, changed4, #file, #line)])
    await bsm.mainFilesChangedImpl()
    try await fulfillmentOfOrThrow([changed4])
  }

  func testSettingsOneMainTwoHeader() async throws {
    let h1 = DocumentURI(string: "bsm:header1.h")
    let h2 = DocumentURI(string: "bsm:header2.h")
    let cpp = DocumentURI(string: "bsm:main.cpp")
    let mainFiles = ManualMainFilesProvider()
    mainFiles.mainFiles = [
      h1: Set([cpp]),
      h2: Set([cpp]),
    ]

    let bs = ManualBuildSystem()
    let bsm = await BuildSystemManager(
      buildSystem: bs,
      fallbackBuildSystem: nil,
      mainFilesProvider: mainFiles)
    defer { withExtendedLifetime(bsm) {} } // Keep BSM alive for callbacks.
    let del = await BSMDelegate(bsm)

    let cppArg = "C++ Main File"
    bs.map[cpp] = FileBuildSettings(compilerArguments: [cppArg, cpp.pseudoPath])

    let initial1 = expectation(description: "initial settings h1 via cpp")
    let initial2 = expectation(description: "initial settings h2 via cpp")
    let expectedArgsH1 = FileBuildSettings(compilerArguments: ["-xc++", cppArg, h1.pseudoPath])
    let expectedArgsH2 = FileBuildSettings(compilerArguments: ["-xc++", cppArg, h2.pseudoPath])
    await del.setExpected([
      (h1, .c, expectedArgsH1, initial1, #file, #line),
      (h2, .c, expectedArgsH2, initial2, #file, #line),
    ])

    await bsm.registerForChangeNotifications(for: h1, language: .c)
    await bsm.registerForChangeNotifications(for: h2, language: .c)

    // Since the registration is async, it's possible that they get grouped together
    // since they are backed by the same underlying cpp file.
    try await fulfillmentOfOrThrow([initial1, initial2])

    let newCppArg = "New C++ Main File"
    bs.map[cpp] = FileBuildSettings(compilerArguments: [newCppArg, cpp.pseudoPath])
    let changed1 = expectation(description: "initial settings h1 via cpp")
    let changed2 = expectation(description: "initial settings h2 via cpp")
    let newArgsH1 = FileBuildSettings(compilerArguments: ["-xc++", newCppArg, h1.pseudoPath])
    let newArgsH2 = FileBuildSettings(compilerArguments: ["-xc++", newCppArg, h2.pseudoPath])
    await del.setExpected([
      (h1, .c, newArgsH1, changed1, #file, #line),
      (h2, .c, newArgsH2, changed2, #file, #line),
    ])
    bsm.fileBuildSettingsChanged([cpp])

    try await fulfillmentOfOrThrow([changed1, changed2])
  }

  func testSettingsChangedAfterUnregister() async throws {
    let a = DocumentURI(string: "bsm:a.swift")
    let b = DocumentURI(string: "bsm:b.swift")
    let c = DocumentURI(string: "bsm:c.swift")
    let mainFiles = ManualMainFilesProvider()
    mainFiles.mainFiles = [a: Set([a]), b: Set([b]), c: Set([c])]
    let bs = ManualBuildSystem()
    let bsm = await BuildSystemManager(
      buildSystem: bs,
      fallbackBuildSystem: nil,
      mainFilesProvider: mainFiles)
    defer { withExtendedLifetime(bsm) {} } // Keep BSM alive for callbacks.
    let del = await BSMDelegate(bsm)

    bs.map[a] = FileBuildSettings(compilerArguments: ["a"])
    bs.map[b] = FileBuildSettings(compilerArguments: ["b"])
    bs.map[c] = FileBuildSettings(compilerArguments: ["c"])

    let initialA = expectation(description: "initial settings a")
    let initialB = expectation(description: "initial settings b")
    let initialC = expectation(description: "initial settings c")
    await del.setExpected([
      (a, .swift, bs.map[a]!, initialA, #file, #line),
      (b, .swift, bs.map[b]!, initialB, #file, #line),
      (c, .swift, bs.map[c]!, initialC, #file, #line),
    ])
    await bsm.registerForChangeNotifications(for: a, language: .swift)
    await bsm.registerForChangeNotifications(for: b, language: .swift)
    await bsm.registerForChangeNotifications(for: c, language: .swift)
    try await fulfillmentOfOrThrow([initialA, initialB, initialC])

    bs.map[a] = FileBuildSettings(compilerArguments: ["new-a"])
    bs.map[b] = FileBuildSettings(compilerArguments: ["new-b"])
    bs.map[c] = FileBuildSettings(compilerArguments: ["new-c"])

    let changedB = expectation(description: "changed settings b")
    await del.setExpected([
      (b, .swift, bs.map[b]!, changedB, #file, #line),
    ])

    await bsm.unregisterForChangeNotifications(for: a)
    await bsm.unregisterForChangeNotifications(for: c)
    // At this point only b is registered, but that can race with notifications,
    // so ensure nothing bad happens and we still get the notification for b.
    bsm.fileBuildSettingsChanged([a, b, c])

    try await fulfillmentOfOrThrow([changedB])
  }

  func testDependenciesUpdated() async throws {
    let a = DocumentURI(string: "bsm:a.swift")
    let mainFiles = ManualMainFilesProvider()
    mainFiles.mainFiles = [a: Set([a])]

    class DepUpdateDuringRegistrationBS: ManualBuildSystem {
        override func registerForChangeNotifications(for uri: DocumentURI, language: Language) async {
          await delegate?.filesDependenciesUpdated([uri])
          await super.registerForChangeNotifications(for: uri, language: language)
        }
    }

    let bs = DepUpdateDuringRegistrationBS()
    let bsm = await BuildSystemManager(
      buildSystem: bs,
      fallbackBuildSystem: nil,
      mainFilesProvider: mainFiles)
    defer { withExtendedLifetime(bsm) {} } // Keep BSM alive for callbacks.
    let del = await BSMDelegate(bsm)

    bs.map[a] = FileBuildSettings(compilerArguments: ["x"])
    let initial = expectation(description: "initial settings")
    await del.setExpected([(a, .swift, bs.map[a]!, initial, #file, #line)])

    let depUpdate1 = expectation(description: "dependencies update during registration")
    await del.setExpectedDependenciesUpdate([(a, depUpdate1, #file, #line)])

    await bsm.registerForChangeNotifications(for: a, language: .swift)
    try await fulfillmentOfOrThrow([initial, depUpdate1])

    let depUpdate2 = expectation(description: "dependencies update 2")
    await del.setExpectedDependenciesUpdate([(a, depUpdate2, #file, #line)])

    bsm.filesDependenciesUpdated([a])
    try await fulfillmentOfOrThrow([depUpdate2])
  }
}

// MARK: Helper Classes for Testing

/// A simple `MainFilesProvider` that wraps a dictionary, for testing.
private final class ManualMainFilesProvider: MainFilesProvider {
  let lock: DispatchQueue = DispatchQueue(label: "\(ManualMainFilesProvider.self)-lock")
  private var _mainFiles: [DocumentURI: Set<DocumentURI>] = [:]
  var mainFiles: [DocumentURI: Set<DocumentURI>] {
    get { lock.sync { _mainFiles } }
    set { lock.sync { _mainFiles = newValue } }
  }

  func mainFilesContainingFile(_ file: DocumentURI) -> Set<DocumentURI> {
    if let result = mainFiles[file] {
      return result
    }
    return Set()
  }
}

/// A simple `BuildSystem` that wraps a dictionary, for testing.
class ManualBuildSystem: BuildSystem {
  var map: [DocumentURI: FileBuildSettings] = [:]

  var delegate: BuildSystemDelegate? = nil

  func setDelegate(_ delegate: SKCore.BuildSystemDelegate?) async {
    self.delegate = delegate
  }

  func buildSettings(for uri: DocumentURI, language: Language) -> FileBuildSettings? {
    return map[uri]
  }

  func registerForChangeNotifications(for uri: DocumentURI, language: Language) async {
    await self.delegate?.fileBuildSettingsChanged([uri])
  }

  func unregisterForChangeNotifications(for: DocumentURI) {
  }

  var indexStorePath: AbsolutePath? { nil }
  var indexDatabasePath: AbsolutePath? { nil }
  var indexPrefixMappings: [PathPrefixMapping] { return [] }

  func filesDidChange(_ events: [FileEvent]) {}

  public func fileHandlingCapability(for uri: DocumentURI) -> FileHandlingCapability {
    if map[uri] != nil {
      return .handled
    } else {
      return .unhandled
    }
  }
}

/// A `BuildSystemDelegate` setup for testing.
private actor BSMDelegate: BuildSystemDelegate {
  fileprivate typealias ExpectedBuildSettingChangedCall = (uri: DocumentURI, language: Language, settings: FileBuildSettings?, expectation: XCTestExpectation, file: StaticString, line: UInt)
  fileprivate typealias ExpectedDependenciesUpdatedCall = (uri: DocumentURI, expectation: XCTestExpectation, file: StaticString, line: UInt)

  let queue: DispatchQueue = DispatchQueue(label: "\(BSMDelegate.self)")
  unowned let bsm: BuildSystemManager
  var expected: [ExpectedBuildSettingChangedCall] = []

  /// - Note: Needed to set `expected` outside of the actor's isolation context.
  func setExpected(_ expected: [ExpectedBuildSettingChangedCall]) {
    self.expected = expected
  }

  var expectedDependenciesUpdate: [(uri: DocumentURI, expectation: XCTestExpectation, file: StaticString, line: UInt)] = []

  /// - Note: Needed to set `expected` outside of the actor's isolation context.
  func setExpectedDependenciesUpdate(_ expectedDependenciesUpdated: [ExpectedDependenciesUpdatedCall]) {
    self.expectedDependenciesUpdate = expectedDependenciesUpdated
  }

  init(_ bsm: BuildSystemManager) async {
    self.bsm = bsm
    await bsm.setDelegate(self)
  }

  func fileBuildSettingsChanged(_ changedFiles: Set<DocumentURI>) async {
    for uri in changedFiles {
      guard let expected = expected.first(where: { $0.uri == uri }) else {
        XCTFail("unexpected settings change for \(uri)")
        continue
      }

      XCTAssertEqual(uri, expected.uri, file: expected.file, line: expected.line)
      let settings = await bsm.buildSettings(ofMainFileFor: uri, language: expected.language)?.buildSettings
      XCTAssertEqual(settings, expected.settings, file: expected.file, line: expected.line)
      expected.expectation.fulfill()
    }
  }

  func buildTargetsChanged(_ changes: [BuildTargetEvent]) {}
  func filesDependenciesUpdated(_ changedFiles: Set<DocumentURI>) {
    for uri in changedFiles {
      guard let expected = expectedDependenciesUpdate.first(where: { $0.uri == uri }) else {
        XCTFail("unexpected filesDependenciesUpdated for \(uri)")
        continue
      }

      XCTAssertEqual(uri, expected.uri, file: expected.file, line: expected.line)
      expected.expectation.fulfill()
    }
  }
  
  func fileHandlingCapabilityChanged() {}
}
