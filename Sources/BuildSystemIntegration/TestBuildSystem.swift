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

import BuildSystemIntegrationProtocol
import LanguageServerProtocol
import SKOptions
import ToolchainRegistry

import struct TSCBasic.AbsolutePath

/// Build system to be used for testing BuildSystem and BuildSystemDelegate functionality with SourceKitLSPServer
/// and other components.
package actor TestBuildSystem: BuiltInBuildSystem {
  package static func projectRoot(for workspaceFolder: AbsolutePath, options: SourceKitLSPOptions) -> AbsolutePath? {
    return workspaceFolder
  }

  package let projectRoot: AbsolutePath
  package let indexStorePath: AbsolutePath? = nil
  package let indexDatabasePath: AbsolutePath? = nil

  weak package var delegate: BuildSystemDelegate?

  package func setDelegate(_ delegate: BuildSystemDelegate?) async {
    self.delegate = delegate
  }

  /// Build settings by file.
  private var buildSettingsByFile: [DocumentURI: BuildSettingsResponse] = [:]

  private weak var messageHandler: BuiltInBuildSystemMessageHandler?

  package init(
    projectRoot: AbsolutePath,
    messageHandler: any BuiltInBuildSystemMessageHandler
  ) {
    self.projectRoot = projectRoot
    self.messageHandler = messageHandler
  }

  package func setBuildSettings(for uri: DocumentURI, to buildSettings: BuildSettingsResponse?) async {
    buildSettingsByFile[uri] = buildSettings
    await self.messageHandler?.handle(DidChangeBuildSettingsNotification(uris: [uri]))
  }

  nonisolated package var supportsPreparation: Bool { false }

  package func buildSettings(request: BuildSettingsRequest) -> BuildSettingsResponse? {
    return buildSettingsByFile[request.uri]
  }

  package func defaultLanguage(for document: DocumentURI) async -> Language? {
    return nil
  }

  package func toolchain(for uri: DocumentURI, _ language: Language) async -> Toolchain? {
    return nil
  }

  package func textDocumentTargets(_ request: TextDocumentTargetsRequest) -> TextDocumentTargetsResponse {
    return TextDocumentTargetsResponse(targets: [ConfiguredTarget(identifier: "dummy")])
  }

  package func prepare(
    targets: [ConfiguredTarget],
    logMessageToIndexLog: @escaping @Sendable (_ taskID: IndexTaskID, _ message: String) -> Void
  ) async throws {
    throw PrepareNotSupportedError()
  }

  package func generateBuildGraph() {}

  package func waitForUpToDateBuildGraph() async {}

  package func topologicalSort(of targets: [ConfiguredTarget]) -> [ConfiguredTarget]? {
    return nil
  }

  package func targets(dependingOn targets: [ConfiguredTarget]) -> [ConfiguredTarget]? {
    return nil
  }

  package func didChangeWatchedFiles(
    notification: BuildSystemIntegrationProtocol.DidChangeWatchedFilesNotification
  ) async {}

  package func sourceFiles() async -> [SourceFileInfo] {
    return []
  }

  package func addSourceFilesDidChangeCallback(_ callback: @escaping () async -> Void) async {}
}
