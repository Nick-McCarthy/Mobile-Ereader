# E-reader Screen

Engine: **Readium Swift Toolkit** (`ReadiumShared`, `ReadiumStreamer`, `ReadiumNavigator`, `ReadiumAdapterGCDWebServer` only if required by the chosen version). Open the file with `AssetRetriever` + `PublicationOpener`, present `EPUBNavigatorViewController` wrapped in a `UIViewControllerRepresentable` (`ReaderContainerView`). Pin the exact Readium version in `Package.resolved`; read its migration guide before bumping.

## Gesture rules (concept requirement)
- **Tap** anywhere in the content → toggle the reader chrome (top bar + bottom bar). Implement via `VisualNavigatorDelegate.navigator(_:didTapAt:)`; do **not** install Readium's edge-tap-to-turn behaviour (`DirectionalNavigationAdapter`) for taps, so every tap only toggles chrome.
  - Exception: taps on links inside the book follow the link (Readium handles this before the tap callback) and don't toggle chrome.
- **Swipe / drag left or right** → page turn only. Chrome must **not** appear or disappear. Paginated mode uses Readium's native swipe; in scroll mode vertical drag scrolls.
- Chrome auto-hides when a page turn happens while it's visible. Hide status bar along with chrome. Respect safe areas.
- Optional keyboard / hardware: arrow keys turn pages (free via Readium's `DirectionalNavigationAdapter` for keys only).

## Chrome layout
**Top bar:** `‹ Library` (back) · title · `Aa` · *Add bookmark* (bookmark icon; filled when the current page is bookmarked, tap again to remove) · *Bookmarks list* · *Contents* (chapter navigation).
**Bottom bar:** draggable progress slider + label `"42%"` and chapter title / "x pages left in chapter" when available.

## Back button
Saves the current locator (also saved continuously, debounced ~1 s, from `navigator(_:locationDidChange:)`), dismisses to the library.

## "Aa" drawer
`.sheet` with `.presentationDetents([.medium, .large])`, segmented tabs **Font | Layout**. Every change applies immediately via `navigator.submitPreferences(_:)` and is persisted (global defaults; per-book override is a later enhancement).

| Tab | Control | Readium `EPUBPreferences` |
|---|---|---|
| Font | Font family (Publisher default, system serif/sans, bundled OpenDyslexic, Literata, etc.) | `fontFamily` (+ register bundled fonts via `FontFamilyDeclaration`) |
| Font | Size (stepper/slider) | `fontSize` |
| Font | Spacing: line height, letter spacing, word spacing, paragraph spacing | `lineHeight`, `letterSpacing`, `wordSpacing`, `paragraphSpacing` (set `publisherStyles = false` when the user overrides) |
| Layout | Page colour: White, Sepia, Dark, Black, + custom | `theme` (`.light/.sepia/.dark`) or `backgroundColor` / `textColor` |
| Layout | Continuous scrolling (toggle) | `scroll` |
| Layout | Alignment: start / justify (+ hyphenation toggle) | `textAlign`, `hyphens` |
| Layout | Orientation lock: Auto / Portrait / Landscape | *App-level*, not Readium: update `AppDelegate.orientationLock`, call `windowScene.requestGeometryUpdate(.iOS(interfaceOrientations:))` and `setNeedsUpdateOfSupportedInterfaceOrientations()`. Only applies while the reader is open. |

Use Readium's `PreferencesEditor` to know which settings are effective for the current publication (e.g. fixed-layout books ignore font settings — disable those controls with an explanatory footnote).

## Bookmarks
- *Add bookmark* stores the navigator's `currentLocation` (`Locator` JSON), chapter title, `totalProgression`, and a short text snippet (`locator.text.highlight` or from `navigator.currentSelection`/visible text).
- *Bookmarks list* drawer: `List` sorted by position, each row = chapter, snippet, percentage, relative date. Tap → `navigator.go(to:)` and close drawer. Swipe to delete. Empty state copy.

## Chapter navigation
Drawer listing `publication.tableOfContents()` (nested, indented, collapsible for deep TOCs). Highlight and auto-scroll to the current chapter. Tap → `navigator.go(to: link)`.

## Progress bar
- Value = `locator.locations.totalProgression` (0…1), label = rounded percentage.
- While dragging: show a floating preview (percentage + chapter title at that position via `publication.locate(progression:)`); navigate on **release** (avoid thrashing the WebView).
- Save `progression` to `book.progression` for list display.

## Performance & safety
- Open/close must not leak the navigator (verify in Instruments once).
- Book JavaScript: keep Readium defaults; never inject app-privileged JS bridges reachable from book content. Block external network loads from book content (Readium serves resources from a local server/custom scheme; links to `http(s)` open in `SFSafariViewController` only after user tap).
- Handle DRM-protected EPUBs (LCP / Adobe) gracefully: detect and show "This book is DRM-protected and can't be opened" — DRM support is out of scope.
