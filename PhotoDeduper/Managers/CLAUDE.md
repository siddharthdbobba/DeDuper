# Managers

All I/O, computation, and external API calls. No SwiftUI imports except where unavoidable.

## Files

### `PhotoLibraryManager.swift`
Wraps `Photos.framework` and `FileManager`.

- `requestAuthorization()` — requests `.readWrite` Photos permission
- `fetchAllPhotos()` / `fetchPhotos(from:)` / `fetchAlbums()` — Photos library queries
- `scanFolder(_:)` — recursive file-system scan using security-scoped resource access; filters by `PhotoItem.imageExtensions`
- `loadThumbnail(for:size:)` — async thumbnail loader; dispatches to `PHImageManager` (assets) or `CGImageSourceCreateThumbnailAtIndex` (files)

### `SimilarityGrouper.swift`
Two-stage duplicate detection:

1. **`groupByTime(_:windowSeconds:)`** — groups photos whose creation dates fall within `windowSeconds` of each other (default 30 s)
2. **`verifyVisualSimilarity(_:threshold:progress:)`** — computes a 64-bit difference hash (dHash) for each photo and keeps only pairs within `threshold` Hamming-distance bits (default 15)

### `PhotoScorer.swift`
On-device quality scorer. Returns a `[Double]` in `[0, 1]` for each item in a group.

- **Sharpness** (`computeSharpness`): applies `CIEdges`, then measures both mean (`CIAreaAverage`) and peak (`CIAreaMaximum`) edge intensity. Formula: `min(mean * 5 + peak * 2.5, 1.0)`. Peak is more discriminating than mean for burst shots.
- **Exposure** (`computeExposure`): 256-bucket histogram via `CIAreaHistogram`; penalises underexposed (<10) and overexposed (>245) pixel fractions.
- **Final score**: `0.7 * sharpness + 0.3 * exposure`
- Scores are **not** normalised here — normalisation for display happens in `PhotoGroup.displayScores`.

### `ClaudeReviewer.swift`
Calls `POST https://api.anthropic.com/v1/messages` with `claude-opus-4-7`.

- Sends up to 4 top-scoring photos as base64 JPEG (800 px, 0.8 quality)
- Parses `{"winner": N, "reason": "..."}` from the response text
- Validates HTTP status (throws `ReviewerError.httpError` on non-2xx)
- Caps `reason` at 500 characters
- API key retrieved from Keychain via `KeychainHelper`

### `OpenAIReviewer.swift`
Calls `POST https://api.openai.com/v1/chat/completions` with `gpt-4o`. Same contract as `ClaudeReviewer` but uses `image_url` with a data-URI instead of Anthropic's `source` block.

### `BatchDeleteManager.swift`
Handles deletion for both asset types:

- `PHAsset` items → `PHAssetChangeRequest.deleteAssets` (moves to Recently Deleted, recoverable 30 days)
- File URLs → `FileManager.trashItem` (moves to macOS Trash)
