# PhotoDeduper — Source Root

This directory is the single Xcode target (`PhotoDeduper`). All Swift source files live in the subdirectories below.

## Subdirectory Guide

| Directory | Purpose |
|-----------|---------|
| `App/` | `@main` entry point and `ContentView` (navigation shell) |
| `Managers/` | All stateful I/O and heavy computation |
| `Models/` | Value types shared across layers |
| `Utilities/` | Thin wrappers around system APIs |
| `ViewModels/` | `ReviewViewModel` — the single source of truth for app state |
| `Views/` | SwiftUI views; no business logic |

## Supporting Files

- `Info.plist` — bundle metadata and `NSPhotoLibraryUsageDescription`
- `PhotoDeduper.entitlements` — sandbox entitlements (app sandbox, Photos library, user-selected file read-write; no network)
