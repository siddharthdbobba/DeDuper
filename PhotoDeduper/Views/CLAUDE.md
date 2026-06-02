# Views

All SwiftUI views. No business logic; all state lives in `ReviewViewModel`.

## Files

### `SplashView.swift`
Idle/entry screen. Offers three scan modes: full library, album picker, and folder picker. Triggers `viewModel.startScan()`, `startAlbumScan()`, or `startFolderScan()`.

### `AlbumPickerView.swift`
Sheet that lists smart albums and user albums from the Photos library. Fetches album list inline (not via ViewModel) using `PhotoLibraryManager.fetchAlbums()`.

### `ScanProgressView.swift`
Shown during `.scanning` state. Displays a `ProgressView` bar and the current status message string.

### `ReviewView.swift`
Main two-pane layout shown during `.reviewing` state.

- **Sidebar**: `List` of `GroupRow` items; drives `viewModel.selectedGroupID`
- **Detail**: `GroupDetailView` for the selected group

**`GroupDetailView`** renders:
- Header with photo count, the on-device "Why this one?" explanation (if present), and Face-to-Face / Delete actions
- `LazyVGrid` of `PhotoCard` views — passes `group.displayScores[i]` (not raw scores)

### `PhotoCard.swift`
Single photo tile. Shows:
- Async thumbnail (`PhotoThumbnail`)
- Green border + "Keep" badge if `isKeeper`
- Score badge (bottom-left): `"XX.X%"` from `displayScores`
- Zoom hint icon if `onDoubleTap` is set

`PhotoThumbnail` loads asynchronously: `PHImageManager` for assets, `CGImageSourceCreateThumbnailAtIndex` for file URLs. Cancels the `PHImageRequestID` on `onDisappear`.

### `PhotoLightboxView.swift`
Full-size image viewer opened by double-clicking a `PhotoCard`.

### `GroupRow.swift`
Compact sidebar row showing photo count and whether the group is a close call.

### `ConfirmDeleteSheet.swift`
Modal confirmation before deletion. Shows count of photos to delete, groups to keep, and estimated space freed. Calls `viewModel.confirmDelete()` on confirmation.

### `DoneView.swift`
Summary screen shown after successful deletion: kept count, deleted count, freed bytes.

### `SettingsView.swift`
Form sheet for:
- Grouping & Scoring: sensitivity preset, time window, hash threshold, close-call threshold sliders
- Behavior: include videos, cross-format (HEIC↔JPG), hold-for-review
- Protected albums, and the audit-log export
- All settings persist to `UserDefaults`
