# Utilities

## Files

### `KeychainHelper.swift`
Static wrapper around `Security.framework` for storing small secrets in the system Keychain.
The app no longer stores API or license keys; the only live use is
`deleteLegacyFileStorage()` at launch (a one-time cleanup of an old plaintext key store).
The generic `save`/`retrieve`/`delete` API is retained for completeness.

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

No keys are written by the app anymore (the AI-key and license-key features were removed).
`deleteLegacyFileStorage()` runs once at launch to purge any old on-disk key store.
