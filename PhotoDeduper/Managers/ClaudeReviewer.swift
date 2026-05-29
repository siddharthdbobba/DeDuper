import Foundation

struct ClaudeReviewer {

    func review(items: [PhotoItem], scores: [Double]) async throws -> AIReviewResult {
        guard let apiKey = KeychainHelper.retrieve(key: "claude_api_key"), !apiKey.isEmpty else {
            throw ReviewerError.noAPIKey
        }

        // Top candidates by score, up to 6 so larger burst groups aren't silently truncated.
        let candidateIndices = Array(
            scores.indices.sorted { scores[$0] > scores[$1] }.prefix(6)
        )

        var imageBlocks: [[String: Any]] = []
        for originalIndex in candidateIndices {
            guard let img = await PhotoLibraryManager.loadThumbnail(
                    for: items[originalIndex],
                    size: CGSize(width: 800, height: 800)),
                  let b64 = img.jpegBase64(quality: 0.9) else {
                throw ReviewerError.imageLoadFailed
            }
            imageBlocks.append([
                "type": "image",
                "source": ["type": "base64", "media_type": "image/jpeg", "data": b64]
            ])
        }

        let count = candidateIndices.count
        let prompt = """
        These are \(count) similar photos taken close together, numbered 1 through \(count) in the order shown.
        Choose the one with the best overall quality based on (in priority order):

        1. Eye state (if people are present) — eyes fully open and engaged. Half-blinks and closed eyes are near-disqualifying.

        2. Expression and timing — for people, is the expression at its peak (genuine, settled) or caught mid-transition (mid-word, mid-laugh, mid-chew)? For action, is the peak moment captured (apex of motion, point of contact)?

        3. Sharpness on the critical area — for portraits, the EYES must be sharp (not ears, hair, or background). For action, the contact point or face. For landscapes, the intended focal plane. Note whether softness is motion blur (subject moved), camera shake (whole frame smeared), or missed focus (wrong plane).

        4. Exposure — blown highlights (pure white without detail), crushed shadows (pure black without detail), or unnatural color cast. Burst shots usually share exposure, so flag only meaningful differences.

        5. Hand and posture — natural vs frozen mid-awkward-gesture.

        Composition and noise are generally consistent across burst frames; mention them only if a frame meaningfully differs (subject drifted, ISO bumped, etc.).

        Reply with ONLY valid JSON, no markdown: {"winner": 1, "reason": "concise explanation"} \
        where winner is the 1-based index of the best photo.
        """

        var messageContent: [[String: Any]] = imageBlocks
        messageContent.append(["type": "text", "text": prompt])

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 300,
            "messages": [["role": "user", "content": messageContent]]
        ]

        guard let url = URL(string: "https://api.anthropic.com/v1/messages"),
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            throw ReviewerError.parseFailed
        }

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: req)
        // Defensive cap — Claude responses are <2 KB in practice. Refusing
        // anything beyond 1 MB prevents a misbehaving / hijacked endpoint
        // from forcing us to parse arbitrary-sized JSON.
        guard data.count <= 1_048_576 else {
            throw ReviewerError.parseFailed
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ReviewerError.httpError(http.statusCode, GroqReviewer.extractAPIError(from: data))
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (json["content"] as? [[String: Any]])?.first,
              let text = content["text"] as? String,
              let textData = text.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: textData) as? [String: Any],
              let winner1Based = result["winner"] as? Int else {
            throw ReviewerError.parseFailed
        }
        let reason = String((result["reason"] as? String ?? "").prefix(500))

        let position = min(max(winner1Based - 1, 0), candidateIndices.count - 1)
        let winnerIndex = candidateIndices[position]
        return AIReviewResult(winnerIndex: winnerIndex, reason: reason, provider: .claude)
    }
}
