import Foundation

/// Display data for one attention/review item: the item plus its channel, snippet,
/// and author, assembled for the list UI (§8.2).
struct ItemRow: Identifiable, Equatable {
    let item: Item
    let channelName: String
    let channelID: String
    /// Owning workspace (team id) — used to build the deep link to the right workspace.
    let teamID: String
    let snippet: String
    let authorName: String?
    /// Number of replies in the thread (responses since the root).
    let responseCount: Int
    /// LLM thread summary for this open item, if generated yet.
    let threadSummary: String?

    init(
        item: Item,
        channelName: String,
        channelID: String,
        teamID: String,
        snippet: String,
        authorName: String?,
        responseCount: Int = 0,
        threadSummary: String? = nil
    ) {
        self.item = item
        self.channelName = channelName
        self.channelID = channelID
        self.teamID = teamID
        self.snippet = snippet
        self.authorName = authorName
        self.responseCount = responseCount
        self.threadSummary = threadSummary
    }

    var id: String { item.id }
    var type: ItemType { item.type }
    var confidence: Double { item.confidence }

    /// Human-readable age based on the Slack message timestamp (not observation time).
    func ageText(now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince1970 - (Double(item.rootMessageTS) ?? now.timeIntervalSince1970)
        let hours = Int(seconds / 3600)
        if hours < 1 { return "just now" }
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    /// `slack://` deep link to the exact thread (§8.2). Opens the channel/thread in Slack.
    func deepLink() -> URL? {
        var components = URLComponents()
        components.scheme = "slack"
        components.host = "channel"
        components.queryItems = [
            URLQueryItem(name: "team", value: teamID),
            URLQueryItem(name: "id", value: channelID),
            URLQueryItem(name: "message", value: item.rootMessageTS),
        ]
        return components.url
    }
}
