# Data Model

SQLite via GRDB. All schema changes go through a **new, append-only** `DatabaseMigrator` migration — never edit a shipped migration.

Implemented in `Packages/EreaderKit/Sources/Persistence`: `AppDatabase` (opening, configuration, Data Protection) and `Schema` (migrations; v1 = everything below). Enum-like text columns have `CHECK` constraints, foreign keys are enforced, and collection/series names are unique case-insensitively (`NOCASE`, ASCII only).

## Tables

### `book`
| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PK | UUID string, app-generated |
| `sourceKind` | TEXT | `local` \| `iCloud` \| `dropbox` \| `oneDrive` |
| `sourceId` | TEXT NULL FK → `library_source.id` (ON DELETE SET NULL) | null for local imports and for **detached** books (`sourceKind` ≠ `local` and `sourceId` is null: downloaded books whose source was unlinked; see [`REMOTE_SOURCES.md`](REMOTE_SOURCES.md#unlinking--detached-books)) |
| `remoteId` | TEXT NULL | Dropbox `id:…`, Graph item id, or iCloud path relative to the root. UNIQUE together with `sourceId` |
| `remotePath` | TEXT NULL | Human-readable path inside the synced root, for display/debug |
| `remoteVersion` | TEXT NULL | Change token: Dropbox `content_hash`, OneDrive `cTag`, iCloud `<modDate>-<size>` |
| `remoteModifiedAt` | DATETIME NULL | |
| `fileSize` | INTEGER NULL | bytes |
| `title` | TEXT NOT NULL | Effective title (user override if set, else parsed, else `"Unknown Title"`) |
| `titleIsPlaceholder`, `authorIsPlaceholder` | BOOLEAN NOT NULL | True when the stored value is the placeholder, so it sorts last and can be localised |
| `titleSort` | TEXT NOT NULL | Lower-cased, leading articles ("the", "a", "an") stripped |
| `authorRaw` | TEXT NOT NULL | Exactly as parsed (or `"Unknown Author"`) |
| `authorFileAs` | TEXT NULL | OPF `opf:file-as` / `refines … file-as` if present |
| `authorStoredFormat` | TEXT NOT NULL | `firstLast` \| `lastFirst` \| `unknown` — auto-detected, user-overridable (see [`EPUB_METADATA.md`](EPUB_METADATA.md#author-name-normalisation)) |
| `authorGiven` / `authorFamily` | TEXT NULL | Parsed components used to render any display format |
| `publicationDate` | TEXT NULL | ISO-8601 (may be year-only, e.g. `"1998"`); null renders as "Unknown" |
| `publicationDateSort` | INTEGER NULL | `yyyymmdd`, nulls sort last |
| `language`, `publisher`, `description`, `identifier` | TEXT NULL | Nice-to-have, cheap to capture |
| `coverPath` | TEXT NULL | Relative path in `Caches/Covers`; null → placeholder cover |
| `localFilePath` | TEXT NULL | Relative path under `Application Support/Books` (`remote/` or `local/`); null → not downloaded |
| `downloadState` | TEXT NOT NULL | `notDownloaded` \| `downloading` \| `downloaded` \| `failed` |
| `isUserEdited` | BOOLEAN | If true, sync must not overwrite edited fields |
| `userEditedFields` | TEXT (JSON array) | Which fields were edited (`title`, `author`, `publicationDate`, `cover`) |
| `isMissingFromSource` | BOOLEAN | File no longer found in its source on last sync (kept so reading data isn't lost) |
| `dateAdded`, `lastOpenedAt` | DATETIME | `lastOpenedAt` drives "Recently viewed" sort |
| `progression` | REAL | 0…1 cached from last locator, for list display |

### `book_fts` (FTS5)
One row per book: `bookId` (UNINDEXED), `title`, `author` (`authorRaw` + `authorFileAs`), `series` (series name), `collections` (collection names). Tokenizer `unicode61 remove_diacritics 2`, so "garcia" matches "García".
- It's a regular FTS5 table, not external-content, because it combines columns from several tables.
- FTS5 matches tokens in any order, so "ursula le guin" finds "Le Guin, Ursula K." without storing both name orders.
- Triggers on `book`, `series`, `series_book`, `collection`, and `collection_book` keep it current, including renames and cascaded deletes.
- Build query patterns from user input with GRDB's `FTS5Pattern(matchingAllPrefixesIn:)`, never by string concatenation.

### `reading_position`
`bookId` (PK, FK cascade) · `locatorJSON` (Readium `Locator` serialised) · `updatedAt`.

### `bookmark`
`id` · `bookId` (FK cascade) · `locatorJSON` · `chapterTitle` · `progression` (REAL) · `textSnippet` (≤160 chars around the location) · `createdAt`. Index on (`bookId`, `progression`).

### `collection`
`id` · `name` (UNIQUE, case-insensitive) · `sortOrder` · `createdAt`.

### `collection_book`
`collectionId` · `bookId` · `addedAt` — composite PK, both FK cascade. A book can be in many collections.

### `series`
`id` · `name` (UNIQUE, case-insensitive) · `createdAt`.

### `series_book`
`seriesId` · `bookId` (PRIMARY KEY, so a book belongs to at most one series) · `position` (REAL, so 1.5 novellas work; NULL = unnumbered).

Series may also be pre-populated from EPUB metadata (`calibre:series` / `calibre:series_index`, or EPUB 3 `belongs-to-collection` + `collection-type="series"` + `group-position`).

### `library_source`
One row per linked source. A user may link any combination of iCloud Drive, Dropbox, and OneDrive, with one root folder each. See [`REMOTE_SOURCES.md`](REMOTE_SOURCES.md).

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PK | UUID; also the Keychain account name for that source's tokens |
| `kind` | TEXT | `iCloud` \| `dropbox` \| `oneDrive` (UNIQUE in v1: one link per service) |
| `accountLabel` | TEXT NULL | Display name / email shown in Settings (on-device only) |
| `rootId` | TEXT NULL | Dropbox folder id/path or Graph item id (`""` / `root` = whole drive) |
| `rootBookmark` | BLOB NULL | iCloud / Files folder bookmark data |
| `rootDisplayPath` | TEXT | e.g. `/Books/Fiction` |
| `syncCursor` | TEXT NULL | Dropbox `list_folder` cursor or Graph `deltaLink`; null → full listing |
| `status` | TEXT | `ok` \| `needsRelink` \| `error` |
| `lastSyncedAt` | DATETIME NULL | |
| `lastSyncError` | TEXT NULL | Short, non-sensitive message |

Tokens are **never** stored in this table. They live in the Keychain.

**Unlink** deletes the `library_source` row inside one transaction that first deletes that source's not-downloaded books, then lets `ON DELETE SET NULL` detach the downloaded ones. Deleting a detached book's file deletes its `book` row (child tables cascade).

### `app_settings`
Prefer `UserDefaults` (`@AppStorage`) for simple prefs: author display format, library view mode, sort key/direction, reader defaults. Reader **per-book** overrides, if added, go in a `book_reader_prefs` table.

## Display rules
- Never write the literal placeholder text into `authorGiven/authorFamily`; placeholders are a display concern, except `title`/`authorRaw` which are NOT NULL and store `"Unknown Title"` / `"Unknown Author"` with a flag (`titleIsPlaceholder`, `authorIsPlaceholder`) so they sort last and can be localised.
- Sorting:
  - *Recently viewed*: `lastOpenedAt DESC NULLS LAST, dateAdded DESC`
  - *Title*: `titleSort`
  - *Author*: family name (from components), then given, then title
  - *Publication date*: `publicationDateSort` (nulls last)
  - *Downloaded / not downloaded*: `downloadState = 'downloaded'` first (toggle direction), then title
