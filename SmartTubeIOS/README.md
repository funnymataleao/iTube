# iTube shared package

A native Swift/SwiftUI YouTube client for **iPhone**, **iPad**, **macOS**, and **Apple TV**.

---

## Features

| Feature | Implementation |
|---|---|
| Home / Subscriptions / History feeds | `BrowseView` + `BrowseViewModel` → InnerTube API |
| Video playback (adaptive, HLS, DASH) | `PlayerView` + `PlaybackViewModel` → AVPlayer / AVKit |
| Search with suggestions | `SearchView` + `SearchViewModel` |
| Channel browser | `ChannelView` + `ChannelViewModel` |
| SponsorBlock auto-skip | `SponsorBlockService` + segment markers on progress bar |
| DeArrow community titles/thumbnails | `DeArrowService` |
| Google sign-in | `AuthService` — YouTube TV device authorization grant |
| Settings (quality, speed, theme, SponsorBlock categories) | `SettingsView` + `SettingsStore` |
| Library (playlists, history) | `LibraryView` |
| Picture-in-Picture | Built-in via `AVKit.VideoPlayer` |

---

## Architecture

```
SmartTubeIOS/
├── Package.swift
└── Sources/SmartTubeIOS/
    ├── SmartTubeApp.swift          # @main entry point
    ├── Models/
    │   ├── Video.swift             # Core video data model
    │   ├── VideoGroup.swift        # VideoGroup, BrowseSection, Channel, etc.
    │   └── AppSettings.swift       # Persisted user preferences
    ├── Services/
    │   ├── InnerTubeAPI.swift      # YouTube InnerTube API (unofficial)
    │   ├── SponsorBlockService.swift  # SponsorBlock + DeArrow APIs
    │   ├── AuthService.swift       # Google OAuth 2.0
    │   └── SettingsStore.swift     # UserDefaults-backed preferences store
    ├── ViewModels/
    │   ├── BrowseViewModel.swift   # Home/subs feeds
    │   ├── PlaybackViewModel.swift # AVPlayer wrapper + SponsorBlock skip
    │   └── SearchViewModel.swift   # Search + ChannelViewModel
    └── Views/
        ├── RootView.swift          # iOS TabView / macOS SidebarView
        ├── Browse/
        │   ├── BrowseView.swift    # Main grid feed
        │   └── VideoCardView.swift # Thumbnail card (grid & compact)
        ├── Player/
        │   └── PlayerView.swift    # Full-screen AVKit player + controls
        ├── Search/
        │   └── SearchView.swift    # Searchable results list
        ├── Channel/
        │   └── ChannelView.swift   # Channel header + video grid
        ├── Settings/
        │   └── SettingsView.swift  # App preferences Form
        └── Common/
            ├── SignInView.swift    # Google sign-in sheet
            └── LibraryView.swift   # Subscriptions / History / Playlists
```

### Design Patterns

| Pattern | Implementation |
|---|---|
| UI architecture | **MVVM** (`@Observable` ViewModels) |
| Async | Swift **async/await** |
| Navigation | **NavigationStack** + `TabView` (iOS) / `NavigationSplitView` (macOS) |
| Playback | **AVPlayer** + AVKit `VideoPlayer` |
| Image loading | **AsyncImage** (SwiftUI built-in) |
| Preferences | **UserDefaults** via `SettingsStore` (migrate to Keychain for secrets) |
| Authentication | YouTube TV device authorization grant via `ASWebAuthenticationSession` |

---

## Requirements

| Platform | Minimum |
|---|---|
| iOS / iPadOS | 17.0 |
| macOS | 14.0 (Sonoma) |
| tvOS | 17.0 |
| Xcode | 16.0 |
| Swift | 6.0 |

---

## Getting Started

### 1. Open in Xcode

```bash
git clone https://github.com/funnymataleao/iTube
cd iTube
open iTube.xcworkspace
```

Select the **iTube** scheme and run on a simulator or device.

### 2. Authentication

Sign-in uses the YouTube TV device authorization grant — no external OAuth credentials are required. `AuthService` scrapes the YouTube TV client credentials automatically at runtime.

### 3. Run Tests

```bash
swift test --package-path SmartTubeIOS
```

---

## Notes

- The [InnerTube API](https://github.com/LuanRT/YouTube.js) used here is **unofficial** and may break when YouTube updates its backend.
- Stream URLs returned by the InnerTube player endpoint are time-limited; long-running downloads will require re-fetching.
- Background audio playback requires the `audio` background mode to be added to the app's Info.plist.
- OAuth tokens are currently stored in `UserDefaults`; consider migrating to Keychain for hardened deployments.
