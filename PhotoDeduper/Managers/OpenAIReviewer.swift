import Foundation
import ImageIO

struct OpenAIReviewer {

    func review(items: [PhotoItem], scores: [Double]) async throws -> AIReviewResult {
        guard let apiKey = KeychainHelper.retrieve(key: "openai_api_key"), !apiKey.isEmpty else {
            throw ReviewerError.noAPIKey
        }

        // Top candidates by score, up to 6 so larger burst groups aren't silently truncated.
        let candidateIndices = Array(
            scores.indices.sorted { scores[$0] > scores[$1] }.prefix(6)
        )

        var imageContents: [[String: Any]] = []
        for originalIndex in candidateIndices {
            guard let img = await PhotoLibraryManager.loadThumbnail(
                    for: items[originalIndex],
                    size: CGSize(width: 800, height: 800)),
                  let b64 = jpegBase64(img) else {
                throw ReviewerError.imageLoadFailed
            }
            imageContents.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(b64)", "detail": "high"]
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

        var messageContent: [[String: Any]] = imageContents
        messageContent.append(["type": "text", "text": prompt])

        let body: [String: Any] = [
            "model": "gpt-4o",
            "max_tokens": 300,
            "messages": [["role": "user", "content": messageContent]]
        ]

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions"),
              let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            throw ReviewerError.parseFailed
        }

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ReviewerError.httpError(http.statusCode, GroqReviewer.extractAPIError(from: data))
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String,
              let textData = text.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: textData) as? [String: Any],
              let winner1Based = result["winner"] as? Int else {
            throw ReviewerError.parseFailed
        }
        let reason = String((result["reason"] as? String ?? "").prefix(500))

        let position = min(max(winner1Based - 1, 0), candidateIndices.count - 1)
        let winnerIndex = candidateIndices[position]
        return AIReviewResult(winnerIndex: winnerIndex, reason: reason, provider: .openai)
    }

    private func jpegBase64(_ image: CGImage) -> String? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data).base64EncodedString()
    }
}
