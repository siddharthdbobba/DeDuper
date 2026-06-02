# Models

Plain value types with no side effects. Safe to pass across concurrency boundaries.

## Files

### `PhotoItem.swift`
Unified representation for a single image, regardless of source.

```swift
enum Source {
    case asset(PHAsset)      // Photos library
    case fileURL(URL)        // File system
}
```

- `id` is `PHAsset.localIdentifier` for assets, `url.absoluteString` for files
- `creationDate` is read from EXIF `DateTimeOriginal` first, then file system creation date
- `imageExtensions` — supported raw and compressed formats: jpg, heic, png, cr2/cr3, nef, arw, dng, raf, orf, rw2, tif

### `PhotoAlbum.swift`
Lightweight wrapper around `PHAssetCollection` for display in `AlbumPickerView`. Carries `id`, `title`, `count`, and the underlying `collection`.
