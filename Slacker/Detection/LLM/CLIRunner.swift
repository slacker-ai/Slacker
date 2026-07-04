import Foundation

/// Seam for running an external command, so CLI LLM backends are testable without
/// spawning real processes (inject a stub in tests).
protocol CLIRunner: Sendable {
    /// Run `executable` with `arguments`, optionally piping `stdin`, and return stdout.
    func run(executable: String, arguments: [String], stdin: String?) async throws -> String
}

/// Production runner backed by `Process`. Requires the App Sandbox to be off (it is —
/// see `Slacker.entitlements`).
struct ProcessCLIRunner: CLIRunner {
    func run(executable: String, arguments: [String], stdin: String?) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = Self.childEnvironment(executable: executable)

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdinPipe: Pipe? = stdin == nil ? nil : Pipe()
            if let stdinPipe { process.standardInput = stdinPipe }

            process.terminationHandler = { proc in
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outData, encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: errData, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
                    continuation.resume(throwing: LLMError.cliFailed(message))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: LLMError.cliNotFound(executable))
                return
            }

            if let stdinPipe, let stdin {
                stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
                stdinPipe.fileHandleForWriting.closeFile()
            }
        }
    }

    /// A complete environment for the child CLI. A macOS GUI app launched from Finder
    /// can hand its children a stripped environment — notably missing `USER`/`LOGNAME`,
    /// which CLIs like `claude` need to read their credentials from the login Keychain
    /// (without them the tool reports "Not logged in" and the call silently fails).
    /// We start from the inherited environment and fill in the essentials, plus the
    /// binary's own directory on `PATH` so it can find sibling tools (e.g. `node`).
    private static func childEnvironment(executable: String) -> [String: String] {
        let info = ProcessInfo.processInfo
        var env = info.environment

        let home = info.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        env["HOME"] = home
        if env["USER"] == nil { env["USER"] = info.userName }
        if env["LOGNAME"] == nil { env["LOGNAME"] = info.userName }

        let binDir = (executable as NSString).deletingLastPathComponent
        let basePath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var pathDirs = basePath.split(separator: ":").map(String.init)
        if !binDir.isEmpty, !pathDirs.contains(binDir) { pathDirs.insert(binDir, at: 0) }
        env["PATH"] = pathDirs.joined(separator: ":")

        return env
    }
}
