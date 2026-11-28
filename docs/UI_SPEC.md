# UI Specification (Library, Collections, Settings)

Reader screen: see [`READER.md`](READER.md). All screens must support Dynamic Type, Dark Mode, VoiceOver labels, and the iPhone SE (small) through Pro Max size classes.

App root: `TabView` — **Library** · **Collections** · **Settings**.

## All screens
- **Secondary text** (authors, captions, empty-state descriptions) uses `.secondaryText` (`App/Features/SecondaryText.swift`), not the system `.secondary`, which falls just short of 4.5:1 contrast at small sizes.
- **Tint and destructive text:** the app tint is `.accessibleAccent` (set on the `TabView`), and destructive buttons use `.foregroundStyle(.accessibleDestructive)`. Both meet 4.5:1 in light and dark mode; the system blue and red fall just short as text on grouped backgrounds.
- **Forms:**
  - Label/value rows use `InfoRow`, which styles the value with `.secondaryText` and combines both into one VoiceOver element, because a bare value such as "0.1.0" isn't a readable label.
  - Action buttons are text-only: a Form button with an icon keeps its label on one line, which the audit reports as clipped at large Dynamic Type sizes.
  - Long explanations go in a footnote row, not a section footer, which the audit reports as not fully scaling.
  - Section headers use `.secondaryText`.
  - Hide an action that can't be used rather than disabling it, since disabled text fails the contrast check.
- **Empty states** under a search bar (*No Results*) are shown centred, or in a scroll view when large Dynamic Type makes them taller than the screen (`ViewThatFits`), so they never clip. Don't size a scroll view's content from a `GeometryReader` under a collapsing search bar: the height feeds back and the layout can loop (a CI run hung that way).
- **Accessibility audit:** `auditAccessibility(_:)` (`UITests/AuditSupport.swift`) runs `performAccessibilityAudit()` and reports every issue in one failure, on one line (xcbeautify shows only a failure's first line), each naming its element. It covers the Library, empty and as a grid and a list of books (`AccessibilityAuditTests`), Settings, and the source detail screen (`BookSourcesTests`). Add new screens. The only exclusions are in UIKit's search field, which the app can't change: its clear button (×) has a 20 pt hit area, and its fixed-height text field is reported as clipping at large sizes.
- Decorative images (covers beside a title) are hidden from VoiceOver; progress indicators have a label.

## Library
- **Toolbar:** search bar (`.searchable`, always available, pulls down from nav bar), *View* menu, *Sort* menu, *Import* button (Files picker for local EPUBs). Importing a book that is already in the library asks *Replace* / *Keep Both* / *Skip* (see [`DATA_MODEL.md`](DATA_MODEL.md#series_book)).
- **View modes** (persisted in `@AppStorage`):
  - **Grid** — `LazyVGrid` of covers (adaptive ~110 pt columns), title + author under each, download badge (cloud icon when not downloaded; circular progress while downloading).
  - **List** — row with small cover, title, author (formatted per setting), publication year, progress %, download state.
  - **Collections** — books grouped by collection in collapsible sections (same component as the Collections tab, see below), plus an "Not in a collection" section.
- **Sort** (with ascending/descending toggle): Recently viewed · Title · Author · Publication date · Downloaded/Not downloaded. Rules in [`DATA_MODEL.md`](DATA_MODEL.md#display-rules).
- **Search:** FTS5 prefix match on title, author (both name orders), series, collection; results update as you type (debounce ~150 ms). Shows `ContentUnavailableView.search` on no results.
- **Tap a book:**
  - Downloaded → open reader at last position, update `lastOpenedAt`.
  - Not downloaded → start download with inline progress; open automatically when done. Tap again = cancel. Offline → alert.
- **Long-press a book** (`.contextMenu` with a cover preview):
  - **Edit Details** → sheet: title, author, author stored format (First Last / Last, First), publication date, cover (choose from Photos / Files / reset to original). Saved fields go into `userEditedFields` so sync won't overwrite them. "Revert to file metadata" button.
  - **Add to Collection** → sheet with multi-select checklist of collections + "New Collection…".
  - **Add to Series** → sheet: pick series (or "New Series…") and optional number; "Remove from series".
  - **Download** / **Remove Download** (depending on state). For a detached book (its source was unlinked) *Remove Download* is labelled **Remove Download & Book** and asks for confirmation, because the book can't be downloaded again.
  - **Remove from Library** (destructive, confirmation dialog; for local imports it deletes the file).
- **Empty state:** explains how to add books, with buttons for *Connect iCloud Drive*, *Connect Dropbox*, *Connect OneDrive*, and *Import a File*.
- **Source indicator:** a small source glyph (iCloud / Dropbox / OneDrive / device) in list rows and the Edit Details sheet. Detached books show the glyph crossed out, with "Not linked" in Edit Details. *Missing from source* books show a subtle badge.
- **Sync banner:** slim progress banner at top while a sync is running.
- **As implemented (P3.3):**
  - `.searchable` on the library, with the default "Search" prompt (a longer one is clipped at large Dynamic Type sizes). It's always shown (`.navigationBarDrawer(displayMode: .always)`; added once the first book arrives, the default placement starts collapsed) but left out while the library is empty and nothing is typed: there's nothing to find, and the bar leaves *No Books Yet* too little room at large sizes. The typed text reaches `LibraryQuery.searchText` after a 150 ms pause (`task(id:)` restarts on each keystroke, which cancels the wait); clearing the field applies at once. The query and its ordering are the repository's FTS5 search ([`DATA_MODEL.md`](DATA_MODEL.md#repositories)), which matches every word as a prefix, so "ursula le guin" and "le guin, ursula" both find a book stored either way.
  - No matches shows "No Results" with the text searched for. It's a plain `ContentUnavailableView` rather than `ContentUnavailableView.search`, whose description uses the system secondary colour that the audit flags for contrast.
  - Tests: `RepositoryTests` (both name orders, both stored formats, series names, a live search updating); UI test `LibrarySearchTests` (both name orders, "No Results" with an audit, clearing restores every book).
- **As implemented (P3.2):**
  - `LibrarySortMenu`, next to the *View* menu, has two pickers: *Sort By* (Recently Viewed, Title, Author, Publication Date, Downloaded) and *Order*, whose two choices are named for the key (Most Recent First / Least Recent First, A to Z / Z to A, Oldest First / Newest First, Downloaded First / Not Downloaded First). The natural direction is the first.
  - Both are kept in `@AppStorage` (`librarySort`, `librarySortReversed`); the default is Recently Viewed, most recent first. The library's observation restarts with the new `LibraryQuery` when either changes. The ordering itself is the repository's (`DatabaseBookRepository.orderClause`, rules in [`DATA_MODEL.md`](DATA_MODEL.md#display-rules)).
  - UI test: `LibrarySortTests` sorts the seeded books by title both ways (the placeholder title stays last), checks the list keeps the order, and audits the list (the grid's audit is flaky after re-sorting; see P3.7 in the action plan). Book cells and rows have the identifier `library-book`.
- **As implemented (P3.1):**
  - `LibraryViewMode` (`grid` / `list`, `@AppStorage("libraryViewMode")`, grid by default) is picked from the *View* menu at the leading edge of the toolbar. Both views pull to refresh.
  - `LibraryGridView`: `LazyVGrid` with adaptive columns of at least 110 pt. The width isn't scaled with Dynamic Type: when larger type changes the column count, cells move rows and the audit reports their text as not supporting Dynamic Type. The list view suits the largest sizes. Each cell is the cover, the title, and the author, wrapped rather than line-limited, because the audit reports a line limit as text that won't grow with Dynamic Type.
  - `LibraryListView`: plain `List`; each row has the cover (44 pt wide, scaled), title, author, a "1971 · 42%" line (year and reading progress, each left out when unknown), and the status glyph.
  - `BookCover` (shared by both, and later by Collections) shows the extracted cover from `CoverImageCache`, or the generated placeholder: title and author in white on one of eight dark tints, drawn in a `Canvas` so the audit doesn't treat the cover-sized type as text that ignores Dynamic Type, picked by `PlaceholderCover.tintIndex` (FNV-1a of the title, stable across launches).
  - Download state comes from `Book.fileStatus(downloadProgress:)` (Persistence), using the live progress from `DownloadManager.observeProgress()`: no glyph when downloaded; `icloud.and.arrow.down` when not; a progress ring while downloading; `exclamationmark.icloud` when it failed; `questionmark.folder` when the file is missing from its source and there's no downloaded copy. On the grid the glyph sits on a small material disc in the cover's top corner.
  - Reading progress is `Book.readingPercent`: nil until started, at least 1 %, and 100 % only when finished.
  - VoiceOver reads each cell or row as one element: label "Title, Author", value such as "Not downloaded" or "Downloaded, 42% read, Published 1971". Covers and glyphs are hidden.
  - UI tests: `-UITestSeedBooks` seeds four books (downloaded and part-read, placeholder not downloaded, failed, missing), and `AccessibilityAuditTests` audits the grid and the list. UI-test launches reset the view mode.

## Collections tab
Chosen layout: **collapsible sections (accordion) inside a `List`** with `.listStyle(.insetGrouped)` — native, VoiceOver-friendly, comfortable one-handed.
- Each section header: collection name, book count, chevron; tapping toggles expansion (state persisted).
- Expanded section: horizontal scrolling row of covers (fast to scan), with "See All" that pushes a full grid of that collection.
- A **Series** segment at the top (`Picker` with *Collections | Series*) uses the same accordion, books ordered by series position and labelled "#1, #2…".
- Swipe on a header → Rename / Delete (delete never deletes books). Drag to reorder collections (`sortOrder`).
- `+` button creates a collection (same flow as Settings).

## Settings
Grouped `Form`:
- **Book Sources** (details in [`REMOTE_SOURCES.md`](REMOTE_SOURCES.md))
  - One row per service: **iCloud Drive / Files**, **Dropbox**, **OneDrive**. Each shows *Not linked* or the account label + chosen folder path + last-synced time; a warning badge if it needs re-linking. The user can link any combination.
  - Tapping an unlinked row: iCloud → system folder picker; Dropbox / OneDrive → sign-in sheet (`ASWebAuthenticationSession`), then the in-app folder browser (*This Folder* / *Whole Dropbox/OneDrive*).
  - Tapping a linked row → detail screen: *Change Folder*, *Sync This Source*, *Unlink*, with a confirmation that states the outcome: not-downloaded books from that source are removed from the library, downloaded books stay (detached), and the remote files aren't changed. See [`REMOTE_SOURCES.md`](REMOTE_SOURCES.md#unlinking--detached-books).
  - **Sync Now** button (syncs all linked sources) with live progress per source (found / processed / errors). *Cancel* while running.
  - Footer text: access is read-only, the app never modifies your files, and nothing is sent anywhere except the service you linked. iCloud footer notes that other installed file providers (such as Google Drive) also work through this option.
- **As implemented (P2.8):**
  - `BookSourcesSection` shows the three rows. iCloud links through `.fileImporter` for folders, then syncs that source. Dropbox and OneDrive say "Coming in a later version" until P2.5 and P2.6; their sign-in sheet and in-app folder browser come with those adapters.
  - A linked row shows the folder path and "Synced <relative time>", or the sync's progress while it runs, and a red warning glyph for `needsRelink` or `error`.
  - `SourceDetailView` has Folder, Last Synced, and (after a sync) Books Found / Couldn't Read, plus *Sync This Source*, *Change Folder…* (*Choose Folder Again…* when access was lost), and *Unlink…*. The unlink confirmation reads: "N books not downloaded will be removed from your library. M downloaded books will stay. Your files in <service> won't be changed."
  - `SyncCoordinator` (App, `@MainActor @Observable`) runs one sync at a time for *Sync Now*, *Sync This Source*, and pull-to-refresh on the library list, and keeps each source's latest `SyncProgress`. *Cancel Sync* replaces the sync buttons while one runs.
  - `SyncBanner` sits at the top of the library: "<service>: Looking for books…" / "Reading 12 of 40" while syncing, otherwise "<service> needs to be linked again. Open Settings to choose the folder." when a source is `needsRelink`.
  - UI tests: `BookSourcesTests` (with `-UITestLinkedFolder`, which links an empty temporary folder at launch) and accessibility audits of Settings and the source detail screen.
- **Library**
  - *Author name format*: As stored · First Last · Last, First (live preview row using a sample author).
  - *Create Collection…* → name prompt (validates uniqueness).
  - *Create Series…* → name prompt.
  - *Manage Collections* / *Manage Series* → lists with rename/delete.
- **Reading defaults** — default font, size, page colour (reader drawer edits per-session values; these are the starting defaults).
- **Storage** — space used by downloads, *Remove All Downloads* (its confirmation says how many detached books will also be removed from the library).
- **About & Privacy** — version, privacy policy link, open-source licences (acknowledgements for Readium and its dependencies, GRDB, ZIPFoundation), *Delete All App Data*.
