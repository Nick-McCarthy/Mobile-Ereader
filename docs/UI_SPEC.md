# UI Specification (Library, Collections, Settings)

Reader screen: see [`READER.md`](READER.md). All screens must support Dynamic Type, Dark Mode, VoiceOver labels, and the iPhone SE (small) through Pro Max size classes.

App root: `TabView` — **Library** · **Collections** · **Settings**.

## Library
- **Toolbar:** search bar (`.searchable`, always available, pulls down from nav bar), *View* menu, *Sort* menu, *Import* button (Files picker for local EPUBs).
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
- **Library**
  - *Author name format*: As stored · First Last · Last, First (live preview row using a sample author).
  - *Create Collection…* → name prompt (validates uniqueness).
  - *Create Series…* → name prompt.
  - *Manage Collections* / *Manage Series* → lists with rename/delete.
- **Reading defaults** — default font, size, page colour (reader drawer edits per-session values; these are the starting defaults).
- **Storage** — space used by downloads, *Remove All Downloads* (its confirmation says how many detached books will also be removed from the library).
- **About & Privacy** — version, privacy policy link, open-source licences (acknowledgements for Readium and its dependencies, GRDB, ZIPFoundation), *Delete All App Data*.
