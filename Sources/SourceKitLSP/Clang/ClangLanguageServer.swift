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
import LanguageServerProtocol
import LanguageServerProtocolJSONRPC
import LSPLogging
import SKCore
import SKSupport

import struct TSCBasic.AbsolutePath

#if os(Windows)
import WinSDK
#endif

extension NSLock {
  /// NOTE: Keep in sync with SwiftPM's 'Sources/Basics/NSLock+Extensions.swift'
  fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}

/// A thin wrapper over a connection to a clangd server providing build setting handling.
///
/// In addition, it also intercepts notifications and replies from clangd in order to do things
/// like witholding diagnostics when fallback build settings are being used.
///
/// ``ClangLangaugeServerShim`` conforms to ``MessageHandler`` to receive
/// requests and notifications **from** clangd, not from the editor and it will
/// forward them to the editor.
actor ClangLanguageServerShim: ToolchainLanguageServer, MessageHandler {
  /// The server's request queue.
  ///
  /// All incoming requests start on this queue, but should reply or move to another queue as soon as possible to avoid blocking.
  public let queue2: DispatchQueue = DispatchQueue(label: "language-server-queue", qos: .userInitiated)

  /// The connection to the client. In the case of `ClangLanguageServerShim`,
  /// the client is always a ``SourceKitServer``, which will forward the request
  /// to the editor.
  public let client: Connection

  /// The connection to the clangd LSP. `nil` until `startClangdProcesss` has been called.
  var clangd: Connection!

  /// Capabilities of the clangd LSP, if received.
  var capabilities: ServerCapabilities? = nil

  /// Path to the clang binary.
  let clangPath: AbsolutePath?
  
  /// Path to the `clangd` binary.
  let clangdPath: AbsolutePath
  
  let clangdOptions: [String]

  /// The current state of the `clangd` language server.
  /// Changing the property automatically notified the state change handlers.
  private var state: LanguageServerState {
    didSet {
      // `state` must only be set from `queue`.
      for handler in stateChangeHandlers {
        handler(oldValue, state)
      }
    }
  }
  
  private var stateChangeHandlers: [(_ oldState: LanguageServerState, _ newState: LanguageServerState) -> Void] = []
  
  /// The date at which `clangd` was last restarted.
  /// Used to delay restarting in case of a crash loop.
  private var lastClangdRestart: Date?
  
  /// Whether or not a restart of `clangd` has been scheduled.
  /// Used to make sure we are not restarting `clangd` twice.
  private var clangRestartScheduled = false
  
  /// The `InitializeRequest` with which `clangd` was originally initialized.
  /// Stored so we can replay the initialization when clangd crashes.
  private var initializeRequest: InitializeRequest?

  /// The workspace this `ClangLanguageServer` was opened for.
  /// `clangd` doesn't have support for multi-root workspaces, so we need to start a separate `clangd` instance for every workspace root.
  private weak var workspace: Workspace?

  /// A callback with which `ClangLanguageServer` can request its owner to reopen all documents in case it has crashed.
  private let reopenDocuments: (ToolchainLanguageServer) -> Void

  private var openDocuments: [DocumentURI: Language] = [:]

  /// While `clangd` is running, its PID.
#if os(Windows)
  private var hClangd: HANDLE = INVALID_HANDLE_VALUE
#else
  private var clangdPid: Int32?
#endif

  /// Creates a language server for the given client referencing the clang binary specified in `toolchain`.
  /// Returns `nil` if `clangd` can't be found.
  public init?(
    client: LocalConnection,
    toolchain: Toolchain,
    options: SourceKitServer.Options,
    workspace: Workspace,
    reopenDocuments: @escaping (ToolchainLanguageServer) -> Void,
    workspaceForDocument: @escaping (DocumentURI) async -> Workspace?
  ) async throws {
    guard let clangdPath = toolchain.clangd else {
      return nil
    }
    self.clangPath = toolchain.clang
    self.clangdPath = clangdPath
    self.clangdOptions = options.clangdOptions
    self.workspace = workspace
    self.reopenDocuments = reopenDocuments
    self.state = .connected
    self.client = client
    try startClangdProcesss()
  }

  private func buildSettings(for document: DocumentURI) async -> ClangBuildSettings? {
    guard let workspace,
          let language = openDocuments[document]
    else {
      return nil
    }
    let buildSystemChange = await workspace.buildSystemManager.settings(for: document, language: language)
    return ClangBuildSettings(change: buildSystemChange, clangPath: self.clangPath)
  }

  func canHandle(workspace: Workspace) -> Bool {
    // We launch different clangd instance for each workspace because clangd doesn't have multi-root workspace support.
    return workspace === self.workspace
  }

  func addStateChangeHandler(handler: @escaping (LanguageServerState, LanguageServerState) -> Void) {
    self.stateChangeHandlers.append(handler)
  }

  private func handleClangdTermination(terminationStatus: Int32) {
#if os(Windows)
    self.hClangd = INVALID_HANDLE_VALUE
#else
    self.clangdPid = nil
#endif
    if terminationStatus != 0 {
      self.state = .connectionInterrupted
      self.restartClangd()
    }
  }

  /// Start the `clangd` process, either on creation of the `ClangLanguageServerShim` or after `clangd` has crashed.
  private func startClangdProcesss() throws {
    // Since we are starting a new clangd process, reset the list of open document
    openDocuments = [:]

    let usToClangd: Pipe = Pipe()
    let clangdToUs: Pipe = Pipe()

    let connectionToClangd = JSONRPCConnection(
      protocol: MessageRegistry.lspProtocol,
      inFD: clangdToUs.fileHandleForReading,
      outFD: usToClangd.fileHandleForWriting
    )
    self.clangd = connectionToClangd

    connectionToClangd.start(receiveHandler: self) {
      // FIXME: keep the pipes alive until we close the connection. This
      // should be fixed systemically.
      withExtendedLifetime((usToClangd, clangdToUs)) {}
    }

    let process = Foundation.Process()
    process.executableURL = clangdPath.asURL
    process.arguments = [
      "-compile_args_from=lsp",   // Provide compiler args programmatically.
      "-background-index=false",  // Disable clangd indexing, we use the build
      "-index=false"             // system index store instead.
    ] + clangdOptions

    process.standardOutput = clangdToUs
    process.standardInput = usToClangd
    process.terminationHandler = { [weak self] process in
      log("clangd exited: \(process.terminationReason) \(process.terminationStatus)")
      connectionToClangd.close()
      guard let self = self else { return }
      Task {
        await self.handleClangdTermination(terminationStatus: process.terminationStatus)
      }
    }
    try process.run()
#if os(Windows)
    self.hClangd = process.processHandle
#else
    self.clangdPid = process.processIdentifier
#endif
  }

  private func restartClangdImpl(initializeRequest: InitializeRequest) {
    self.clangRestartScheduled = false
    do {
      try self.startClangdProcesss()
      // FIXME: We assume that clangd will return the same capabilites after restarting.
      // Theoretically they could have changed and we would need to inform SourceKitServer about them.
      // But since SourceKitServer more or less ignores them right now anyway, this should be fine for now.
      _ = try self.initializeSync(initializeRequest)
      self.clientInitialized(InitializedNotification())
      self.reopenDocuments(self)
      self.state = .connected
    } catch {
      log("Failed to restart clangd after a crash.", level: .error)
    }
  }

  /// Restart `clangd` after it has crashed.
  /// Delays restarting of `clangd` in case there is a crash loop.
  private func restartClangd() {
    precondition(self.state == .connectionInterrupted)

    precondition(self.clangRestartScheduled == false)
    self.clangRestartScheduled = true

    guard let initializeRequest = self.initializeRequest else {
      log("clangd crashed before it was sent an InitializeRequest.", level: .error)
      return
    }

    let restartDelay: Int
    if let lastClangdRestart = self.lastClangdRestart, Date().timeIntervalSince(lastClangdRestart) < 30 {
      log("clangd has already been restarted in the last 30 seconds. Delaying another restart by 10 seconds.", level: .info)
      restartDelay = 10
    } else {
      restartDelay = 0
    }
    self.lastClangdRestart = Date()

    DispatchQueue.global(qos: .default).asyncAfter(deadline: .now() + .seconds(restartDelay)) {
      Task {
        await self.restartClangdImpl(initializeRequest: initializeRequest)
      }
    }
  }

  /// Handler for notifications received **from** clangd, ie. **clangd** is
  /// sending a notification that's intended for the client.
  ///
  /// We should either handle it ourselves or forward it to the client.
  func handle(_ params: some NotificationType, from clientID: ObjectIdentifier) async {
    if let publishDiags = params as? PublishDiagnosticsNotification {
      await self.publishDiagnostics(Notification(publishDiags, clientID: clientID))
    } else if clientID == ObjectIdentifier(self.clangd) {
      self.client.send(params)
    }
  }

  /// Handler for requests received **from** clangd, ie. **clangd** is
  /// sending a notification that's intended for the client.
  ///
  /// We should either handle it ourselves or forward it to the client.
  func handle<R: RequestType>(
    _ params: R,
    id: RequestID,
    from clientID: ObjectIdentifier,
    reply: @escaping (LSPResult<R.Response>) -> Void
  ) {
    let request = Request(params, id: id, clientID: clientID, cancellation: CancellationToken(), reply: { result in
      reply(result)
    })

    if request.clientID == ObjectIdentifier(self.clangd) {
      self.forwardRequest(request, to: self.client)
    } else {
      request.reply(.failure(ResponseError.methodNotFound(R.method)))
    }
  }

  /// Forwards a request to the given connection, taking care of replying to the original request
  /// and cancellation, while providing a callback with the response for additional processing.
  ///
  /// Immediately after `handler` returns, this passes the result to the original reply handler by
  /// calling `request.reply(result)`.
  ///
  /// The cancellation token from the original request is automatically linked to the forwarded
  /// request such that cancelling the original request will cancel the forwarded request.
  ///
  /// - Parameters:
  ///   - request: The request to forward.
  ///   - to: Where to forward the request (e.g. self.clangd).
  ///   - handler: An optional closure that will be called with the result of the request.
  func forwardRequest<R>(
    _ request: Request<R>,
    to: Connection,
    _ handler: ((LSPResult<R.Response>) -> Void)? = nil)
  {
    let id = to.send(request.params, queue: queue2) { result in
      handler?(result)
      request.reply(result)
    }
    request.cancellationToken.addCancellationHandler {
      to.send(CancelRequestNotification(id: id))
    }
  }
  
  /// Forward the given `notification` to `clangd` by asynchronously switching to `queue` for a thread-safe access to `clangd`.
  private func forwardNotificationToClangdOnQueue<Notification>(_ notification: Notification) where Notification: NotificationType {
    self.clangd.send(notification)
  }

  func _crash() {
    // Since `clangd` doesn't have a method to crash it, kill it.
#if os(Windows)
    if self.hClangd != INVALID_HANDLE_VALUE {
      // FIXME(compnerd) this is a bad idea - we can potentially deadlock the
      // process if a kobject is a pending state.  Unfortunately, the
      // `OpenProcess(PROCESS_TERMINATE, ...)`, `CreateRemoteThread`,
      // `ExitProcess` dance, while safer, can also indefinitely hang as
      // `CreateRemoteThread` may not be serviced depending on the state of
      // the process.  This just attempts to terminate the process, risking a
      // deadlock and resource leaks.
      _ = TerminateProcess(self.hClangd, 0)
    }
#else
    if let pid = self.clangdPid {
      kill(pid, SIGKILL)
    }
#endif
  }
  
  /// Forward the given `request` to `clangd` by asynchronously switching to `queue` for a thread-safe access to `clangd`.
  private func forwardRequestToClangdOnQueue<R>(_ request: Request<R>, _ handler: ((LSPResult<R.Response>) -> Void)? = nil) {
    self.forwardRequest(request, to: self.clangd, handler)
  }
}

// MARK: - LanguageServer

extension ClangLanguageServerShim {

  /// Intercept clangd's `PublishDiagnosticsNotification` to withold it if we're using fallback
  /// build settings.
  func publishDiagnostics(_ note: Notification<PublishDiagnosticsNotification>) async {
    let params = note.params
    let buildSettings = await self.buildSettings(for: params.uri)
    let isFallback = buildSettings?.isFallback ?? true
    guard isFallback else {
      client.send(note.params)
      return
    }
    // Fallback: send empty publish notification instead.
    client.send(PublishDiagnosticsNotification(
      uri: params.uri, version: params.version, diagnostics: []))
  }

}

// MARK: - ToolchainLanguageServer

extension ClangLanguageServerShim {

  func initializeSync(_ initialize: InitializeRequest) throws -> InitializeResult {
    // Store the initialize request so we can replay it in case clangd crashes
    self.initializeRequest = initialize

    let result = try clangd.sendSync(initialize)
    self.capabilities = result.capabilities
    return result
  }

  public func clientInitialized(_ initialized: InitializedNotification) {
    forwardNotificationToClangdOnQueue(initialized)
  }

  public func shutdown() async {
    await withCheckedContinuation { continuation in
      _ = self.clangd.send(ShutdownRequest(), queue: self.queue2) { [weak self] _ in
        guard let self else { return }
        Task {
          await self.clangd.send(ExitNotification())
          if let localConnection = self.client as? LocalConnection {
            localConnection.close()
          }
          continuation.resume()
        }
      }
    }
  }

  // MARK: - Text synchronization

  public func openDocument(_ note: DidOpenTextDocumentNotification) async {
    openDocuments[note.textDocument.uri] = note.textDocument.language
    // Send clangd the build settings for the new file. We need to do this before
    // sending the open notification, so that the initial diagnostics already
    // have build settings.
    await documentUpdatedBuildSettings(note.textDocument.uri, change: .removedOrUnavailable)
    forwardNotificationToClangdOnQueue(note)
  }

  public func closeDocument(_ note: DidCloseTextDocumentNotification) {
    openDocuments[note.textDocument.uri] = nil
    forwardNotificationToClangdOnQueue(note)
  }

  public func changeDocument(_ note: DidChangeTextDocumentNotification) {
    forwardNotificationToClangdOnQueue(note)
  }

  public func willSaveDocument(_ note: WillSaveTextDocumentNotification) {

  }

  public func didSaveDocument(_ note: DidSaveTextDocumentNotification) {
    forwardNotificationToClangdOnQueue(note)
  }

  // MARK: - Build System Integration

  public func documentUpdatedBuildSettings(_ uri: DocumentURI, change: FileBuildSettingsChange) async {
    guard let url = uri.fileURL else {
      // FIXME: The clang workspace can probably be reworked to support non-file URIs.
      log("Received updated build settings for non-file URI '\(uri)'. Ignoring the update.")
      return
    }
    let clangBuildSettings = await self.buildSettings(for: uri)
//    assert(clangBuildSettings?.compilerArgs == change.newSettings?.compilerArguments)
    logAsync(level: clangBuildSettings == nil ? .warning : .debug) { _ in
      let settingsStr = clangBuildSettings == nil ? "nil" : clangBuildSettings!.compilerArgs.description
      return "settings for \(uri): \(settingsStr)"
    }

    // The compile command changed, send over the new one.
    // FIXME: what should we do if we no longer have valid build settings?
    if 
      let compileCommand = clangBuildSettings?.compileCommand,
      let pathString = (try? AbsolutePath(validating: url.path))?.pathString 
    {
      let note = DidChangeConfigurationNotification(settings: .clangd(
        ClangWorkspaceSettings(
          compilationDatabaseChanges: [pathString: compileCommand])))
      forwardNotificationToClangdOnQueue(note)
    }
  }

  public func documentDependenciesUpdated(_ uri: DocumentURI) {
    // In order to tell clangd to reload an AST, we send it an empty `didChangeTextDocument`
    // with `forceRebuild` set in case any missing header files have been added.
    // This works well for us as the moment since clangd ignores the document version.
    let note = DidChangeTextDocumentNotification(
      textDocument: VersionedTextDocumentIdentifier(uri, version: 0),
      contentChanges: [],
      forceRebuild: true)
    forwardNotificationToClangdOnQueue(note)
  }

  // MARK: - Text Document


  /// Returns true if the `ToolchainLanguageServer` will take ownership of the request.
  public func definition(_ req: Request<DefinitionRequest>) -> Bool {
    // We handle it to provide jump-to-header support for #import/#include.
    forwardRequestToClangdOnQueue(req)
    return true
  }

  /// Returns true if the `ToolchainLanguageServer` will take ownership of the request.
  public func declaration(_ req: Request<DeclarationRequest>) -> Bool {
    // We handle it to provide jump-to-header support for #import/#include.
    forwardRequestToClangdOnQueue(req)
    return true
  }

  func completion(_ req: Request<CompletionRequest>) {
    forwardRequestToClangdOnQueue(req)
  }

  func hover(_ req: Request<HoverRequest>) {
    forwardRequestToClangdOnQueue(req)
  }

  func symbolInfo(_ req: Request<SymbolInfoRequest>) {
    forwardRequestToClangdOnQueue(req)
  }

  func documentSymbolHighlight(_ req: Request<DocumentHighlightRequest>) {
    forwardRequestToClangdOnQueue(req)
  }

  func documentSymbol(_ req: Request<DocumentSymbolRequest>) {
    forwardRequestToClangdOnQueue(req)
  }

  func documentColor(_ req: Request<DocumentColorRequest>) {
    if self.capabilities?.colorProvider?.isSupported == true {
      self.forwardRequestToClangdOnQueue(req)
    } else {
      req.reply(.success([]))
    }
  }

  func documentSemanticTokens(_ req: Request<DocumentSemanticTokensRequest>) {
    forwardRequestToClangdOnQueue(req)
  }

  func documentSemanticTokensDelta(_ req: Request<DocumentSemanticTokensDeltaRequest>) {
    forwardRequestToClangdOnQueue(req)
  }

  func documentSemanticTokensRange(_ req: Request<DocumentSemanticTokensRangeRequest>) {
    forwardRequestToClangdOnQueue(req)
  }

  func colorPresentation(_ req: Request<ColorPresentationRequest>) {
    if self.capabilities?.colorProvider?.isSupported == true {
      self.forwardRequestToClangdOnQueue(req)
    } else {
      req.reply(.success([]))
    }
  }

  func codeAction(_ req: Request<CodeActionRequest>) {
    forwardRequestToClangdOnQueue(req)
  }

  func inlayHint(_ req: Request<InlayHintRequest>) {
    forwardRequestToClangdOnQueue(req)
  }

  func documentDiagnostic(_ req: Request<DocumentDiagnosticsRequest>) {
    forwardRequestToClangdOnQueue(req)
  }

  func foldingRange(_ req: Request<FoldingRangeRequest>) {
    if self.capabilities?.foldingRangeProvider?.isSupported == true {
      self.forwardRequestToClangdOnQueue(req)
    } else {
      req.reply(.success(nil))
    }
  }

  func openInterface(_ request: Request<OpenInterfaceRequest>) {
    request.reply(.failure(.unknown("unsupported method")))
  }

  // MARK: - Other

  func executeCommand(_ req: Request<ExecuteCommandRequest>) {
    forwardRequestToClangdOnQueue(req)
  }
}

/// Clang build settings derived from a `FileBuildSettingsChange`.
private struct ClangBuildSettings: Equatable {
  /// The compiler arguments, including the program name, argv[0].
  public let compilerArgs: [String]

  /// The working directory for the invocation.
  public let workingDirectory: String

  /// Whether the compiler arguments are considered fallback - we withhold diagnostics for
  /// fallback arguments and represent the file state differently.
  public let isFallback: Bool

  public init(_ settings: FileBuildSettings, clangPath: AbsolutePath?, isFallback: Bool = false) {
    var arguments = [clangPath?.pathString ?? "clang"] + settings.compilerArguments
    if arguments.contains("-fmodules") {
      // Clangd is not built with support for the 'obj' format.
      arguments.append(contentsOf: [
        "-Xclang", "-fmodule-format=raw"
      ])
    }
    if let workingDirectory = settings.workingDirectory {
      // FIXME: this is a workaround for clangd not respecting the compilation
      // database's "directory" field for relative -fmodules-cache-path.
      // rdar://63984913
      arguments.append(contentsOf: [
        "-working-directory", workingDirectory
      ])
    }

    self.compilerArgs = arguments
    self.workingDirectory = settings.workingDirectory ?? ""
    self.isFallback = isFallback
  }

  public init?(change: FileBuildSettingsChange, clangPath: AbsolutePath?) {
    switch change {
    case .fallback(let settings): self.init(settings, clangPath: clangPath, isFallback: true)
    case .modified(let settings): self.init(settings, clangPath: clangPath, isFallback: false)
    case .removedOrUnavailable: return nil
    }
  }

  public var compileCommand: ClangCompileCommand {
    return ClangCompileCommand(
        compilationCommand: self.compilerArgs, workingDirectory: self.workingDirectory)
  }
}
