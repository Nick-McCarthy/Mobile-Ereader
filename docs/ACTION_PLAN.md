# Action Plan — Native iPhone E-reader

Source requirements: [`/Concept.md`](../Concept.md). Supporting specs are indexed in [`/Agents.md`](../Agents.md).

Each task has an id (`P<phase>.<n>`), a short description, and **Done when** acceptance criteria. Tick the box when merged. Phases are ordered by dependency; tasks inside a phase can often run in parallel (noted with ∥).

---

## Phase 0 — Prerequisites & project setup

> ⚠️ iOS apps must be built with **Xcode on macOS**. The repo currently lives on a Windows machine; development needs a Mac (local, remote such as MacinCloud, or GitHub Actions `macos-latest` runners for CI builds). Docs and pure-Swift package logic can be authored anywhere, but nothing can be run on a simulator/device without macOS.

- [ ] **P0.1 Accounts** — Apple Developer Program membership (needed for device testing beyond 7-day free provisioning, TestFlight, App Store); Google Cloud project with the Drive API enabled and an OAuth consent screen (Testing mode, add your Google account as a test user); iOS OAuth client id created for the bundle id.
  *Done when:* bundle id (e.g. `com.<you>.ereader`) is registered and the OAuth client id is stored in a local, git-ignored `Config/Secrets.xcconfig`.
- [ ] **P0.2 Repo scaffolding** — `.gitignore` (Xcode, SPM, `Secrets.xcconfig`), `.swift-format`, `Config/Secrets.example.xcconfig`, README with build steps.
- [ ] **P0.3 Xcode project** — SwiftUI app target `Ereader` (iOS 17+, iPhone only, portrait + landscape), local packages `Core`, `Persistence`, `EPUBMetadata`, `DriveSync`, `BookStorage` per [`ARCHITECTURE.md`](ARCHITECTURE.md#module-layout). Swift 6 strict concurrency on. Optionally XcodeGen `project.yml`.
  *Done when:* empty app with three tabs (Library / Collections / Settings) builds and runs; `swift test` passes in every package.
- [ ] **P0.4 Dependencies** — add via SPM and pin: Readium Swift Toolkit, GRDB, GoogleSignIn-iOS, ZIPFoundation.
- [ ] **P0.5 Compliance skeleton** — `PrivacyInfo.xcprivacy`, `ITSAppUsesNonExemptEncryption = NO`, Data Protection entitlement, no ATS exceptions. See [`SECURITY_AND_APP_STORE.md`](SECURITY_AND_APP_STORE.md).
- [ ] **P0.6 CI** — GitHub Actions on `macos-latest`: build + unit tests on every PR.

## Phase 1 — Local data foundation

- [ ] **P1.1 Database & migrations** — GRDB `DatabaseQueue` in Application Support with file protection; migration v1 creating all tables in [`DATA_MODEL.md`](DATA_MODEL.md) incl. FTS5 + triggers.
  *Done when:* migration unit tests pass on an in-memory DB; FTS search returns rows by title and author.
- [ ] **P1.2 Repositories** ∥ — `BookRepository`, `CollectionRepository`, `SeriesRepository`, `BookmarkRepository`, `ReadingPositionRepository` with async `observe…` APIs.
- [ ] **P1.3 EPUB metadata parser** ∥ — OPF parsing (title, authors + roles + file-as, date, series, cover href) per [`EPUB_METADATA.md`](EPUB_METADATA.md); placeholders for missing fields; cover thumbnail generation; hardening limits.
  *Done when:* fixture tests cover EPUB 2, EPUB 3, missing fields, each cover-discovery strategy, and malformed archives (no crash).
- [ ] **P1.4 Author name normalisation** ∥ — stored-format detection, component parsing, `AuthorNameFormatter` with the three display modes.
  *Done when:* the tricky-names fixture table in `EPUB_METADATA.md` passes.
- [ ] **P1.5 Local import** — Files-app import (`.fileImporter` for `.epub`) and "Open in…" handling (`CFBundleDocumentTypes` for `org.idpf.epub-container`); copy into `Books/local/`, parse, insert.
  *Done when:* importing a fixture EPUB shows it in the DB with cover and metadata. This gives a usable app before Google Drive exists (also useful for App Review).

## Phase 2 — Google Drive link & sync

- [ ] **P2.1 Google sign-in** — GoogleSignIn config, *Link* / *Unlink* (revoke) in Settings, incremental `drive.readonly` scope request, token refresh. Show linked email.
- [ ] **P2.2 Drive client** — `DriveClient` protocol + `URLSession` implementation: list folders, list children (paged), shared drives, ranged media GET, full download; retries/backoff per [`GOOGLE_DRIVE_SYNC.md`](GOOGLE_DRIVE_SYNC.md#robustness). `FakeDriveClient` for tests.
- [ ] **P2.3 Remote ZIP reader** — EOCD/central-directory/entry fetch via `Range`, inflate, ZIP64 support, full-download fallback.
  *Done when:* reads metadata from fixture EPUBs served by a fake ranged server in tests, issuing ≤5 requests per book.
- [ ] **P2.4 Folder browser** — My Drive + shared drives, breadcrumbs, *Use This Folder*; persists `drive_root`.
- [ ] **P2.5 Sync engine** — recursive enumeration, diff (new / changed / missing), bounded-concurrency metadata fetch, respects `userEditedFields`, progress stream, cancellation, idempotent resume.
  *Done when:* fake-client tests cover nested folders, pagination, shortcuts/cycles, deletions, md5 changes, rate-limit retry.
- [ ] **P2.6 Sync UI** — *Sync Now* button with progress + last-synced time in Settings; library banner; error surfacing (re-link prompt on auth failure).
- [ ] **P2.7 On-demand download** — `DownloadManager` actor; tap-to-download with progress, cancel, atomic move, backup exclusion; *Remove Download*.

## Phase 3 — Library UI

- [ ] **P3.1 Grid & List views** with download state badges, placeholder covers, progress %.
- [ ] **P3.2 Sort menu** — Recently viewed, Title, Author, Publication date, Downloaded/Not downloaded; asc/desc; persisted.
- [ ] **P3.3 Search bar** — FTS5-backed, debounced, both author orders.
- [ ] **P3.4 Collections view mode** — grouped accordion inside the library (shares component with P4.1).
- [ ] **P3.5 Tap behaviour** — open if downloaded, otherwise download then open.
- [ ] **P3.6 Long-press menu** — Edit Details sheet (incl. author stored format & custom cover), Add to Collection, Add to Series, Download/Remove Download, Remove from Library.
- [ ] **P3.7 Empty states & accessibility pass** (Dynamic Type, VoiceOver, dark mode).
  *Phase done when:* every library item in the concept works end-to-end against the local DB and a linked Drive.

## Phase 4 — Collections, series & settings

- [ ] **P4.1 Collections tab** — accordion of collections, horizontal cover rows, See All grid, rename/delete/reorder; *Collections | Series* switch with series ordering. Layout rationale in [`UI_SPEC.md`](UI_SPEC.md#collections-tab).
- [ ] **P4.2 Create collection / series from Settings** + manage lists.
- [ ] **P4.3 Author name format setting** with live preview; applies app-wide immediately.
- [ ] **P4.4 Storage & privacy settings** — downloads size, Remove All Downloads, Delete All App Data, licences, privacy policy link.
- [ ] **P4.5 Series auto-population** from `calibre:series` / EPUB 3 collection metadata during sync (non-destructive to user assignments).

## Phase 5 — Reader

Spec: [`READER.md`](READER.md).

- [ ] **P5.1 Readium integration** — open publication from local file, present `EPUBNavigatorViewController` in SwiftUI, restore/save locator, update `lastOpenedAt`. Graceful DRM / corrupt-file errors.
- [ ] **P5.2 Chrome & gestures** — tap toggles chrome; horizontal drag only turns pages (never toggles chrome); back button returns to library.
  *Done when:* XCUITest verifies tap shows chrome and swipe does not.
- [ ] **P5.3 "Aa" drawer — Font tab** — font family (incl. bundled fonts), size, line/letter/word/paragraph spacing.
- [ ] **P5.4 "Aa" drawer — Layout tab** — page colour/theme, continuous scrolling, alignment (+ hyphenation), orientation lock.
- [ ] **P5.5 Bookmarks** — add/remove bookmark button with filled state; bookmarks drawer (sorted, tap to jump, swipe to delete).
- [ ] **P5.6 Chapter navigation drawer** — nested TOC with current-chapter highlight.
- [ ] **P5.7 Progress bar** — draggable slider with percentage and chapter preview; navigates on release.
- [ ] **P5.8 Reader QA** — test with EPUB 2, EPUB 3, fixed-layout, RTL, image-heavy and very long books; memory leak check.

## Phase 6 — Hardening & release

- [ ] **P6.1 Security review** against every item in [`SECURITY_AND_APP_STORE.md`](SECURITY_AND_APP_STORE.md); parser fuzzing; log audit.
- [ ] **P6.2 Performance** — library with 5 000 books scrolls at 60/120 fps; sync of 1 000 books completes without memory spikes; cold launch < 1 s on recent devices.
- [ ] **P6.3 Offline behaviour** — downloaded books fully usable in airplane mode; clear messaging for undownloaded ones.
- [ ] **P6.4 Google OAuth decision** — stay in Testing mode (personal use) **or** submit for verification + CASA assessment (public release). See [`GOOGLE_DRIVE_SYNC.md`](GOOGLE_DRIVE_SYNC.md#scope-choice--important).
- [ ] **P6.5 App Store assets** — icon, screenshots (no copyrighted covers), privacy label, privacy policy page, reviewer notes + demo account.
- [ ] **P6.6 TestFlight beta → App Store submission.**

## Later / nice-to-have (not in concept, don't build without asking)
- Background sync (`BGAppRefreshTask`), multiple Drive roots, highlights & notes, iCloud sync of reading positions/bookmarks, per-book reader preferences, iPad layout, widgets, text-to-speech (Readium TTS), OPDS catalogues.

## Open questions for the owner
1. **Distribution:** personal use only (Testing-mode OAuth, weekly re-link) or public App Store (Google restricted-scope verification + annual CASA assessment)?
2. **Unlink behaviour default:** keep Drive books' metadata/bookmarks after unlinking, or remove them?
3. **Bundled fonts:** any specific fonts wanted beyond system serif/sans and an accessibility font?
