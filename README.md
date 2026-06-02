# DeDuper

A native macOS & iOS app for photographers to find and remove near-duplicate photos —
**100% on-device, free, and private.** No accounts, no API keys, no network access.

## Features

- Groups burst/similar shots by timestamp (configurable window)
- Verifies visual similarity with perceptual difference hashing (dHash)
- Scores each photo on sharpness and exposure using Core Image
- Breaks close-call ties on-device using Vision face/aesthetics analysis, with an explanation
- Side-by-side batch review — you control every deletion
- Moves deleted photos to **Recently Deleted** (30-day recovery)

## Setup

### 1. Prerequisites

- macOS 14 (Sonoma) or later (and/or iOS 17+)
- Xcode 15 or later

### 2. Open in Xcode

```bash
open PhotoDeduper.xcodeproj
```

> The project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).
> If you change `project.yml`, run `xcodegen generate` to regenerate `PhotoDeduper.xcodeproj`.

### 3. Configure signing

In Xcode → Project → PhotoDeduper target → Signing & Capabilities:
- Set your **Team**
- Xcode will auto-manage the bundle ID

### 4. Build & Run

`Cmd+R` — the app will ask for Photos library access on first launch.

## How it works

1. **Scan** — fetches all photos sorted by date
2. **Group** — clusters photos within the time window (default: 30 s)
3. **Hash** — verifies visual similarity via dHash; splits groups that diverge
4. **Score** — rates each photo: 70% sharpness + 30% exposure
5. **Resolve close calls** — when the top two scores are within the close-call threshold,
   an on-device Vision pass (face sharpness, eyes-open, overall aesthetics) breaks the tie
   and shows a short "Why this one?" explanation
6. **Review** — you see all groups and can override any pick by tapping a photo
7. **Delete** — one confirm tap; rejects move to Recently Deleted

Everything runs locally on your device. No photo or metadata ever leaves the device.

## Adjustable settings

| Setting | Default | Effect |
|---|---|---|
| Time window | 30 s | Max gap between photos in a group |
| Hash threshold | 20 bits | Higher = more permissive grouping |
| Close-call threshold | 15% | Score gap below which the on-device resolver breaks the tie |

## Project structure

```
PhotoDeduper/
├── App/              Entry point, root ContentView
├── Managers/         Business logic (grouping, scoring, deletion, auditing)
├── ViewModels/       ReviewViewModel — orchestrates the scan pipeline
├── Views/            All SwiftUI views
└── Utilities/        KeychainHelper, PlatformImage
```

## License

MIT — see [LICENSE](LICENSE). Free to use, modify, and distribute.
