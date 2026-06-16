# ViewModels

## Files

### `ReviewViewModel.swift`
`@MainActor` `ObservableObject` — the single source of truth for the entire app.

#### Key types defined here

**`PhotoGroup`** — one duplicate cluster:
- `items: [PhotoItem]` — all photos in the group
- `scores: [Double]` — raw quality scores from `PhotoScorer` (preserved for close-call logic)
- `displayScores: [Double]` — computed; currently returns `scores` unchanged (the scorer's normalization already provides meaningful spread)
- `proposedKeeperIndex` — best index by raw score (may be promoted to a protected item)
- `keptIndices: Set<Int>` — the set of indices to keep; everything else is proposed for deletion
- `isCloseCall` — true when top two raw scores are within `closeCallThreshold`%
- `localExplanation: String?` — on-device "Why this one?" reason when the Vision resolver breaks a close call

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
| `selectKeeper(groupID:itemIndex:)` | User picks the keeper for a group |
| `toggleKeep(groupID:itemIndex:)` | Toggle an individual photo in/out of the keep set |
| `stageGroup(groupID:)` | Move a group from `groups` to `stagedGroups` — local only, no PhotoKit/file I/O (`d` key, "Stage N" button) |
| `restoreStagedGroups()` | Move all staged groups back into `groups` (sidebar "Restore") |
| `confirmDelete()` | Flush staged + remaining groups in ONE `BatchDeleteManager` call → one macOS delete prompt per session |
| `reset()` | Return to idle |

#### Staging model ("mark, then flush")

Per-group actions only *stage* groups into `stagedGroups`; nothing is deleted
until `confirmDelete()` flushes everything in a single PhotoKit request. This
keeps the unavoidable macOS "Allow PhotoDeduper to delete N photos?" prompt to
one per session instead of one per group. `totalToDelete` /
`estimatedFreedBytes` span both collections; `reset()`, `cancelScan()`, and a
new scan clear `stagedGroups`.

#### Scan pipeline (`runPipeline`)

1. `SimilarityGrouper.groupByTime` — time window grouping
2. `SimilarityGrouper.verifyVisualSimilarity` — dHash filtering
3. `PhotoScorer.evaluateGroup` — quality scoring per group
4. `resolveCloseCallLocally` — on-device Vision tie-break for close-call groups (no network/AI)
