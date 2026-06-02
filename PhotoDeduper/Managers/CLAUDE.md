# Managers

All I/O and on-device computation. No network access. No SwiftUI imports except where unavoidable.

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
- Scores are **not** normalised; `PhotoGroup.displayScores` returns them unchanged for display.

> Close-call ties are broken on-device by `ReviewViewModel.resolveCloseCallLocally`
> (Vision face/aesthetics signals). There is no network/LLM reviewer.

### `BatchDeleteManager.swift`
Handles deletion for both asset types:

- `PHAsset` items → `PHAssetChangeRequest.deleteAssets` (moves to Recently Deleted, recoverable 30 days)
- File URLs → `FileManager.trashItem` (moves to macOS Trash)
