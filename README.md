# Photo Deduper

A native macOS app for travel photographers to find and remove near-duplicate photos using on-device AI scoring and Claude's vision API.

## Features

- Groups burst/similar shots by timestamp (configurable window)
- Verifies visual similarity with perceptual difference hashing
- Scores each photo on sharpness and exposure using Core Image
- Uses Claude Vision API to break close-call ties with an explanation
- Side-by-side batch review — you control every deletion
- Moves deleted photos to **Recently Deleted** (30-day recovery)

## Setup

### 1. Prerequisites

- macOS 14 (Sonoma) or later
- Xcode 15 or later

### 2. Open in Xcode

```bash
open PhotoDeduper.xcodeproj
```

### 3. Configure signing

In Xcode → Project → PhotoDeduper target → Signing & Capabilities:
- Set your **Team**
- Xcode will auto-manage the bundle ID

### 4. Build & Run

`Cmd+R` — the app will ask for Photos library access on first launch.

### 5. Add your Claude API key (optional)

Click the gear icon on the splash screen → paste your Anthropic API key.
This enables AI explanations for close-call groups. Without it, the app
still scores photos on-device and works fully.

## How it works

1. **Scan** — fetches all photos sorted by date
2. **Group** — clusters photos within the time window (default: 30 s)
3. **Hash** — verifies visual similarity via dHash; splits groups that diverge
4. **Score** — rates each photo: 70% sharpness + 30% exposure
5. **AI review** — calls Claude for groups where scores differ by < 15%
6. **Review** — you see all groups, override any AI choice by tapping a photo
7. **Delete** — one confirm tap; rejects move to Recently Deleted

## Adjustable settings

| Setting | Default | Effect |
|---|---|---|
| Time window | 30 s | Max gap between photos in a group |
| Hash threshold | 15 bits | Higher = more permissive grouping |
| Close-call threshold | 15% | Score gap below which Claude is called |

## Project structure

```
PhotoDeduper/
├── App/              Entry point, root ContentView
├── Managers/         Business logic (grouping, scoring, API, deletion)
├── ViewModels/       ReviewViewModel — orchestrates the scan pipeline
├── Views/            All SwiftUI views
└── Utilities/        KeychainHelper
```
