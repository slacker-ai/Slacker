import Foundation

/// Locates a CLI binary by name: explicit override first, then PATH, then common
/// install locations (§ project decision: auto-detect + override).
///
/// macOS GUI apps launched from Finder/Xcode do NOT inherit the shell's `PATH`, so a bare
/// PATH scan misses tools installed by Homebrew, Node version managers (nvm/fnm/n), bun,
/// cargo, etc. We therefore also search well-known locations, including per-version Node
/// bin dirs — where npm-installed CLIs like `codex`/`claude` typically live.
enum BinaryLocator {
    static func defaultSearchDirs() -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path

        var dirs: [String] = []
        // Inherited PATH first (when present) — fastest path for common setups.
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs += path.split(separator: ":").map(String.init)
        }
        // Well-known fixed locations a GUI app's PATH usually omits.
        dirs += [
            "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.local/bin", "\(home)/bin",
            "\(home)/.bun/bin", "\(home)/.cargo/bin", "\(home)/.deno/bin",
            "\(home)/.volta/bin", "\(home)/.rbenv/shims",
            "\(home)/.npm-global/bin", "\(home)/.npm/bin", "\(home)/.yarn/bin",
            "/usr/bin", "/bin",
        ]
        // Node version managers install a bin dir per Node version — search them all.
        dirs += nodeVersionBinDirs(home: home, fileManager: fm)

        // De-duplicate, preserving order.
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }
    }

    /// Per-version Node `bin` directories for nvm / fnm / n, where globally-installed npm
    /// CLIs land. Returns candidate paths regardless of existence (`locate` filters).
    private static func nodeVersionBinDirs(home: String, fileManager fm: FileManager) -> [String] {
        let roots = [
            "\(home)/.nvm/versions/node",
            "\(home)/.fnm/node-versions",
            "\(home)/Library/Application Support/fnm/node-versions",
            "\(home)/.local/share/fnm/node-versions",
            "\(home)/n/versions/node",
        ]
        var result: [String] = []
        for root in roots {
            guard let versions = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for version in versions {
                // nvm/n: <root>/<version>/bin ; fnm: <root>/<version>/installation/bin
                result.append("\(root)/\(version)/bin")
                result.append("\(root)/\(version)/installation/bin")
            }
        }
        return result
    }

    /// Return an executable path for `name`, or nil if not found.
    static func locate(
        _ name: String,
        override: String? = nil,
        searchDirs: [String] = defaultSearchDirs(),
        fileManager: FileManager = .default
    ) -> String? {
        if let override, !override.isEmpty, fileManager.isExecutableFile(atPath: override) {
            return override
        }
        for dir in searchDirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
