# tvOS Home shelf design QA

## Target and implementation

- Reference: `/var/folders/h4/rb7g5dgj5hl8q7hqzgjhbjkw0000gn/T/codex-clipboard-c2c51502-4f97-4268-b828-4b7da62aeebd.png`
- Implementation screenshot: `/tmp/personaltube-shelves-v3.png`
- Side-by-side comparison: `/tmp/personaltube-design-comparison-v3.png`
- Viewport: Apple TV 4K (3rd generation), tvOS 27 simulator
- Reference dimensions: 3840 × 2160 px
- Implementation dimensions: 3840 × 2160 px
- State: signed-in Home feed with deterministic real YouTube thumbnails

## Visual comparison

The full-screen comparison is sufficient for this change because the shelf headings,
card size, horizontal density, and the start of the second shelf are all readable at
the captured resolution. A separate crop would not expose additional detail.

### Pass 1 findings

- P2: The shelf heading was larger than the reference. Fixed by using the native
  `title2` text style with semibold weight.
- P2: The row was too dense compared with the reference. Fixed by increasing the
  tvOS shelf card width from 520 to 600 points.

### Final pass

- Hierarchy: passed. Each topic is a heading followed by its own horizontal video
  carousel; there is no topic chip/tab strip.
- Ordering: passed. Recommended content is first, “New to you” is promoted to the
  second shelf, and remaining Google-provided topics retain their personalized order.
- Typography: passed. System San Francisco styles are used and headings remain
  readable at TV distance.
- Spacing and focus: passed. Shelves have consistent leading alignment and preserve
  native tvOS focus behavior.
- Assets and image quality: passed. Video thumbnails come from the live content
  source; shelf icons use SF Symbols rather than fabricated assets.
- Accessibility: passed for the changed structure. Shelf titles are exposed as
  headers, decorative symbols are hidden, and focusable cards remain reachable.
- Localization: passed for layout. Server-provided shelf titles can grow without
  changing the carousel structure.
- Existing primary app navigation remains a top system tab bar; changing it to the
  reference application's sidebar was outside this shelf-layout correction.

## Functional verification

- Simulator build: passed.
- Focus/select/player/back UI test: passed (1 test, 0 failures).

## Final result

passed
