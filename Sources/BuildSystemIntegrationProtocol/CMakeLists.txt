
add_library(BuildSystemIntegrationProtocol STATIC
  BuildSettingsRequests.swift
  DidChangeWatchedFilesNotification.swift
  InitializeRequest.swift
  LogMessageNotification
  PrepareTargetsRequest.swift
  Target.swift
  TargetPropertiesRequest.swift
  TextDocumentTargets.swift
  WorkspaceTargetsRequest.swift)
set_target_properties(BuildSystemIntegrationProtocol PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})
target_link_libraries(BuildSystemIntegration PUBLIC
  LanguageServerProtocol)
