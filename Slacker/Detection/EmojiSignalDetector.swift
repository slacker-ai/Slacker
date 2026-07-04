import Foundation

/// Shared reaction/text emoji semantics for open-loop vs resolved-loop signals.
/// Slack reaction names use colon names without colons, e.g. `white_check_mark`.
enum EmojiSignalDetector {
    static let resolvedReactionNames: Set<String> = [
        "white_check_mark", "heavy_check_mark", "ballot_box_with_check",
        "+1", "thumbsup", "ok_hand", "done", "shipit", "merged",
        "approved", "complete", "completed",
    ]

    static let openReactionNames: Set<String> = [
        "eyes", "hourglass", "hourglass_flowing_sand", "mag", "mag_right",
        "question", "grey_question", "thinking_face", "construction",
        "rotating_light", "warning", "raised_hand", "hand", "thread",
    ]

    private static let resolvedTextEmoji = ["✅", "✔", "☑", "👍", "👌"]
    private static let openTextEmoji = ["👀", "⏳", "⌛", "🔍", "🔎", "❓", "🤔", "🚧", "🚨", "⚠️", "⚠"]

    static func hasResolvedReaction(_ reactions: [SlackReaction]) -> Bool {
        reactions.contains { resolvedReactionNames.contains(normalize($0.name)) }
    }

    static func hasOpenReaction(_ reactions: [SlackReaction]) -> Bool {
        reactions.contains { openReactionNames.contains(normalize($0.name)) }
    }

    static func hasResolvedTextEmoji(_ text: String) -> Bool {
        resolvedTextEmoji.contains { text.contains($0) }
    }

    static func hasOpenTextEmoji(_ text: String) -> Bool {
        openTextEmoji.contains { text.contains($0) }
    }

    private static func normalize(_ name: String) -> String {
        name
            .trimmingCharacters(in: CharacterSet(charactersIn: ":").union(.whitespacesAndNewlines))
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }
}
