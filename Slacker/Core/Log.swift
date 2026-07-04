import Foundation
import os

/// Local-only structured logging (§3). Uses the unified logging system (no remote
/// logging) and redacts secrets from every message. Onboarding/detection use this to
/// debug locally without ever leaking tokens.
enum Log {
    private static let logger = Logger(subsystem: "com.slacker.Slacker", category: "app")

    static func info(_ message: @autoclosure () -> String) {
        let redacted = SecretRedaction.redact(message())
        logger.info("\(redacted, privacy: .public)")
        emitDebug(redacted)
    }

    static func error(_ message: @autoclosure () -> String) {
        let redacted = SecretRedaction.redact(message())
        logger.error("\(redacted, privacy: .public)")
        emitDebug(redacted)
    }

    static func debug(_ message: @autoclosure () -> String) {
        let redacted = SecretRedaction.redact(message())
        logger.debug("\(redacted, privacy: .public)")
        emitDebug(redacted)
    }

    /// In debug builds, also print to stdout so logs are visible in the Xcode console
    /// and when running the binary from a terminal.
    private static func emitDebug(_ redacted: String) {
        #if DEBUG
        print("[Slacker] \(redacted)")
        #endif
    }
}
