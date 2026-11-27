# Architecture

Requirements source: [`/Concept.md`](../Concept.md). Delivery order: [`ACTION_PLAN.md`](ACTION_PLAN.md).

## Tech stack decision

| Concern | Choice | Why |
|---|---|---|
| Language / UI | **Swift 5.10+ (Swift 6 language mode where practical), SwiftUI**, UIKit only where a library requires it | Fully native, best App Store review outcome, first-class access to Keychain, Data Protection, background tasks. |
| Minimum OS | **iOS 17.0** | `@Observable`, modern SwiftUI navigation, `NavigationStack`, `ContentUnavailableView`. Covers the vast majority of active devices. |
| EPUB rendering | **[Readium Swift Toolkit](https://github.com/readium/swift-toolkit)** (latest stable 3.x, via SPM) | The most flexible open-source EPUB engine on iOS: reflowable + fixed layout, paginated *and* continuous scroll, a typed *Preferences* API (font family, size, letter/word/line spacing, alignment, theme/page colour), `Locator`-based positions with `totalProgression`, table of contents, decorations, and a delegate for tap handling. BSD-3 licensed. See [`READER.md`](READER.md). |
| Persistence | **[GRDB.swift](https://github.com/groue/GRDB.swift)** (SQLite) | Explicit migrations, FTS5 full-text search for the library search bar, observation (`ValueObservation`) that plugs into SwiftUI, predictable performance with thousands of books. See [`DATA_MODEL.md`](DATA_MODEL.md). |
| Remote book sources | User's choice of **iCloud Drive / Files**, **Dropbox**, **OneDrive** behind one `RemoteSource` protocol | iCloud needs no third-party setup; Dropbox and OneDrive offer read-only scopes without Google's restricted-scope security assessment. See [`REMOTE_SOURCES.md`](REMOTE_SOURCES.md). |
| Cloud auth (Dropbox, OneDrive) | **OAuth 2.0 + PKCE via `ASWebAuthenticationSession`**, tokens in the Keychain | One small shared implementation instead of two vendor SDKs (SwiftyDropbox, MSAL). |
| Cloud APIs | **Dropbox API v2 and Microsoft Graph v1.0 over `URLSession`** (thin hand-written clients) | We only need folder listing, change cursors, and (ranged) downloads. |
| iCloud Drive access | `UIDocumentPickerViewController` folder pick + bookmark, `FileManager` / `NSFileCoordinator` | No iCloud entitlement or container needed; also works with any other file provider app. |
| EPUB metadata (sync-time) | **[ZIPFoundation](https://github.com/weichsel/ZIPFoundation)** for local and iCloud files, plus a small custom **remote ZIP reader** (HTTP range requests) for Dropbox and OneDrive | Lets us read title/author/date/cover *without* downloading whole books. See [`EPUB_METADATA.md`](EPUB_METADATA.md). |
| XML parsing | Foundation `XMLParser` (or Readium's parser when the file is local) | No extra dependency. |
| Image cache | Covers written to disk as downscaled JPEG/HEIC thumbnails; loaded via a small in-memory `NSCache` | Keeps the DB small, list/grid scrolling smooth. |
| Project generation | **Xcode project** (optionally XcodeGen `project.yml` to keep the `.pbxproj` merge-friendly) | Agents can edit `project.yml` as text. |
| Tests | **Swift Testing** (`@Test`) for unit tests, **XCUITest** for UI flows | Built into Xcode 16+. |
| Lint / format | `swift-format` (Apple) with repo config | Deterministic formatting for agent-written code. |

Rejected alternatives (don't revisit without a reason):
- **React Native / Flutter** – EPUB rendering would still need a native WebView-based engine, plus bridging; adds attack surface and review risk with no benefit for an iPhone-only app.
- **SwiftData** – viable, but weaker migration story and no built-in FTS; GRDB is more predictable.
- **Google Drive as a built-in source**: its `drive.readonly` scope is restricted (Google verification + annual paid CASA assessment for public release). Google Drive users can use the iCloud Drive / Files picker via the Google Drive app.
- **SwiftyDropbox / MSAL**: large SDKs for what is a standard PKCE flow plus a few REST calls.
- **FolioReaderKit** – unmaintained.
- **Building our own renderer on WKWebView** – reinvents pagination, CSS injection, locators; Readium already solves it.

## Module layout

Single app target plus local Swift packages so domain logic is testable without the simulator UI.

```
Mobile-Ereader/
├─ App/                          # iOS app target (SwiftUI entry point, scenes, DI wiring)
│  ├─ EreaderApp.swift
│  ├─ Features/
│  │  ├─ Library/                # grid / list / collections views, search, sort, context menu
│  │  ├─ Collections/
│  │  ├─ Settings/
│  │  ├─ BookDetailsEditor/
│  │  └─ Reader/                 # Readium navigator wrapper + reader chrome + drawers
│  ├─ Resources/                 # Assets, Localizable.xcstrings, PrivacyInfo.xcprivacy
│  └─ Info.plist
├─ Packages/
│  ├─ Core/                      # Models, AuthorNameFormatter, shared utilities (no UIKit)
│  ├─ Persistence/               # GRDB database, migrations, repositories
│  ├─ EPUBMetadata/              # OPF parsing, cover extraction, RemoteZipReader
│  ├─ RemoteSources/             # RemoteSource protocol, OAuth/PKCE + Keychain, iCloud/Dropbox/OneDrive adapters, SyncEngine
│  └─ BookStorage/               # On-device file management, downloads, file protection
├─ AppTests/ AppUITests/
├─ docs/                         # agent helper files (see /Agents.md)
└─ project.yml                   # XcodeGen spec (if adopted)
```

Dependency direction (no cycles): `App → {RemoteSources, BookStorage, Persistence, EPUBMetadata} → Core`. Readium is imported only by `App/Features/Reader` and (optionally) `EPUBMetadata` for local files.

## Runtime architecture

- **State:** feature-level `@Observable` view models (`@MainActor`). They read from repositories that expose GRDB `ValueObservation` streams as `AsyncSequence`.
- **Concurrency:** Swift structured concurrency. `SyncEngine` and `DownloadManager` are `actor`s. No `DispatchQueue` juggling in feature code.
- **Dependency injection:** a single `AppEnvironment` struct built at launch and passed via SwiftUI `Environment`. Tests construct it with fakes (`FakeRemoteSource`, in-memory DB).
- **Navigation:** `TabView` with *Library*, *Collections*, *Settings*; the reader is presented `fullScreenCover` from any book tap.

## File storage on device

| Path | Contents | Protection | Backed up? |
|---|---|---|---|
| `Application Support/Database/library.sqlite` | All metadata | `completeUntilFirstUserAuthentication` (sync can run in background) | Yes |
| `Application Support/Books/remote/<bookId>.epub` | Downloaded books from iCloud / Dropbox / OneDrive | `completeUntilFirstUserAuthentication` | **No** (`isExcludedFromBackup`; re-downloadable) |
| `Application Support/Books/local/<uuid>.epub` | Books imported from Files / share sheet | `completeUntilFirstUserAuthentication` | Yes (only copy) |
| `Caches/Covers/<bookId>.jpg` | Cover thumbnails | default | No (regenerable from source) |

Never store books in `Documents/` unless we deliberately enable Files-app visibility (`UIFileSharingEnabled`) — out of scope for v1.
