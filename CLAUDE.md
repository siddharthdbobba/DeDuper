# PhotoDeduper

A macOS SwiftUI app that finds and removes duplicate/similar photos from your Photos library or a local folder.

## Build & Run

Open `PhotoDeduper.xcodeproj` in Xcode and run the `PhotoDeduper` scheme. Requires macOS with Photos framework support.

There is no package manager (no SPM, no CocoaPods). All dependencies are Apple system frameworks.

## Project Layout

```
PhotoDeduper/          ← Xcode project file
PhotoDeduper/          ← Main Swift source target
  App/                 ← App entry point and root view
  Managers/            ← Business logic: photo library, scoring, grouping, deletion, AI review
  Models/              ← Plain data types: PhotoItem, PhotoAlbum, AIReviewResult
  Utilities/           ← KeychainHelper
  ViewModels/          ← ReviewViewModel (central state machine)
  Views/               ← All SwiftUI views
```

## Architecture

- **Single ViewModel**: `ReviewViewModel` drives the entire scan→review→delete lifecycle via a `ScanState` enum published to SwiftUI views.
- **PhotoItem** is a unified representation for both `PHAsset` (Photos library) and file-URL-based images.
- **Pipeline** (in `ReviewViewModel.runPipeline`): fetch → time-group (`SimilarityGrouper`) → visual hash verify → score (`PhotoScorer`) → optional AI close-call review (`ClaudeReviewer`).
- **AI keys** are stored in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (not backed up). Keys are scoped by bundle ID via `kSecAttrService`.

## Entitlements

- `com.apple.security.app-sandbox` — sandboxed
- `com.apple.security.personal-information.photos-library` — Photos access
- `com.apple.security.network.client` — outbound network (AI APIs)
- `com.apple.security.files.user-selected.read-write` — folder scanning via security-scoped bookmarks

## AI Integration

- **Claude** (`ClaudeReviewer`): called automatically during scanning for close-call groups (scores within `closeCallThreshold`%). Also available on-demand per group.
- **OpenAI GPT-4o** (`OpenAIReviewer`): on-demand only.
- Both reviewers validate HTTP status codes before parsing and cap the returned `reason` string at 500 characters.

## Key Settings (stored in UserDefaults)

| Key | Default | Meaning |
|-----|---------|---------|
| `timeWindow` | 30s | Photos taken within this window are grouped as candidates |
| `pHashThreshold` | 15 bits | Max Hamming distance for visual similarity (dHash) |
| `closeCallThreshold` | 15% | Score gap below which Claude auto-reviews |
