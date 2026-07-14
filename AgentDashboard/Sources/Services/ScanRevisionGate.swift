import Foundation

/// Tracks scan requests so asynchronous results can be rejected after newer work arrives.
/// Access is owned by ProcessScanner's MainActor; Sendable only documents that captured
/// revision values are safe to pass into detached scan tasks.
struct ScanRevisionGate: Sendable {
    private(set) var current: UInt64 = 0

    @discardableResult
    mutating func registerRequest() -> UInt64 {
        current &+= 1
        return current
    }

    func accepts(_ revision: UInt64) -> Bool {
        revision == current
    }
}
