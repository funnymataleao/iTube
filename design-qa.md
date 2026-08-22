# tvOS personalized Home shelf design QA

## Target and implementation

- Reference: `/var/folders/h4/rb7g5dgj5hl8q7hqzgjhbjkw0000gn/T/codex-clipboard-a9ce49f4-23df-4d4a-b6b3-ca4f1ef304c7.png`
- Implementation and focus-state screenshot: `/tmp/personaltube-office-live-fixed.png`
- Latest installed-build capture: `/tmp/personaltube-office-row-pagination-2.png`
- Side-by-side comparison: `/tmp/personaltube-office-live-comparison.png`
- Viewport: physical Apple TV `Office` (Apple TV 4K 3rd generation), tvOS 27
- Reference dimensions: 3840 × 2160 px
- Implementation dimensions: 3840 × 2160 px
- State: signed-in live account Home feed with Google-provided topic shelves and
  a focused first card

## Visual comparison

The full-screen comparison uses a physical-device capture. It verifies the same
heading-plus-horizontal-carousel hierarchy as the reference, including live topic
headings such as `Consumer Electronics and more` and `Tourism and more`. The focused
card's scale and glow are fully visible.

### Findings and corrections

- P1: Structural `Home`/`Главная` shelf titles were repeated between personalized
  groups. Fixed by reading the authenticated Google secondary-navigation tab title
  for each group and suppressing structural container titles.
- P1: The first attempted parser read the wrong TVHTML5 title field and then replaced
  the vertical feed continuation with a shelf's horizontal continuation. This merged
  the live account into one untitled row. Fixed by reading
  `headerRenderer.shelfHeaderRenderer.avatarLockup.avatarLockupRenderer.title` and
  following `sectionListRenderer`/`sectionListContinuation` tokens for more shelves.
- P2: Decorative icons were inserted into every shelf heading. Removed; headings
  now contain only Google's text.
- P2: Shelf and card typography was oversized. Reduced to native `headline`,
  `footnote`, and `caption2` styles with semantic weights.
- P2: Focus scale and glow were clipped by the horizontal scroll container. Fixed
  with unclipped scroll content, 64-point horizontal and 28-point vertical focus
  breathing room, and a 1.05 focus scale.
- P3: Thumbnail corners were too tight. Increased to an 18-point continuous radius.
- P1: Later shelves showed only two or three cards because video IDs were
  deduplicated across unrelated Google topics. Deduplication is now scoped to a
  single shelf, so legitimate overlap between topics is retained.
- P1: Horizontal shelf continuations were parsed but never consumed. Each Home
  carousel now owns and advances its `horizontalListContinuation` independently;
  vertical `sectionListContinuation` remains responsible only for adding topics.
- P1: Home used a separate custom dark backdrop, so it did not match Search,
  History, Subscriptions, and Settings. Removed the Home-specific backdrop;
  Home now inherits the same adaptive system tvOS background as every other tab.
- P2: Moving vertically after scrolling a shelf could preserve the horizontal
  column and enter the next shelf on its third card. Every shelf now has an
  independent tvOS focus scope whose first card is the preferred vertical entry.

### Final pass

- Hierarchy: passed. Each topic is a heading followed by its own horizontal video
  carousel; there is no topic chip/tab strip.
- Ordering: passed. “New to you” is promoted to the first shelf, while every other
  Google-provided topic retains its personalized server order.
- Typography: passed. System San Francisco styles are used and headings remain
  readable at TV distance.
- Spacing and focus: passed. Shelves have consistent leading alignment, preserve
  native tvOS focus behavior, and the focused card glow remains fully visible.
- Assets and image quality: passed. Video thumbnails come from the live content
  source and shelf headings contain no decorative assets.
- Accessibility: passed for the changed structure. Shelf titles are exposed as
  headers and focusable cards remain reachable.
- Localization: passed for layout. Server-provided shelf titles can grow without
  changing the carousel structure.
- Existing primary app navigation remains a top system tab bar; changing it to the
  reference application's sidebar was outside this shelf-layout correction.

## Functional verification

- Simulator build: passed.
- Signed physical-tvOS build, install, and launch on `Office`: passed.
- Physical-device process and 3840 × 2160 screenshot capture: passed.
- Live-account Google shelf headers and vertical continuation: passed.
- Signed build containing per-shelf horizontal pagination: passed.
- Install and foreground launch of that build on `Office`: passed.
- The `SmartTubeTVUITests` target was removed at the user's request. No tvOS UI
  test Runner is installed or used; physical checks use the signed product app.
- Parser and view-model coverage for row tokens, cross-shelf overlap, and append
  behavior was added. The package's standalone test action remains blocked by its
  pre-existing macOS-only `TOSPlayerView` compile mismatch; the signed tvOS product
  build itself succeeds.

## Final result

passed
