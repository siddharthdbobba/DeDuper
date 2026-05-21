# Utilities

## Files

### `KeychainHelper.swift`
Static wrapper around `Security.framework` for storing API keys.

**Security properties applied to every item:**
- `kSecAttrService` — set to `Bundle.main.bundleIdentifier`, scoping items to this app
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — only accessible when the Mac is unlocked; **excluded from iCloud and local backups**; not transferable to another device

**API:**
```swift
KeychainHelper.save(key:value:)    // delete-then-add pattern
KeychainHelper.retrieve(key:)      // returns nil if not found
KeychainHelper.delete(key:)
```

**Keys in use:**
- `"claude_api_key"` — Anthropic API key
- `"openai_api_key"` — OpenAI API key

> **Migration note:** Items saved before the service attribute was added will not be found by `retrieve` because they lack the `kSecAttrService` attribute. Users will need to re-enter keys once after upgrading.
