# Utilities

## Files

### `KeychainHelper.swift`
The app no longer stores any secrets (the AI-key and license-key features were
removed), so the generic Keychain `save`/`retrieve`/`has`/`delete` API has been
deleted along with its `Security.framework` dependency.

What remains is a one-time, launch-time cleanup:

```swift
KeychainHelper.deleteLegacyFileStorage() // removes the old plaintext Keys/ dir, if any
```

`deleteLegacyFileStorage()` (and its private `wipeFile(at:)` helper) use only
`Foundation` (`FileManager`/`URL`/`Data`) to purge an old on-disk key store left
by earlier versions. It is invoked once from `PhotoDeduperApp` at startup.
