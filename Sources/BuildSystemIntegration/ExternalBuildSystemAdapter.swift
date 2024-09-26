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

import BuildServerProtocol
import Foundation
import LanguageServerProtocol
import LanguageServerProtocolJSONRPC
import SKLogging
import SKOptions

import struct TSCBasic.AbsolutePath
import func TSCBasic.getEnvSearchPaths
import var TSCBasic.localFileSystem
import func TSCBasic.lookupExecutablePath

private func executable(_ name: String) -> String {
  #if os(Windows)
  guard !name.hasSuffix(".exe") else { return name }
  return "\(name).exe"
  #else
  return name
  #endif
}

private let python3ExecutablePath: AbsolutePath? = {
  let pathVariable: String
  #if os(Windows)
  pathVariable = "Path"
  #else
  pathVariable = "PATH"
  #endif
  let searchPaths =
    getEnvSearchPaths(
      pathString: ProcessInfo.processInfo.environment[pathVariable],
      currentWorkingDirectory: localFileSystem.currentWorkingDirectory
    )

  return lookupExecutablePath(filename: executable("python3"), searchPaths: searchPaths)
    ?? lookupExecutablePath(filename: executable("python"), searchPaths: searchPaths)
}()

struct ExecutableNotFoundError: Error {
  let executableName: String
}

private struct BuildServerConfig: Codable {
  /// The name of the build tool.
  let name: String

  /// The version of the build tool.
  let version: String

  /// The bsp version of the build tool.
  let bspVersion: String

  /// A collection of languages supported by this BSP server.
  let languages: [String]

  /// Command arguments runnable via system processes to start a BSP server.
  let argv: [String]

  static func load(from path: AbsolutePath) throws -> BuildServerConfig {
    let decoder = JSONDecoder()
    let fileData = try localFileSystem.readFileContents(path).contents
    return try decoder.decode(BuildServerConfig.self, from: Data(fileData))
  }
}

/// Launches a subprocess that is a BSP server and manages the process's lifetime.
actor ExternalBuildSystemAdapter {
  private let projectRoot: AbsolutePath

  /// The `BuildSystemManager` that handles messages from the BSP server to SourceKit-LSP.
  var messagesToSourceKitLSPHandler: MessageHandler

  /// The JSON-RPC connection between SourceKit-LSP and the BSP server.
  private(set) var connectionToBuildServer: JSONRPCConnection?

  /// After a `build/initialize` request has been sent to the BSP server, that request, so we can replay it in case the
  /// server crashes.
  private var initializeRequest: InitializeBuildRequest?

  /// The date at which `clangd` was last restarted.
  /// Used to delay restarting in case of a crash loop.
  private var lastRestart: Date?

  static package func projectRoot(for workspaceFolder: AbsolutePath, options: SourceKitLSPOptions) -> AbsolutePath? {
    guard localFileSystem.isFile(workspaceFolder.appending(component: "buildServer.json")) else {
      return nil
    }
    return workspaceFolder
  }

  init(
    projectRoot: AbsolutePath,
    messagesToSourceKitLSPHandler: MessageHandler
  ) async throws {
    self.projectRoot = projectRoot
    self.messagesToSourceKitLSPHandler = messagesToSourceKitLSPHandler
    self.connectionToBuildServer = try await self.createConnectionToBspServer()
  }

  /// Change the handler that handles messages from the build server.
  ///
  /// The intended use of this is to intercept messages from the build server by `LegacyBuildServerBuildSystem`.
  func changeMessageToSourceKitLSPHandler(to newHandler: MessageHandler) {
    messagesToSourceKitLSPHandler = newHandler
    connectionToBuildServer?.changeReceiveHandler(messagesToSourceKitLSPHandler)
  }

  /// Send a notification to the build server.
  func send(_ notification: some NotificationType) async {
    guard let connectionToBuildServer else {
      logger.error("Dropping notification because BSP server has crashed: \(notification.forLogging)")
      return
    }
    connectionToBuildServer.send(notification)
  }

  /// Send a request to the build server.
  func send<Request: RequestType>(_ request: Request) async throws -> Request.Response {
    guard let connectionToBuildServer else {
      throw ResponseError.internalError("BSP server has crashed")
    }
    if let request = request as? InitializeBuildRequest {
      if initializeRequest != nil {
        logger.error("BSP server was initialized multiple times")
      }
      self.initializeRequest = request
    }
    return try await connectionToBuildServer.send(request)
  }

  /// Create a new JSONRPCConnection to the build server.
  private func createConnectionToBspServer() async throws -> JSONRPCConnection {
    let configPath = projectRoot.appending(component: "buildServer.json")
    let serverConfig = try BuildServerConfig.load(from: configPath)
    var serverPath = try AbsolutePath(validating: serverConfig.argv[0], relativeTo: projectRoot)
    var serverArgs = Array(serverConfig.argv[1...])

    if serverPath.suffix == ".py" {
      serverArgs = [serverPath.pathString] + serverArgs
      guard let interpreterPath = python3ExecutablePath else {
        throw ExecutableNotFoundError(executableName: "python3")
      }

      serverPath = interpreterPath
    }

    return try JSONRPCConnection.start(
      executable: serverPath.asURL,
      arguments: serverArgs,
      name: "BSP-Server",
      protocol: bspRegistry,
      stderrLoggingCategory: "bsp-server-stderr",
      client: messagesToSourceKitLSPHandler,
      terminationHandler: { [weak self] terminationStatus in
        guard let self else {
          return
        }
        if terminationStatus != 0 {
          Task {
            await orLog("Restarting BSP server") {
              try await handleBspServerCrash()
            }
          }
        }
      }
    ).connection
  }

  /// Restart the BSP server after it has crashed.
  private func handleBspServerCrash() async throws {
    // Set `connectionToBuildServer` to `nil` to indicate that there is currently no BSP server running.
    connectionToBuildServer = nil

    guard let initializeRequest else {
      logger.error("BSP server crashed before it was sent an initialize request. Not restarting.")
      return
    }

    logger.error("The BSP server has crashed. Restarting.")
    let restartDelay: Duration
    if let lastClangdRestart = self.lastRestart, Date().timeIntervalSince(lastClangdRestart) < 30 {
      logger.log("BSP server has been restarted in the last 30 seconds. Delaying another restart by 10 seconds.")
      restartDelay = .seconds(10)
    } else {
      restartDelay = .zero
    }
    self.lastRestart = Date()

    try await Task.sleep(for: restartDelay)

    let restartedConnection = try await self.createConnectionToBspServer()

    // We assume that the server returns the same initialize response after being restarted.
    // BSP does not set any state from the client to the server, so there are no other requests we need to replay
    // (other than `textDocument/registerForChanges`, which is only used by the legacy BSP protocol, which didn't have
    // crash recovery and doesn't need to gain it because it is deprecated).
    _ = try await restartedConnection.send(initializeRequest)
    restartedConnection.send(OnBuildInitializedNotification())
    self.connectionToBuildServer = restartedConnection

    // The build targets might have changed after the restart. Send a `buildTarget/didChange` notification to
    // SourceKit-LSP to discard cached information.
    self.messagesToSourceKitLSPHandler.handle(OnBuildTargetDidChangeNotification(changes: nil))
  }
}