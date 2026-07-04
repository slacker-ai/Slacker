import Foundation

enum SlackTextSanitizer {
    /// Removes triple-backtick fenced content. Slack log dumps often look actionable
    /// ("failed", "blocked", "done") but are evidence, not the user's ask.
    static func stripFencedBlocks(_ text: String) -> String {
        var result = ""
        var remainder = text[...]
        var isSkipping = false

        while let fence = remainder.range(of: "```") {
            if !isSkipping {
                result += remainder[..<fence.lowerBound]
            }
            remainder = remainder[fence.upperBound...]
            isSkipping.toggle()
        }

        if !isSkipping {
            result += remainder
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
