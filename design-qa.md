# tvOS personalized Home shelf design QA

## Target and implementation

- Reference: `/var/folders/h4/rb7g5dgj5hl8q7hqzgjhbjkw0000gn/T/codex-clipboard-a9ce49f4-23df-4d4a-b6b3-ca4f1ef304c7.png`
- Implementation screenshot: `/tmp/personaltube-shelves-v4.png`
- Focus-state screenshot: `/tmp/personaltube-shelves-v4-attachments/B5B81F42-77E1-4E65-9614-BC7236440EEF.png`
- Side-by-side comparison: `/tmp/personaltube-design-comparison-v4.png`
- Viewport: Apple TV 4K (3rd generation), tvOS 27 simulator
- Reference dimensions: 3840 × 2160 px
- Implementation dimensions: 3840 × 2160 px
- State: signed-in Home feed with deterministic real YouTube thumbnails and a
  focused first card

## Visual comparison

The full-screen comparison shows the repeated structural `Home` titles, heading
icons, typography, card radius, and carousel spacing. The separate focus-state
screenshot verifies that the focused card's scale and glow are not clipped by the
horizontal scroll container.

### Findings and corrections

- P1: Structural `Home`/`Главная` shelf titles were repeated between personalized
  groups. Fixed by reading the authenticated Google secondary-navigation tab title
  for each group and suppressing structural container titles.
- P2: Decorative icons were inserted into every shelf heading. Removed; headings
  now contain only Google's text.
- P2: Shelf and card typography was oversized. Reduced to native `headline`,
  `footnote`, and `caption2` styles with semantic weights.
- P2: Focus scale and glow were clipped by the horizontal scroll container. Fixed
  with unclipped scroll content, 64-point horizontal and 28-point vertical focus
  breathing room, and a 1.05 focus scale.
- P3: Thumbnail corners were too tight. Increased to an 18-point continuous radius.

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
- Focus/select/player/back UI test: passed (1 test, 0 failures).

## Final result

passed
