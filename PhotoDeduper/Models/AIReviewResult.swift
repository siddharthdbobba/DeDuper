import SwiftUI

enum AIProvider: String, CaseIterable, Identifiable, Hashable {
    case claude = "claude"
    case openai = "openai"
    case groq   = "groq"
    /// Bundled GPT-4.1 mini via the developer-hosted Cloudflare proxy.
    /// No user API key required.
    case proxy  = "proxy"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .openai: "ChatGPT"
        case .groq:   "Groq"
        case .proxy:  "GPT-4.1 mini"
        }
    }

    var systemImage: String {
        switch self {
        case .claude: "sparkles"
        case .openai: "bubble.left.and.bubble.right.fill"
        case .groq:   "bolt.fill"
        case .proxy:  "wand.and.stars"
        }
    }

    var accentColor: Color {
        switch self {
        case .claude: .purple
        case .openai: .mint
        case .groq:   .orange
        case .proxy:  .blue
        }
    }

    /// True for providers that require the user to supply their own API key.
    var requiresUserKey: Bool { self != .proxy }
}

struct AIReviewResult {
    let winnerIndex: Int   // index into the PhotoGroup.items array
    let reason: String
    let provider: AIProvider
}

enum ReviewerError: LocalizedError {
    case noAPIKey
    case imageLoadFailed
    case parseFailed
    case httpError(Int, String?)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:           return "No API key configured. Add it in Settings."
        case .imageLoadFailed:    return "Could not load photos for comparison."
        case .parseFailed:        return "Could not parse the AI response."
        case .httpError(let code, let detail):
            if let detail, !detail.isEmpty {
                return "API request failed (\(code)): \(detail)"
            }
            return "API request failed with status \(code)."
        }
    }
}
