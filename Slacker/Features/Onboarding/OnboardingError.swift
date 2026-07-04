import Foundation

/// Maps low-level errors to actionable, friendly copy (§5.3 — never a dead end).
enum OnboardingError {
    static func message(for error: Error) -> String {
        if let slack = error as? SlackClientError {
            switch slack {
            case .api(let code):
                return apiMessage(code)
            case .http(let status):
                return "Slack returned an unexpected error (HTTP \(status)). Please try again in a moment."
            case .rateLimited:
                return "Slack is rate-limiting requests. Wait a minute and try again."
            case .nonHTTPResponse, .decoding:
                return "Got an unexpected response from Slack. Please try again."
            }
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return "Couldn't reach Slack. Check your internet connection and try again."
        }
        return "Something went wrong. Please try again."
    }

    private static func apiMessage(_ code: String) -> String {
        switch code {
        case "invalid_auth", "not_authed", "token_revoked", "token_expired":
            return "That token didn't work. Make sure you pasted the full user token (starts with \"xoxp-\")."
        case "account_inactive":
            return "That Slack account is inactive. Sign in to the right workspace and reinstall the app."
        case "missing_scope", "no_permission":
            return "The token is missing a required scope. Reinstall the Slack app from the manifest and try again."
        default:
            return "Slack rejected the request (\(code)). Double-check the token and workspace."
        }
    }
}
