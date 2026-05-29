import Foundation
import CryptoKit

/// Sends photo comparison requests to the developer-hosted Cloudflare Worker
/// proxy, which holds the real OpenAI key server-side.
///
/// The request is identical in shape to the OpenAI chat completions API, but
/// instead of an `Authorization: Bearer <key>` header, two auth headers are
/// added:
///
///   X-Timestamp  — Unix epoch seconds (string)
///   X-Signature  — HMAC-SHA256 over (timestamp + "." + hex(SHA256(body)))
///
/// The proxy verifies the signature, rate-limits per IP, then reconstructs
/// the outbound body with `model` and `max_tokens` hardcoded server-side.
struct ProxyReviewer {

    func review(items: [PhotoItem], scores: [Double]) async throws -> AIReviewResult {
        // Top candidates by score, up to 6.
        let candidateIndices = Array(
            scores.indices.sorted { scores[$0] > scores[$1] }.prefix(6)
        )

        var imageContents: [[String: Any]] = []
        for originalIndex in candidateIndices {
            guard let img = await PhotoLibraryManager.loadThumbnail(
                    for: items[originalIndex],
                    size: CGSize(width: 800, height: 800)),
                  let b64 = img.jpegBase64(quality: 0.9) else {
                throw ReviewerError.imageLoadFailed
            }
            // OpenAI image_url format — omit "detail" so the proxy's sanitizer
            // doesn't need to strip it.
            imageContents.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(b64)"]
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

        // Note: "model" is included so the body is valid OpenAI JSON, but the
        // proxy IGNORES it and hardcodes gpt-4.1-mini server-side.
        let body: [String: Any] = [
            "model": "gpt-4.1-mini",
            "max_tokens": 300,
            "messages": [["role": "user", "content": messageContent]]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            throw ReviewerError.parseFailed
        }

        let req = try buildSignedRequest(body: bodyData)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard data.count <= 1_048_576 else { throw ReviewerError.parseFailed }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                throw ReviewerError.httpError(429, "AI review rate limit reached. Try again later.")
            }
            if !(200...299).contains(http.statusCode) {
                throw ReviewerError.httpError(http.statusCode,
                    GroqReviewer.extractAPIError(from: data))
            }
        }

        // Parse OpenAI-shaped response: choices[0].message.content
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
        return AIReviewResult(winnerIndex: winnerIndex, reason: reason, provider: .proxy)
    }

    // MARK: - Request signing

    /// Builds a URLRequest with HMAC-SHA256 authentication headers.
    ///
    /// Signed string: `timestamp + "." + lowercase_hex(SHA256(body))`
    private func buildSignedRequest(body: Data) throws -> URLRequest {
        let timestamp = String(Int(Date().timeIntervalSince1970))

        // SHA-256 the body, hex-encode it
        let bodyDigest = SHA256.hash(data: body)
        let bodyHex = bodyDigest.map { String(format: "%02x", $0) }.joined()

        // HMAC-SHA256 over "timestamp.bodyHex"
        let signedStr = Data((timestamp + "." + bodyHex).utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: signedStr, using: AppConfig.hmacSecret)
        let signature = mac.map { String(format: "%02x", $0) }.joined()

        var req = URLRequest(url: AppConfig.proxyChatURL, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
        req.setValue(signature,  forHTTPHeaderField: "X-Signature")
        req.setValue(AppConfig.appVersion, forHTTPHeaderField: "X-App-Version")
        req.httpBody = body
        return req
    }
}
