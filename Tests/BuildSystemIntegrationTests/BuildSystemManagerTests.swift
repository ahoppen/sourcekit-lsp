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

import BuildServerProtocol
@_spi(Testing) import BuildSystemIntegration
import BuildSystemIntegrationProtocol
import LanguageServerProtocol
import SKOptions
import SKTestSupport
import TSCBasic
import ToolchainRegistry
import XCTest

fileprivate extension BuildSystemManager {
  func fileBuildSettingsChanged(_ changedFiles: Set<DocumentURI>) async {
    handle(DidChangeBuildSettingsNotification(uris: Array(changedFiles)))
  }
}

final class BuildSystemManagerTests: XCTestCase {

  func testMainFiles() async throws {
    let a = try DocumentURI(string: "bsm:a")
    let b = try DocumentURI(string: "bsm:b")
    let c = try DocumentURI(string: "bsm:c")
    let d = try DocumentURI(string: "bsm:d")

    let mainFiles = ManualMainFilesProvider(
      [
        a: [c],
        b: [c, d],
        c: [c],
        d: [d],
      ]
    )

    let bsm = await BuildSystemManager(
      buildSystemKind: nil,
      toolchainRegistry: ToolchainRegistry.forTesting,
      options: SourceKitLSPOptions(),
      swiftpmTestHooks: SwiftPMTestHooks(),
      delegate: nil,
      reloadPackageStatusCallback: { _ in }
    )
    await bsm.setMainFilesProvider(mainFiles)
    defer { withExtendedLifetime(bsm) {} }  // Keep BSM alive for callbacks.

    await assertEqual(bsm.cachedMainFile(for: a), nil)
    await assertEqual(bsm.cachedMainFile(for: b), nil)
    await assertEqual(bsm.cachedMainFile(for: c), nil)
    await assertEqual(bsm.cachedMainFile(for: d), nil)

    await bsm.registerForChangeNotifications(for: a, language: .c)
    await bsm.registerForChangeNotifications(for: b, language: .c)
    await bsm.registerForChangeNotifications(for: c, language: .c)
    await bsm.registerForChangeNotifications(for: d, language: .c)
    await assertEqual(bsm.cachedMainFile(for: a), c)
    let bMain = await bsm.cachedMainFile(for: b)
    XCTAssert(Set([c, d]).contains(bMain))
    await assertEqual(bsm.cachedMainFile(for: c), c)
    await assertEqual(bsm.cachedMainFile(for: d), d)

    await mainFiles.updateMainFiles(for: a, to: [a])
    await mainFiles.updateMainFiles(for: b, to: [c, d, a])

    await assertEqual(bsm.cachedMainFile(for: a), c)
    await assertEqual(bsm.cachedMainFile(for: b), bMain)
    await assertEqual(bsm.cachedMainFile(for: c), c)
    await assertEqual(bsm.cachedMainFile(for: d), d)

    await bsm.mainFilesChanged()

    await assertEqual(bsm.cachedMainFile(for: a), a)
    await assertEqual(bsm.cachedMainFile(for: b), a)
    await assertEqual(bsm.cachedMainFile(for: c), c)
    await assertEqual(bsm.cachedMainFile(for: d), d)

    await bsm.unregisterForChangeNotifications(for: a)
    await assertEqual(bsm.cachedMainFile(for: a), nil)
    await assertEqual(bsm.cachedMainFile(for: b), a)
    await assertEqual(bsm.cachedMainFile(for: c), c)
    await assertEqual(bsm.cachedMainFile(for: d), d)

    await bsm.unregisterForChangeNotifications(for: b)
    await bsm.mainFilesChanged()
    await bsm.unregisterForChangeNotifications(for: c)
    await bsm.unregisterForChangeNotifications(for: d)
    await assertEqual(bsm.cachedMainFile(for: a), nil)
    await assertEqual(bsm.cachedMainFile(for: b), nil)
    await assertEqual(bsm.cachedMainFile(for: c), nil)
    await assertEqual(bsm.cachedMainFile(for: d), nil)
  }

  func testSettingsMainFile() async throws {
    let a = try DocumentURI(string: "bsm:a.swift")
    let mainFiles = ManualMainFilesProvider([a: [a]])
    let del = await BSMDelegate()
    let bsm = await BuildSystemManager(
      buildSystemKind: .testBuildSystem(projectRoot: try AbsolutePath(validating: "/")),
      toolchainRegistry: ToolchainRegistry.forTesting,
      options: SourceKitLSPOptions(),
      swiftpmTestHooks: SwiftPMTestHooks(),
      delegate: del,
      reloadPackageStatusCallback: { _ in }
    )
    await del.setBuildSystemManager(bsm)
    await bsm.setMainFilesProvider(mainFiles)
    let bs = try await unwrap(bsm.buildSystem?.underlyingBuildSystem as? TestBuildSystem)
    defer { withExtendedLifetime(bsm) {} }  // Keep BSM alive for callbacks.

    await bs.setBuildSettings(for: a, to: BuildSettingsResponse(compilerArguments: ["x"]))
    // Wait for the new build settings to settle before registering for change notifications
    await bsm.waitForUpToDateBuildGraph()
    await bsm.registerForChangeNotifications(for: a, language: .swift)
    assertEqual(await bsm.buildSettingsInferredFromMainFile(for: a, language: .swift)?.compilerArguments, ["x"])

    let changed = expectation(description: "changed settings")
    await del.setExpected([
      (a, .swift, FallbackBuildSystem(options: .init()).buildSettings(for: a, language: .swift), changed)
    ])
    await bs.setBuildSettings(for: a, to: nil)
    try await fulfillmentOfOrThrow([changed])
  }

  func testSettingsMainFileInitialNil() async throws {
    let a = try DocumentURI(string: "bsm:a.swift")
    let mainFiles = ManualMainFilesProvider([a: [a]])
    let del = await BSMDelegate()
    let bsm = await BuildSystemManager(
      buildSystemKind: .testBuildSystem(projectRoot: try AbsolutePath(validating: "/")),
      toolchainRegistry: ToolchainRegistry.forTesting,
      options: SourceKitLSPOptions(),
      swiftpmTestHooks: SwiftPMTestHooks(),
      delegate: del,
      reloadPackageStatusCallback: { _ in }
    )
    await del.setBuildSystemManager(bsm)
    await bsm.setMainFilesProvider(mainFiles)
    let bs = try await unwrap(bsm.buildSystem?.underlyingBuildSystem as? TestBuildSystem)
    defer { withExtendedLifetime(bsm) {} }  // Keep BSM alive for callbacks.
    await bsm.registerForChangeNotifications(for: a, language: .swift)

    let changed = expectation(description: "changed settings")
    await del.setExpected([(a, .swift, FileBuildSettings(compilerArguments: ["x"]), changed)])
    await bs.setBuildSettings(for: a, to: BuildSettingsResponse(compilerArguments: ["x"]))
    try await fulfillmentOfOrThrow([changed])
  }

  func testSettingsMainFileWithFallback() async throws {
    let a = try DocumentURI(string: "bsm:a.swift")
    let mainFiles = ManualMainFilesProvider([a: [a]])
    let del = await BSMDelegate()
    let bsm = await BuildSystemManager(
      buildSystemKind: .testBuildSystem(projectRoot: try AbsolutePath(validating: "/")),
      toolchainRegistry: ToolchainRegistry.forTesting,
      options: SourceKitLSPOptions(),
      swiftpmTestHooks: SwiftPMTestHooks(),
      delegate: del,
      reloadPackageStatusCallback: { _ in }
    )
    await del.setBuildSystemManager(bsm)
    await bsm.setMainFilesProvider(mainFiles)
    let bs = try await unwrap(bsm.buildSystem?.underlyingBuildSystem as? TestBuildSystem)
    defer { withExtendedLifetime(bsm) {} }  // Keep BSM alive for callbacks.
    let fallbackSettings = await FallbackBuildSystem(options: .init()).buildSettings(for: a, language: .swift)
    await bsm.registerForChangeNotifications(for: a, language: .swift)
    assertEqual(await bsm.buildSettingsInferredFromMainFile(for: a, language: .swift), fallbackSettings)

    let changed = expectation(description: "changed settings")
    await del.setExpected([(a, .swift, FileBuildSettings(compilerArguments: ["non-fallback", "args"]), changed)])
    await bs.setBuildSettings(for: a, to: BuildSettingsResponse(compilerArguments: ["non-fallback", "args"]))
    try await fulfillmentOfOrThrow([changed])

    let revert = expectation(description: "revert to fallback settings")
    await del.setExpected([(a, .swift, fallbackSettings, revert)])
    await bs.setBuildSettings(for: a, to: nil)
    try await fulfillmentOfOrThrow([revert])
  }

  func testSettingsHeaderChangeMainFile() async throws {
    let h = try DocumentURI(string: "bsm:header.h")
    let cpp1 = try DocumentURI(string: "bsm:main.cpp")
    let cpp2 = try DocumentURI(string: "bsm:other.cpp")
    let mainFiles = ManualMainFilesProvider(
      [
        h: [cpp1],
        cpp1: [cpp1],
        cpp2: [cpp2],
      ]
    )

    let del = await BSMDelegate()
    let bsm = await BuildSystemManager(
      buildSystemKind: .testBuildSystem(projectRoot: try AbsolutePath(validating: "/")),
      toolchainRegistry: ToolchainRegistry.forTesting,
      options: SourceKitLSPOptions(),
      swiftpmTestHooks: SwiftPMTestHooks(),
      delegate: del,
      reloadPackageStatusCallback: { _ in }
    )
    await del.setBuildSystemManager(bsm)
    await bsm.setMainFilesProvider(mainFiles)
    let bs = try await unwrap(bsm.buildSystem?.underlyingBuildSystem as? TestBuildSystem)
    defer { withExtendedLifetime(bsm) {} }  // Keep BSM alive for callbacks.

    await bs.setBuildSettings(for: cpp1, to: BuildSettingsResponse(compilerArguments: ["C++ 1"]))
    await bs.setBuildSettings(for: cpp2, to: BuildSettingsResponse(compilerArguments: ["C++ 2"]))

    // Wait for the new build settings to settle before registering for change notifications
    await bsm.waitForUpToDateBuildGraph()
    await bsm.registerForChangeNotifications(for: h, language: .c)
    assertEqual(await bsm.buildSettingsInferredFromMainFile(for: h, language: .c)?.compilerArguments, ["C++ 1"])

    await mainFiles.updateMainFiles(for: h, to: [cpp2])

    let changed = expectation(description: "changed settings to cpp2")
    await del.setExpected([(h, .c, FileBuildSettings(compilerArguments: ["C++ 2"]), changed)])
    await bsm.mainFilesChanged()
    try await fulfillmentOfOrThrow([changed])

    let changed2 = expectation(description: "still cpp2, no update")
    changed2.isInverted = true
    await del.setExpected([(h, .c, nil, changed2)])
    await bsm.mainFilesChanged()
    try await fulfillmentOfOrThrow([changed2], timeout: 1)

    await mainFiles.updateMainFiles(for: h, to: [cpp1, cpp2])

    let changed3 = expectation(description: "added lexicographically earlier main file")
    await del.setExpected([(h, .c, FileBuildSettings(compilerArguments: ["C++ 1"]), changed3)])
    await bsm.mainFilesChanged()
    try await fulfillmentOfOrThrow([changed3], timeout: 1)

    await mainFiles.updateMainFiles(for: h, to: [])

    let changed4 = expectation(description: "changed settings to []")
    await del.setExpected([
      (h, .c, FallbackBuildSystem(options: .init()).buildSettings(for: h, language: .cpp), changed4)
    ])
    await bsm.mainFilesChanged()
    try await fulfillmentOfOrThrow([changed4])
  }

  func testSettingsOneMainTwoHeader() async throws {
    let h1 = try DocumentURI(string: "bsm:header1.h")
    let h2 = try DocumentURI(string: "bsm:header2.h")
    let cpp = try DocumentURI(string: "bsm:main.cpp")
    let mainFiles = ManualMainFilesProvider(
      [
        h1: [cpp],
        h2: [cpp],
      ]
    )

    let del = await BSMDelegate()
    let bsm = await BuildSystemManager(
      buildSystemKind: .testBuildSystem(projectRoot: try AbsolutePath(validating: "/")),
      toolchainRegistry: ToolchainRegistry.forTesting,
      options: SourceKitLSPOptions(),
      swiftpmTestHooks: SwiftPMTestHooks(),
      delegate: del,
      reloadPackageStatusCallback: { _ in }
    )
    await del.setBuildSystemManager(bsm)
    await bsm.setMainFilesProvider(mainFiles)
    let bs = try await unwrap(bsm.buildSystem?.underlyingBuildSystem as? TestBuildSystem)
    defer { withExtendedLifetime(bsm) {} }  // Keep BSM alive for callbacks.

    let cppArg = "C++ Main File"
    await bs.setBuildSettings(for: cpp, to: BuildSettingsResponse(compilerArguments: [cppArg, cpp.pseudoPath]))

    // Wait for the new build settings to settle before registering for change notifications
    await bsm.waitForUpToDateBuildGraph()

    await bsm.registerForChangeNotifications(for: h1, language: .c)
    await bsm.registerForChangeNotifications(for: h2, language: .c)

    let expectedArgsH1 = FileBuildSettings(compilerArguments: ["-xc++", cppArg, h1.pseudoPath])
    let expectedArgsH2 = FileBuildSettings(compilerArguments: ["-xc++", cppArg, h2.pseudoPath])
    assertEqual(await bsm.buildSettingsInferredFromMainFile(for: h1, language: .c), expectedArgsH1)
    assertEqual(await bsm.buildSettingsInferredFromMainFile(for: h2, language: .c), expectedArgsH2)

    let newCppArg = "New C++ Main File"
    let changed1 = expectation(description: "initial settings h1 via cpp")
    let changed2 = expectation(description: "initial settings h2 via cpp")
    let newArgsH1 = FileBuildSettings(compilerArguments: ["-xc++", newCppArg, h1.pseudoPath])
    let newArgsH2 = FileBuildSettings(compilerArguments: ["-xc++", newCppArg, h2.pseudoPath])
    await del.setExpected([
      (h1, .c, newArgsH1, changed1),
      (h2, .c, newArgsH2, changed2),
    ])
    await bs.setBuildSettings(for: cpp, to: BuildSettingsResponse(compilerArguments: [newCppArg, cpp.pseudoPath]))
    try await fulfillmentOfOrThrow([changed1, changed2])
  }

  func testSettingsChangedAfterUnregister() async throws {
    let a = try DocumentURI(string: "bsm:a.swift")
    let b = try DocumentURI(string: "bsm:b.swift")
    let c = try DocumentURI(string: "bsm:c.swift")
    let mainFiles = ManualMainFilesProvider([a: [a], b: [b], c: [c]])
    let del = await BSMDelegate()
    let bsm = await BuildSystemManager(
      buildSystemKind: .testBuildSystem(projectRoot: try AbsolutePath(validating: "/")),
      toolchainRegistry: ToolchainRegistry.forTesting,
      options: SourceKitLSPOptions(),
      swiftpmTestHooks: SwiftPMTestHooks(),
      delegate: del,
      reloadPackageStatusCallback: { _ in }
    )
    await del.setBuildSystemManager(bsm)
    await bsm.setMainFilesProvider(mainFiles)
    let bs = try await unwrap(bsm.buildSystem?.underlyingBuildSystem as? TestBuildSystem)
    defer { withExtendedLifetime(bsm) {} }  // Keep BSM alive for callbacks.

    await bs.setBuildSettings(for: a, to: BuildSettingsResponse(compilerArguments: ["a"]))
    await bs.setBuildSettings(for: b, to: BuildSettingsResponse(compilerArguments: ["b"]))
    await bs.setBuildSettings(for: c, to: BuildSettingsResponse(compilerArguments: ["c"]))

    // Wait for the new build settings to settle before registering for change notifications
    await bsm.waitForUpToDateBuildGraph()

    await bsm.registerForChangeNotifications(for: a, language: .swift)
    await bsm.registerForChangeNotifications(for: b, language: .swift)
    await bsm.registerForChangeNotifications(for: c, language: .swift)
    assertEqual(await bsm.buildSettingsInferredFromMainFile(for: a, language: .swift)?.compilerArguments, ["a"])
    assertEqual(await bsm.buildSettingsInferredFromMainFile(for: b, language: .swift)?.compilerArguments, ["b"])
    assertEqual(await bsm.buildSettingsInferredFromMainFile(for: c, language: .swift)?.compilerArguments, ["c"])

    let changedB = expectation(description: "changed settings b")
    await del.setExpected([(b, .swift, FileBuildSettings(compilerArguments: ["new-b"]), changedB)])

    await bsm.unregisterForChangeNotifications(for: a)
    await bsm.unregisterForChangeNotifications(for: c)

    // At this point only b is registered, but that can race with notifications,
    // so ensure nothing bad happens and we still get the notification for b.
    await bs.setBuildSettings(for: a, to: BuildSettingsResponse(compilerArguments: ["new-a"]))
    await bs.setBuildSettings(for: b, to: BuildSettingsResponse(compilerArguments: ["new-b"]))
    await bs.setBuildSettings(for: c, to: BuildSettingsResponse(compilerArguments: ["new-c"]))

    try await fulfillmentOfOrThrow([changedB])
  }

  func testDependenciesUpdated() async throws {
    let a = try DocumentURI(string: "bsm:a.swift")
    let mainFiles = ManualMainFilesProvider([a: [a]])

    let del = await BSMDelegate()
    let bsm = await BuildSystemManager(
      buildSystemKind: .testBuildSystem(projectRoot: try AbsolutePath(validating: "/")),
      toolchainRegistry: ToolchainRegistry.forTesting,
      options: SourceKitLSPOptions(),
      swiftpmTestHooks: SwiftPMTestHooks(),
      delegate: del,
      reloadPackageStatusCallback: { _ in }
    )
    await del.setBuildSystemManager(bsm)
    await bsm.setMainFilesProvider(mainFiles)
    let bs = try await unwrap(bsm.buildSystem?.underlyingBuildSystem as? TestBuildSystem)
    defer { withExtendedLifetime(bsm) {} }  // Keep BSM alive for callbacks.

    await bs.setBuildSettings(for: a, to: BuildSettingsResponse(compilerArguments: ["x"]))
    assertEqual(await bsm.buildSettingsInferredFromMainFile(for: a, language: .swift)?.compilerArguments, ["x"])

    await bsm.registerForChangeNotifications(for: a, language: .swift)

    let depUpdate2 = expectation(description: "dependencies update 2")
    await del.setExpectedDependenciesUpdate([(a, depUpdate2, #file, #line)])

    bsm.handle(DidUpdateTextDocumentDependenciesNotification(documents: [a]))
    try await fulfillmentOfOrThrow([depUpdate2])
  }
}

// MARK: Helper Classes for Testing

/// A simple `MainFilesProvider` that wraps a dictionary, for testing.
private final actor ManualMainFilesProvider: MainFilesProvider {
  private var mainFiles: [DocumentURI: Set<DocumentURI>]

  init(_ mainFiles: [DocumentURI: Set<DocumentURI>]) {
    self.mainFiles = mainFiles
  }

  func updateMainFiles(for file: DocumentURI, to mainFiles: Set<DocumentURI>) async {
    self.mainFiles[file] = mainFiles
  }

  func mainFilesContainingFile(_ file: DocumentURI) -> Set<DocumentURI> {
    if let result = mainFiles[file] {
      return result
    }
    return Set()
  }
}

/// A `BuildSystemManagerDelegate` setup for testing.
private actor BSMDelegate: BuildSystemManagerDelegate {
  fileprivate typealias ExpectedBuildSettingChangedCall = (
    uri: DocumentURI, language: Language, settings: FileBuildSettings?, expectation: XCTestExpectation,
    file: StaticString, line: UInt
  )
  fileprivate typealias ExpectedDependenciesUpdatedCall = (
    uri: DocumentURI, expectation: XCTestExpectation, file: StaticString, line: UInt
  )

  weak var bsm: BuildSystemManager?
  var expected: [ExpectedBuildSettingChangedCall] = []

  /// - Note: Needed to set `expected` outside of the actor's isolation context.
  func setExpected(
    _ expected: [(uri: DocumentURI, language: Language, settings: FileBuildSettings?, expectation: XCTestExpectation)],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    self.expected = expected.map { ($0.uri, $0.language, $0.settings, $0.expectation, file, line) }
  }

  func setBuildSystemManager(_ buildSystemManager: BuildSystemManager) {
    bsm = buildSystemManager
  }

  var expectedDependenciesUpdate: [(uri: DocumentURI, expectation: XCTestExpectation, file: StaticString, line: UInt)] =
    []

  /// - Note: Needed to set `expected` outside of the actor's isolation context.
  func setExpectedDependenciesUpdate(_ expectedDependenciesUpdated: [ExpectedDependenciesUpdatedCall]) {
    self.expectedDependenciesUpdate = expectedDependenciesUpdated
  }

  init() async {}

  func fileBuildSettingsChanged(_ changedFiles: Set<DocumentURI>) async {
    for uri in changedFiles {
      guard let expectedIndex = expected.firstIndex(where: { $0.uri == uri }) else {
        XCTFail("unexpected settings change for \(uri)")
        continue
      }
      let expected = expected[expectedIndex]
      self.expected.remove(at: expectedIndex)

      XCTAssertEqual(uri, expected.uri, file: expected.file, line: expected.line)
      let settings = await bsm?.buildSettingsInferredFromMainFile(for: uri, language: expected.language)
      XCTAssertEqual(settings, expected.settings, file: expected.file, line: expected.line)
      expected.expectation.fulfill()
    }
  }

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

  nonisolated func logMessageToIndexLog(taskID: BuildSystemIntegration.IndexTaskID, message: String) {}

  func sourceFilesDidChange() async {}
}
