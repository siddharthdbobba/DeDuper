# ViewModels

## Files

### `ReviewViewModel.swift`
`@MainActor` `ObservableObject` — the single source of truth for the entire app.

#### Key types defined here

**`PhotoGroup`** — one duplicate cluster:
- `items: [PhotoItem]` — all photos in the group
- `scores: [Double]` — raw quality scores from `PhotoScorer` (preserved for close-call logic)
- `displayScores: [Double]` — computed; min-max normalised to `[0.50, 0.97]` for display. Only stretches when `score.max - score.min > 0.001`; otherwise returns raw scores unchanged.
- `proposedKeeperIndex` — best index by raw score (overwritten by AI review if Claude runs)
- `userSelectedKeeperIndex` — set when the user manually taps a photo
- `keeperIndex` — `userSelectedKeeperIndex ?? proposedKeeperIndex`
- `isCloseCall` — true when top two raw scores are within `closeCallThreshold`%
- `aiReviews: [String: AIReviewResult]` — keyed by `AIProvider.rawValue`

**`ScanState`** — drives `ContentView` navigation:
```
idle → scanning(progress, message) → reviewing / error(message)
                                  → done(keptCount, deletedCount, freedBytes)
```

#### Entry points (called from views)

| Method | Trigger |
|--------|---------|
| `startScan()` | Scan full Photos library |
| `startAlbumScan(album:)` | Scan a specific album |
| `startFolderScan(url:)` | Scan a local folder |
| `requestAIReview(groupID:provider:)` | On-demand AI review of one group |
| `overrideKeeper(groupID:itemIndex:)` | User picks a different keeper |
| `acceptAISuggestion(groupID:provider:)` | Apply AI winner to `userSelectedKeeperIndex` |
| `confirmDelete()` | Execute deletion via `BatchDeleteManager` |
| `reset()` | Return to idle |

#### Scan pipeline (`runPipeline`)

1. `SimilarityGrouper.groupByTime` — time window grouping
2. `SimilarityGrouper.verifyVisualSimilarity` — dHash filtering
3. `PhotoScorer.scoreGroup` — quality scoring per group
4. If Claude key is present: parallel `ClaudeReviewer.review` for all close-call groups
