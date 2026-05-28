import Foundation
import CryptoKit

/// Static configuration for the bundled AI proxy.
///
/// ## Proxy URL
/// In Debug builds the app targets localhost (wrangler dev).
/// In Release builds it targets the deployed Cloudflare Worker.
/// Update the release URL before shipping.
///
/// ## HMAC secret
/// The XOR-obfuscated byte arrays below encode the shared secret that
/// authenticates app requests to the proxy. The obfuscation resists
/// `strings(1)` extraction but is NOT a true secret: a determined attacker
/// with a disassembler can recover it. The real guarantee is that the proxy
/// hardcodes the model + max_tokens and rate-limits — so extracting the
/// secret only grants access to YOUR proxy, not OpenAI directly.
///
/// To rotate the secret:
///   1. Run `python3 -c "import os; print(os.urandom(32).hex())"` → new hex
///   2. Run the keygen script in proxy/README.md to get new xorKey/masked arrays
///   3. Update wrangler secret: `wrangler secret put APP_HMAC_SECRET`
///   4. Keep the old secret in PREVIOUS_APP_HMAC_SECRET during the rollout window

enum AppConfig {

    // MARK: - Proxy URL

    /// Full URL of the /v1/chat/completions endpoint on your proxy.
    /// Debug builds point at local `wrangler dev` (port 8787).
    /// Release: replace YOUR_SUBDOMAIN with your Cloudflare account subdomain.
    static let proxyChatURL: URL = {
        #if DEBUG
        return URL(string: "http://127.0.0.1:8787/v1/chat/completions")!
        #else
        return URL(string: "https://photodeduper-proxy.siddharthdbobba.workers.dev/v1/chat/completions")!
        #endif
    }()

    // MARK: - HMAC shared secret (XOR-obfuscated)

    /// The symmetric key used to sign outbound proxy requests.
    /// Recovered at runtime by XORing `masked` with `xorKey`.
    static var hmacSecret: SymmetricKey {
        // Random mask — 32 bytes generated with /dev/urandom
        let xorKey: [UInt8] = [
            0x43, 0x25, 0x4D, 0x35, 0xF0, 0xD6, 0x95, 0x3C,
            0xDE, 0x4C, 0x73, 0x61, 0xF8, 0xD5, 0x17, 0x83,
            0x6C, 0xAB, 0x80, 0xCA, 0x18, 0x26, 0x94, 0xB1,
            0x05, 0x6C, 0xBC, 0x19, 0x02, 0x3D, 0xB7, 0xC1
        ]
        // Actual secret XOR'd with xorKey (secret = masked XOR xorKey at runtime)
        let masked: [UInt8] = [
            0x40, 0xCF, 0x2B, 0x50, 0x9A, 0x2F, 0x40, 0xD6,
            0x36, 0x07, 0x65, 0xA4, 0xD1, 0xE9, 0x03, 0x54,
            0xD0, 0x5F, 0xBE, 0x1C, 0x6E, 0x9E, 0x54, 0x93,
            0xB8, 0xB9, 0x91, 0xC2, 0xE8, 0xBF, 0xAF, 0xF1
        ]
        let rawBytes = zip(masked, xorKey).map { $0 ^ $1 }
        return SymmetricKey(data: Data(rawBytes))
    }

    // MARK: - LemonSqueezy (direct distribution)

    /// Checkout page URL — set this to your LemonSqueezy product link.
    /// Format: https://YOUR-STORE.lemonsqueezy.com/buy/PRODUCT-UUID
    static let lemonSqueezyCheckoutURL = URL(
        string: "https://deduper.lemonsqueezy.com/checkout/buy/f07ea94c-fe43-4586-ad07-f75961ee5d60"
    )!

    /// Display price shown in the paywall for direct builds.
    /// Keep in sync with your LemonSqueezy product price.
    static let directPrice = "$4.99"

    // MARK: - App version

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
