import Foundation
import CryptoKit
import Security

/// Manages LemonSqueezy license key activation, validation, and deactivation
/// for direct-distribution builds.
///
/// LemonSqueezy's Licenses API is intentionally public — no API token is needed
/// from the client. The license key itself is the credential.
///
/// Keychain keys used:
///   "ls_license_key"        — raw key string stored after successful activation
///   "ls_instance_id"        — UUID assigned by LemonSqueezy, required for validate/deactivate
///   "ls_last_validated_at"  — UNIX timestamp (String) of the last successful, valid validation
///   "ls_last_known_valid"   — "1" if the last decoded response said valid, "0" if it said invalid
@MainActor
final class LemonSqueezyManager {

    static let shared = LemonSqueezyManager()
    private init() {}

    private let baseURL = "https://api.lemonsqueezy.com/v1/licenses"

    static let licenseKeychainKey        = "ls_license_key"
    static let instanceKeychainKey       = "ls_instance_id"
    static let lastValidatedKeychainKey  = "ls_last_validated_at"
    static let lastKnownValidKeychainKey = "ls_last_known_valid"

    /// How long a previously-valid license stays usable while validation can't
    /// reach a definitive server answer (offline / transient failure / pin miss).
    private static let graceWindow: TimeInterval = 7 * 24 * 60 * 60

    /// Pinned URLSession: TLS certificate pinning for api.lemonsqueezy.com.
    /// Created once; `PinnedSessionDelegate` enforces the pin on every request.
    private lazy var session = URLSession(
        configuration: .ephemeral,
        delegate: PinnedSessionDelegate(),
        delegateQueue: nil
    )

    // MARK: - Public

    /// Activates `licenseKey` for this machine.
    /// Stores the key and instance ID in Keychain on success.
    func activate(licenseKey: String) async throws {
        let clean = licenseKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !clean.isEmpty else { throw LemonSqueezyError.invalidKey }

        let body: [String: String] = [
            "license_key":   clean,
            "instance_name": machineName()
        ]
        let data = try await call(method: "POST", path: "activate", body: body)
        let response = try decoded(ActivationResponse.self, from: data)

        guard response.activated else {
            throw LemonSqueezyError.from(response.error)
        }
        guard let instanceID = response.instance?.id else {
            throw LemonSqueezyError.serverError("No instance ID returned.")
        }

        KeychainHelper.save(key: Self.licenseKeychainKey,  value: clean)
        KeychainHelper.save(key: Self.instanceKeychainKey, value: instanceID)

        // A successful activation is itself definitive proof of validity — seed
        // the grace keys so a user who goes offline (or hits a TLS-pin miss)
        // before the first validate() isn't locked out by withinGraceWindow()'s
        // fail-closed default.
        let now = String(Int(Date().timeIntervalSince1970))
        KeychainHelper.save(key: Self.lastValidatedKeychainKey,  value: now)
        KeychainHelper.save(key: Self.lastKnownValidKeychainKey, value: "1")
    }

    /// Validates the stored license key against LemonSqueezy.
    ///
    /// Unified validation policy:
    /// - A definitive server answer is always honored. If LemonSqueezy explicitly
    ///   says the key is **invalid**, premium locks immediately — no grace.
    /// - When validation can't get a definitive answer (offline, a server/decode
    ///   hiccup, or a TLS-pin failure), a previously-valid license keeps working
    ///   for a 7-day offline grace window measured from the last successful,
    ///   *valid* validation. After the window lapses with no successful
    ///   validation, premium locks.
    func validate() async -> Bool {
        guard
            let key        = KeychainHelper.retrieve(key: Self.licenseKeychainKey),
            let instanceID = KeychainHelper.retrieve(key: Self.instanceKeychainKey)
        else { return false }

        do {
            let body: [String: String] = [
                "license_key": key,
                "instance_id": instanceID
            ]
            let data = try await call(method: "POST", path: "validate", body: body)
            let response = try decoded(ValidationResponse.self, from: data)

            if response.valid {
                let now = String(Int(Date().timeIntervalSince1970))
                KeychainHelper.save(key: Self.lastValidatedKeychainKey,  value: now)
                KeychainHelper.save(key: Self.lastKnownValidKeychainKey, value: "1")
                return true
            } else {
                // Explicit revocation locks immediately; the grace window does not apply.
                KeychainHelper.save(key: Self.lastKnownValidKeychainKey, value: "0")
                return false
            }
        } catch {
            // Any thrown error (network, server/decode, or TLS-pin failure) falls
            // back to the offline grace window rather than revoking a paying user.
            return withinGraceWindow()
        }
    }

    /// Returns `true` iff the last decoded response was valid and that validation
    /// happened within `graceWindow` of now. A never-validated key (no stored
    /// timestamp) and an unparseable timestamp both fail closed.
    private func withinGraceWindow() -> Bool {
        guard
            KeychainHelper.retrieve(key: Self.lastKnownValidKeychainKey) == "1",
            let stamp = KeychainHelper.retrieve(key: Self.lastValidatedKeychainKey),
            let lastValidatedAt = TimeInterval(stamp)
        else { return false }

        return (Date().timeIntervalSince1970 - lastValidatedAt) < Self.graceWindow
    }

    /// Deactivates the stored license for this machine and wipes Keychain.
    /// Clears locally even if the server call fails.
    func deactivate() async throws {
        guard
            let key        = KeychainHelper.retrieve(key: Self.licenseKeychainKey),
            let instanceID = KeychainHelper.retrieve(key: Self.instanceKeychainKey)
        else { return }

        let body: [String: String] = [
            "license_key": key,
            "instance_id": instanceID
        ]
        _ = try? await call(method: "DELETE", path: "deactivate", body: body)

        KeychainHelper.delete(key: Self.licenseKeychainKey)
        KeychainHelper.delete(key: Self.instanceKeychainKey)
        // Clear grace state too, so a later reactivation can't ride this
        // license's stale last-known-valid timestamp.
        KeychainHelper.delete(key: Self.lastValidatedKeychainKey)
        KeychainHelper.delete(key: Self.lastKnownValidKeychainKey)
    }

    /// Whether a license key is stored in Keychain (doesn't re-validate).
    var hasStoredKey: Bool {
        KeychainHelper.has(key: Self.licenseKeychainKey)
    }

    /// Masked key for display, e.g. `"AABB-••••-••••-••••"`.
    var maskedKey: String? {
        guard let key = KeychainHelper.retrieve(key: Self.licenseKeychainKey) else { return nil }
        let parts = key.split(separator: "-")
        guard parts.count > 1 else { return key }
        let hidden = (1..<parts.count).map { _ in "••••" }.joined(separator: "-")
        return "\(parts[0])-\(hidden)"
    }

    // MARK: - Networking

    private func call(method: String, path: String, body: [String: String]) async throws -> Data {
        guard let url = URL(string: "\(baseURL)/\(path)") else {
            throw LemonSqueezyError.serverError("Malformed URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod  = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody    = try JSONEncoder().encode(body)

        do {
            let (data, _) = try await session.data(for: req)
            return data
        } catch {
            throw LemonSqueezyError.networkError(error)
        }
    }

    private func decoded<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try dec.decode(type, from: data)
        } catch {
            throw LemonSqueezyError.serverError("Unexpected response format.")
        }
    }

    private func machineName() -> String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "iPhone"
        #endif
    }

    // MARK: - Response models

    private struct ActivationResponse: Decodable {
        let activated: Bool
        let error: String?
        let instance: Instance?
        struct Instance: Decodable { let id: String }
    }

    private struct ValidationResponse: Decodable {
        let valid: Bool
        let error: String?
    }
}

// MARK: - TLS certificate pinning

/// Enforces certificate pinning for api.lemonsqueezy.com.
///
/// The pinned values are **full-certificate DER SHA-256 digests** (base64), not
/// SPKI hashes — i.e. `base64(SHA256(SecCertificateCopyData(cert)))`. A handshake
/// is accepted only if it passes default trust evaluation *and* at least one
/// certificate in the presented chain matches a pin.
///
/// Refreshing pins when the chain rotates: leaf certificates rotate often
/// (~90 days for Google Trust Services), so the durable pin is the intermediate
/// (Google Trust Services WE1). To regenerate, capture the live DER for each cert
/// and run `openssl x509 -inform DER -in cert.der -outform DER | openssl dgst -sha256 -binary | base64`.
/// See SECURITY_FIXES_PLAN.md for the full rotation runbook.
///
/// Not `@MainActor`: URLSession invokes the delegate on a background queue.
private final class PinnedSessionDelegate: NSObject, URLSessionDelegate {

    /// Full-certificate DER SHA-256 pins (base64).
    private static let pinnedCertHashes: Set<String> = [
        "DSBPplLAHWrv9JDYzl8B6S1GoUpryDWPx3lu8xeBooo=", // leaf CN=lemonsqueezy.com
        "HfwWBfutNY2LyET3bRUgP6ycpcGnn9SFf/ryhk++v5Y="  // intermediate Google Trust Services WE1 (durable across leaf rotation)
    ]

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Default validation first: chain to a trusted root, hostname, expiry, etc.
        guard SecTrustEvaluateWithError(serverTrust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        for cert in chain {
            let der = SecCertificateCopyData(cert) as Data
            let hash = Data(SHA256.hash(data: der)).base64EncodedString()
            if Self.pinnedCertHashes.contains(hash) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }

        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

// MARK: - Error

enum LemonSqueezyError: LocalizedError {
    case invalidKey
    case activationLimitReached
    case expired
    case disabled
    case networkError(Error)
    case serverError(String)

    static func from(_ message: String?) -> LemonSqueezyError {
        let msg = message?.lowercased() ?? ""
        if msg.contains("limit")                        { return .activationLimitReached }
        if msg.contains("expired")                      { return .expired }
        if msg.contains("disabled")                     { return .disabled }
        if msg.contains("invalid") || msg.contains("not found") { return .invalidKey }
        return .serverError(message ?? "Activation failed.")
    }

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "Invalid license key. Check your purchase email and try again."
        case .activationLimitReached:
            return "Activation limit reached. Deactivate another Mac in Settings first."
        case .expired:
            return "This license key has expired."
        case .disabled:
            return "This license key has been disabled. Contact support."
        case .networkError:
            return "Network error. Check your connection and try again."
        case .serverError(let msg):
            return msg
        }
    }
}
