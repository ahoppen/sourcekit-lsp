import ArgumentParser
import TSCLibc

import class TSCBasic.LocalFileOutputByteStream
import class TSCBasic.ThreadSafeOutputByteStream

extension ThreadSafeOutputByteStream: @unchecked @retroactive Sendable {}

// A version of `stderrStream` from `TSCBasic` that is a `let` and can thus be used from Swift 6.
@MainActor
let stderrStreamConcurrencySafe: ThreadSafeOutputByteStream = try! ThreadSafeOutputByteStream(
  LocalFileOutputByteStream(
    filePointer: TSCLibc.stderr,
    closeOnDeinit: false
  )
)

// If `CommandConfiguration` is not sendable, commands can't have static `configuration` properties.
extension CommandConfiguration: @unchecked @retroactive Sendable {}
