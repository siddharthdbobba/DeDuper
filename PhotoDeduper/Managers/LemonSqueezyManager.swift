import Foundation

/// Manages LemonSqueezy license key activation, validation, and deactivation
/// for direct-distribution builds.
///
/// LemonSqueezy's Licenses API is intentionally public — no API token is needed
/// from the client. The license key itself is the credential.
///
/// Keychain keys used:
///   "ls_license_key"   — raw key string stored after successful activation
///   "ls_instance_id"   — UUID assigned by LemonSqueezy, required for validate/deactivate
@MainActor
final class LemonSqueezyManager {

    static let shared = LemonSqueezyManager()
    private init() {}

    private let baseURL = "https://api.lemonsqueezy.com/v1/licenses"

    static let licenseKeychainKey  = "ls_license_key"
    static let instanceKeychainKey = "ls_instance_id"

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
    }

    /// Validates the stored license key against LemonSqueezy.
    /// Returns `true` on success **or** on network failure (offline grace).
    /// Returns `false` only when LemonSqueezy explicitly says the key is invalid.
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
            return response.valid
        } catch LemonSqueezyError.networkError {
            return true   // benefit of the doubt when offline
        } catch {
            return false
        }
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
            let (data, _) = try await URLSession.shared.data(for: req)
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
