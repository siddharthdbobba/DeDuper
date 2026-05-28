# Utilities

## Files

### `KeychainHelper.swift`
Static wrapper around `Security.framework` for storing API keys in the system Keychain.

**Security properties applied to every item:**
- `kSecAttrService` — set to `Bundle.main.bundleIdentifier`, scoping items to this app
- `kSecAttrAccount` — the key name (e.g. `"claude_api_key"`)
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — accessible only when the device is unlocked; **excluded from iCloud and local backups**; not transferable to another device; hardware-backed on Apple Silicon
- Uses a delete-then-add pattern in `save` to avoid `errSecDuplicateItem`

**API:**
```swift
KeychainHelper.save(key:value:)          // delete-then-add
KeychainHelper.retrieve(key:)            // returns nil if not found
KeychainHelper.delete(key:)
KeychainHelper.deleteLegacyFileStorage() // one-time migration: removes old plaintext Keys/ dir
```

**Keys in use:**
- `"claude_api_key"` — Anthropic API key
- `"openai_api_key"` — OpenAI API key
- `"groq_api_key"` — Groq API key
