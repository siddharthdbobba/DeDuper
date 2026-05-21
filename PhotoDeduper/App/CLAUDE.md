# App

Entry point and navigation shell.

## Files

### `PhotoDeduperApp.swift`
`@main` struct. Creates the single `ReviewViewModel` instance and injects it into the SwiftUI environment via `WindowGroup`.

### `ContentView.swift`
Root navigation controller. Drives the top-level state machine by switching on `ReviewViewModel.scanState`:

| State | Shown View |
|-------|-----------|
| `.idle` | `SplashView` (scan entry) |
| `.scanning` | `ScanProgressView` |
| `.reviewing` | `ReviewView` |
| `.done` | `DoneView` |
| `.error` | Inline error message with retry |
