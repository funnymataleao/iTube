# iTube

iTube is a native SwiftUI video client built primarily for Apple TV. It is designed for the living room: full Siri Remote navigation, AVKit playback, optional Google sign-in, local subscriptions, and a guest mode that works without creating an account.

> iTube is an independent third-party client. It is not affiliated with, endorsed by, or sponsored by Google or YouTube.

## Public pages

- [Product site](https://funnymataleao.github.io/iTube/)
- [Privacy Policy](https://funnymataleao.github.io/iTube/privacy/)
- [Terms of Use](https://funnymataleao.github.io/iTube/terms/)
- [Support](https://funnymataleao.github.io/iTube/support/)

## Apple TV experience

- Browse, search, and play videos without signing in or purchasing anything.
- Sign in to Google only when account features such as subscriptions and playlists are wanted.
- Follow channels locally without a Google account.
- Play through AVPlayer/AVKit with captions, audio tracks, chapters, queue controls, and playback history.
- Use SponsorBlock and DeArrow community metadata when those optional features are enabled.
- Run playback directly on Apple TV; no Mac relay or always-on companion computer is required.

## Optional iTube Plus

A new installation receives a seven-day welcome period before the optional iTube Plus offer is first presented automatically. The offer is dismissible and free playback remains available. Plans are also accessible at any time from Settings.

Purchases use StoreKit. The purchase sheet is the source of truth for the localized price, billing period, renewal terms, and eligibility shown to a user.

## Project structure

```text
SmartTubeIOS/          Shared Swift package and tests
SmartTubeApp/          Xcode project and Apple-platform app targets
SmartTube.xcworkspace/ Workspace for the project and local package
docs/                  GitHub Pages site
```

Some internal module, bundle, and persistence identifiers retain their historical names to preserve source compatibility, installed app data, Keychain access, and StoreKit purchase identity. The public product name is iTube.

## Build the Apple TV app

Requirements:

- Xcode 16 or newer
- tvOS 17 or newer
- An Apple Developer team for device signing

```sh
git clone https://github.com/funnymataleao/iTube.git
cd iTube
open SmartTube.xcworkspace
```

Choose the **iTube** scheme and an Apple TV or tvOS Simulator destination.

Run package tests with:

```sh
swift test --package-path SmartTubeIOS
```

## Upstream and license

iTube is derived from the open-source [SmartTubeIOS project](https://github.com/milika/SmartTubeIOS) and preserves its history and GPL-3.0 licensing. See [LICENSE](LICENSE) and [CHANGELOG.md](CHANGELOG.md).
