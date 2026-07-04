import Foundation

/// Redacts secrets from strings before they reach logs or error surfaces (§3).
/// Tokens must never be logged.
enum SecretRedaction {
    /// Patterns that look like secrets: Slack tokens and common API-key shapes.
    private static let patterns: [String] = [
        #"xox[abpse]-[A-Za-z0-9-]+"#,   // Slack tokens (xoxp/xoxb/xoxa/xoxs/xoxe)
        #"sk-[A-Za-z0-9_-]{8,}"#,         // OpenAI-style keys
        #"AIza[A-Za-z0-9_-]{10,}"#,       // Google API keys
        #"Bearer\s+[A-Za-z0-9._-]+"#,     // Authorization bearer values
    ]

    private static let regexes: [NSRegularExpression] = patterns.compactMap {
        try? NSRegularExpression(pattern: $0)
    }

    /// Replace any secret-looking substrings with `‹redacted›`.
    static func redact(_ input: String) -> String {
        var output = input
        for regex in regexes {
            let range = NSRange(output.startIndex..., in: output)
            output = regex.stringByReplacingMatches(
                in: output, range: range, withTemplate: "‹redacted›"
            )
        }
        return output
    }
}
