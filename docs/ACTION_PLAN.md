# Action Plan — Native iPhone E-reader

Source requirements: [`/Concept.md`](../Concept.md). Supporting specs are indexed in [`/Agents.md`](../Agents.md).

Each task has an id (`P<phase>.<n>`), a short description, and **Done when** acceptance criteria. Tick the box when merged. Phases are ordered by dependency; tasks inside a phase can often run in parallel (noted with ∥).

---

## Phase 0 — Prerequisites & project setup

> iOS apps must be built with Xcode on macOS. **Decision:** development happens on Windows and every build, test run, and TestFlight upload runs on **GitHub Actions macOS runners**. See [`CI_AND_BUILD.md`](CI_AND_BUILD.md). Because CI is the only build machine, **P0.6 comes before any app code**.

- [x] **P0.1 Bundle identifier** — decided: **`io.github.nick-mccarthy.ereader`**. Used in `project.yml` from the start. Registration is deferred (see P0.1a–c); simulator builds in CI don't need it.
- [ ] **P0.1a Apple App ID** — *deferred until the first TestFlight build (P6.6).* Register the identifier above as an explicit App ID with the **Data Protection** capability (Complete Until First User Authentication). Needs a paid Apple Developer Program membership.
- [ ] **P0.1b Dropbox app** — *deferred until P2.5.* App Console: scoped access, Full Dropbox, read-only scopes. Store the app key as the `DROPBOX_APP_KEY` repository variable.
- [ ] **P0.1c Microsoft Entra app registration** — *deferred until P2.6.* Personal + work/school accounts, iOS public client, redirect `msauth.io.github.nick-mccarthy.ereader://auth`. Store the client id as the `MICROSOFT_CLIENT_ID` repository variable. iCloud Drive needs no setup.
- [x] **P0.2 Repo scaffolding** — `.gitignore` (Xcode, SPM, `Secrets.xcconfig`), `.swift-format`, `Config/Secrets.example.xcconfig`, README with build steps.
- [x] **P0.3 Xcode project** — SwiftUI app target `Ereader` (iOS 17+, iPhone only, portrait + landscape), local packages `Core`, `Persistence`, `EPUBMetadata`, `RemoteSources`, `BookStorage` per [`ARCHITECTURE.md`](ARCHITECTURE.md#module-layout). Swift 6 strict concurrency on. Defined in XcodeGen `project.yml` (required; `.xcodeproj` git-ignored).
  *Done when:* empty app with three tabs (Library / Collections / Settings) builds in CI; `swift test` passes in every package; a UI-test screenshot of the app shows up in the CI artifact.
- [x] **P0.4 Dependencies** — add via SPM and pin: Readium Swift Toolkit 3.11.1 (app target), GRDB 7.12.0 and Readium's ZIPFoundation fork 3.0.2 (`EreaderKit`). Commit `Packages/EreaderKit/Package.resolved` (pins the whole graph); CI enforces it. (No vendor auth SDKs; see [`ARCHITECTURE.md`](ARCHITECTURE.md#tech-stack-decision).)
- [x] **P0.5 Compliance skeleton** — `PrivacyInfo.xcprivacy`, `ITSAppUsesNonExemptEncryption = NO`, Data Protection entitlement, no ATS exceptions, all checked in CI by `scripts/check-compliance.sh`. See [`SECURITY_AND_APP_STORE.md`](SECURITY_AND_APP_STORE.md).
- [x] **P0.6 CI** — `ci.yml` per [`CI_AND_BUILD.md`](CI_AND_BUILD.md#githubworkflowsciyml-every-push-and-pull-request): pinned macOS image + Xcode, SPM cache, XcodeGen, lint, unit + UI tests on a simulator, `.xcresult` artifact. Repository variables for the public app ids.
  *Done when:* a PR shows a green check and downloadable test results.

## Phase 1 — Local data foundation

- [x] **P1.1 Database & migrations** — GRDB `DatabaseQueue` in Application Support with file protection; migration v1 creating all tables in [`DATA_MODEL.md`](DATA_MODEL.md) incl. FTS5 + triggers.
  *Done when:* migration unit tests pass on an in-memory DB; FTS search returns rows by title and author.
- [x] **P1.2 Repositories** ∥ — `BookRepository`, `CollectionRepository`, `SeriesRepository`, `BookmarkRepository`, `ReadingPositionRepository` with async `observe…` APIs.
- [x] **P1.3 EPUB metadata parser** ∥ — OPF parsing (title, authors + roles + file-as, date, series, cover href) per [`EPUB_METADATA.md`](EPUB_METADATA.md); placeholders for missing fields; cover thumbnail generation; hardening limits.
  *Done when:* fixture tests cover EPUB 2, EPUB 3, missing fields, each cover-discovery strategy, and malformed archives (no crash).
- [x] **P1.4 Author name normalisation** ∥ — stored-format detection, component parsing, `AuthorNameFormatter` with the three display modes.
  *Done when:* the tricky-names fixture table in `EPUB_METADATA.md` passes.
- [x] **P1.5 Local import** — Files-app import (`.fileImporter` for `.epub`) and "Open in…" handling (`CFBundleDocumentTypes` for `org.idpf.epub-container`); copy into `Books/local/`, parse, insert.
  *Done when:* importing a fixture EPUB shows it in the DB with cover and metadata. This gives a usable app before any cloud source exists (also useful for App Review).

## Phase 2 — Book sources (iCloud Drive, Dropbox, OneDrive) & sync

The user can link any combination of the three. Spec: [`REMOTE_SOURCES.md`](REMOTE_SOURCES.md).

- [x] **P2.1 Source abstraction** — `RemoteSource` protocol, `RemoteFile` / `RemoteChange` / `SyncCursor` types, `library_source` repository, `FakeRemoteSource` for tests.
- [x] **P2.2 OAuth + Keychain** — shared PKCE flow on `ASWebAuthenticationSession` (state check, code exchange, refresh, revoke), `TokenStore` on the Keychain.
  *Done when:* unit tests cover PKCE generation, state mismatch rejection, refresh-before-expiry, and that tokens never touch UserDefaults or the DB.
- [x] **P2.3 Remote ZIP reader** — provider-agnostic `ByteRangeReading` → EOCD / central-directory / entry fetch, inflate, ZIP64 support, full-download fallback.
  *Done when:* reads metadata from fixture EPUBs served by a fake ranged reader in tests, issuing ≤5 reads per book.
- [x] **P2.4 iCloud Drive / Files adapter** ∥ — folder picker, bookmark persistence + security-scoped access, enumeration incl. `.icloud` placeholders, coordinated fetch + evict for metadata, copy-to-sandbox download.
- [ ] **P2.5 Dropbox adapter** ∥ — app key config + URL scheme, sign-in, folder browser (the in-app browser UI moved here from P2.8; add the adapter to `BookSources.remote(for:)` and `isAvailable`), recursive `list_folder` with saved cursor (incl. `reset`), ranged and full download.
- [ ] **P2.6 OneDrive adapter** ∥ — Entra client id config + redirect, sign-in, folder browser (reuse the P2.5 browser UI), BFS `children` walk (+ `delta` on personal accounts), ranged and full download via pre-authenticated URL.
  *Done when (P2.4–P2.6):* each adapter passes tests against sanitised recorded responses (or a temp directory for iCloud), including pagination, deletions, and auth expiry.
- [x] **P2.7 Sync engine** — provider-agnostic: diff (new / changed / missing), bounded-concurrency metadata fetch, respects `userEditedFields`, saves cursor only on success, progress stream, cancellation, idempotent resume, multiple sources.
  *Done when:* fake-source tests cover nested folders, pagination, cursor resume, deletions, version changes, rate-limit retry, and two sources linked at once.
  *Status:* done in `LibraryServices/SyncEngine.swift` (`SyncEngineTests`). Adds `book.localFileVersion` (migration v2) so a changed downloaded book reports `isDownloadStale`. Details in [`REMOTE_SOURCES.md`](REMOTE_SOURCES.md#as-implemented-p27-libraryservicessyncengineswift).
- [x] **P2.8 Sources UI** — Settings *Book Sources* section (link / change folder / unlink per service, with the outcome-stating unlink confirmation), in-app folder browser for Dropbox and OneDrive, *Sync Now* with per-source progress, library banner, re-link prompts.
  *Status:* done for iCloud Drive / Files, which now links, syncs and unlinks from Settings (`UITests/BookSourcesTests`, `LibraryServicesTests/BookSourcesTests`). The Dropbox and OneDrive rows show "Coming in a later version"; their sign-in and the in-app folder browser move to P2.5 and P2.6, since they can't be used before those adapters exist. Details in [`UI_SPEC.md`](UI_SPEC.md#settings).
- [x] **P2.9 On-demand download** — `DownloadManager` actor; tap-to-download with progress, cancel, atomic move, backup exclusion; *Remove Download*.
  *Status:* the `DownloadManager` actor is done (`DownloadManagerTests`). Details in [`REMOTE_SOURCES.md`](REMOTE_SOURCES.md#as-implemented-p29-libraryservicesdownloadmanagerswift). The tap and menu items are wired up in P3.5 and P3.6, once P2.8 lets a source be linked.
- [x] **P2.10 Unlink & detached books** — per [`REMOTE_SOURCES.md`](REMOTE_SOURCES.md#unlinking--detached-books): remote files untouched; not-downloaded books deleted; downloaded books detached (backup flag cleared); deleting a detached book's file deletes the book; launch-time integrity pass; re-attach on re-link.
  *Done when:* tests cover unlink with mixed downloaded/not-downloaded books, cascade cleanup, Remove Download on a detached book, a missing detached file, and re-link re-attachment without duplicates.
  *Status:* done (`SourceUnlinkTests`; Remove Download on a detached book is in `DownloadManagerTests`). Details in [`REMOTE_SOURCES.md`](REMOTE_SOURCES.md#as-implemented-p210-libraryservicessourceunlinkerswift). The Settings UI that calls it is P2.8.

## Audit stage 1 fixes
From [`audit-stage-1-findings.md`](audit-stage-1-findings.md). High before P2.5; Medium before P2.7 unless noted; each with its own test and CI run.

- [x] **A1.1 Bound remote fetches by the limits** (F-B1 High, F-B3, F-C2) — reject entries whose declared compressed size exceeds the allowed uncompressed size plus deflate overhead; clamp `expectEntry` hints to `maxEntryBytes`; overflow-safe range arithmetic in `RangeCache`; throw on a negative `length()`; document the one-read-at-a-time assumption.
  *Done when:* tests with a lying central directory (huge compressed size, `Int64.max`) fail with `entryTooLarge` and never request more than the limit.
- [x] **A1.2 Orphaned Keychain cleanup** (F-A1) — at every launch, delete Dropbox / OneDrive Keychain items whose source id isn't the linked source of that kind (`OrphanedTokenCleanup`). Comparing with the database, rather than a first-launch flag, also covers a lost or reset database.
  *Done when:* a test with an in-memory store shows orphaned items are removed once and linked sources' items are kept.
- [x] **A1.3 Token store failure paths** (F-A2, F-A3, F-A4) — undecodable items become `needsRelink` and are deletable by `signOut`; after a successful refresh whose save fails, keep the fresh tokens in memory and retry the save; replace the `status: 0` sentinel with explicit error cases.
  *Done when:* tests cover a corrupt item, a failing save after refresh, and sign-out of a corrupt item.
- [x] **A1.4 Encoding-proof entity guard** (F-B2) — abort parsing from the `XMLParserDelegate` entity-declaration callbacks instead of (or as well as) the byte search.
  *Done when:* UTF-16 and UTF-8 entity fixtures are both rejected with `malformedXML`.
- [x] **A1.5 Cancellable, off-actor folder walk** (F-C1) — run the `FilesListing` walk off the actor's executor (`@concurrent` or a dedicated task), check cancellation per item, and stream results instead of collecting them all.
  *Done when:* a test cancels a walk of a large temporary tree and the stream ends with `cancelled` promptly.
- [x] **A1.6 Test fixes** (F-D1, F-D4) — rewrite the shared-refresh test with a gated fake HTTP client (no sleep) and a short `expires_in` so a non-shared refresh would make two requests; add iCloud tests for a file deleted between listings and for the stale-bookmark path (or document why it can't be triggered).
  *Done when:* the shared-refresh test fails if sharing is removed.
- [x] **A1.7 Import completeness** (F-D2, F-D3) — save series from EPUB metadata on import; detect a re-import of the same book (package identifier, else content hash) and offer to keep or replace instead of duplicating.
  *Done when:* importer tests cover series and duplicate import.
- [x] **A1.8 Library view hygiene** (F-E1, F-E2, F-E4, F-E5) — async, cached cover loading off the main actor; per-import state in `BookImportController`; a stored `@Bindable`-friendly alert flag instead of `Binding(get:set:)`; show an error state when the library can't be read. F-E1 is done (`CoverImageCache`); the Low items F-E2, F-E4, and F-E5 move to Phase 3 with the Library rework.
- [x] **A1.9 Accessibility automation** (F-F1, F-F2) — add a UI test running `performAccessibilityAudit()` on the Library (empty and with a seeded book in `-UITestMode`); hide the decorative cover from VoiceOver; label the import progress indicator.
  *Done when:* the audit test passes in CI.
- [x] **A1.10 Privacy-manifest coverage** (F-G1, F-G2) — list the required-reason APIs used by our sources and the Readium modules we link at the pinned version, add any missing declarations (System Boot Time if confirmed), and extend `check-compliance.sh` to grep our sources for required-reason APIs and fail when the manifest lacks the category; prove each compliance check fails on a deliberately broken branch. Re-check on every Readium bump.
  *Done when:* CI fails on a branch that adds an undeclared `UserDefaults` or `systemUptime` use.
  *Status:* done. A throwaway branch that added `ProcessInfo.processInfo.systemUptime` failed the "Compliance checks (source)" step in CI run 46086173090 ("sources use a SystemBootTime API … doesn't declare it"); the branch was then deleted. `UserDefaults` is already declared, so only an undeclared category can fail the check.

## Phase 3 — Library UI

- [x] **P3.1 Grid & List views** with download state badges, placeholder covers, progress %.
  *Status:* done. Grid and list with a persisted *View* menu, generated placeholder covers, download badges driven by `DownloadManager` progress, and reading progress. Details in [`UI_SPEC.md`](UI_SPEC.md#library) (as implemented, P3.1). The source glyph and detached/missing details in rows come with P3.6 and P3.7.
- [x] **P3.2 Sort menu** — Recently viewed, Title, Author, Publication date, Downloaded/Not downloaded; asc/desc; persisted.
  *Status:* done. *Sort* menu with key and direction in `@AppStorage`, driving `LibraryQuery`. Details in [`UI_SPEC.md`](UI_SPEC.md#library) (as implemented, P3.2).
- [ ] **P3.3 Search bar** — FTS5-backed, debounced, both author orders.
- [ ] **P3.4 Collections view mode** — grouped accordion inside the library (shares component with P4.1).
- [ ] **P3.5 Tap behaviour** — open if downloaded, otherwise download then open.
- [ ] **P3.6 Long-press menu** — Edit Details sheet (incl. author stored format & custom cover), Add to Collection, Add to Series, Download/Remove Download, Remove from Library.
- [ ] **P3.7 Empty states & accessibility pass** (Dynamic Type, VoiceOver, dark mode).
  *Known issue:* the accessibility audit sometimes reports the captions of a grid cell in the second row as "Dynamic Type font sizes are partially unsupported" (seen in P3.1 and P3.2 runs, depending on which book is there). Most likely `LazyVGrid` unloads cells that larger type pushes off screen, so the audit can't measure them. `AccessibilityAuditTests.testLibraryGridPassesAudit` passes with the seeded order; `LibrarySortTests` audits the list instead. Find a fix that keeps the grid lazy for large libraries.
  *Phase done when:* every library item in the concept works end-to-end against the local DB and at least one linked source of each kind.

## Phase 4 — Collections, series & settings

- [ ] **P4.1 Collections tab** — accordion of collections, horizontal cover rows, See All grid, rename/delete/reorder; *Collections | Series* switch with series ordering. Layout rationale in [`UI_SPEC.md`](UI_SPEC.md#collections-tab).
- [ ] **P4.2 Create collection / series from Settings** + manage lists.
- [ ] **P4.3 Author name format setting** with live preview; applies app-wide immediately.
- [ ] **P4.4 Storage & privacy settings** — downloads size, Remove All Downloads, Delete All App Data, licences, privacy policy link.
- [x] **P4.5 Series auto-population** from `calibre:series` / EPUB 3 collection metadata during sync (non-destructive to user assignments).
  *Status:* done with P2.7: sync (like local import) saves the EPUB's series unless the user already put the book in a series.

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
- [ ] **P6.4 Provider approvals** — apply for Dropbox production status; complete Microsoft publisher verification. Both are free. See [`SECURITY_AND_APP_STORE.md`](SECURITY_AND_APP_STORE.md#provider-requirements).
- [ ] **P6.5 App Store assets** — icon, screenshots (no copyrighted covers), privacy label, privacy policy page, reviewer notes + demo account.
- [ ] **P6.6 Release workflow** — `release.yml` per [`CI_AND_BUILD.md`](CI_AND_BUILD.md#githubworkflowsreleaseyml-manual-workflow_dispatch-or-v-tags-on-main-only): signing secrets in a protected `release` environment, archive, export, upload to TestFlight. Set this up early (after Phase 1) so the owner can test on a real iPhone throughout.
- [ ] **P6.7 TestFlight beta → App Store submission.**

## Later / nice-to-have (not in concept, don't build without asking)
- Background sync (`BGAppRefreshTask`), multiple root folders per source, cross-source duplicate detection, built-in Google Drive (needs restricted-scope assessment), WebDAV / OPDS servers (Calibre-Web, Kavita), highlights & notes, iCloud sync of reading positions/bookmarks, per-book reader preferences, iPad layout, widgets, text-to-speech (Readium TTS).

## Open questions for the owner
1. **Distribution:** personal use only, or public App Store? (Public needs Dropbox production approval and Microsoft publisher verification, both free.)
2. **Bundled fonts:** any specific fonts wanted beyond system serif/sans and an accessibility font?
