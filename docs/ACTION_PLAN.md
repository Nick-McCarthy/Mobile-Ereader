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
- [ ] **P0.5 Compliance skeleton** — `PrivacyInfo.xcprivacy`, `ITSAppUsesNonExemptEncryption = NO`, Data Protection entitlement, no ATS exceptions. See [`SECURITY_AND_APP_STORE.md`](SECURITY_AND_APP_STORE.md).
- [x] **P0.6 CI** — `ci.yml` per [`CI_AND_BUILD.md`](CI_AND_BUILD.md#githubworkflowsciyml-every-push-and-pull-request): pinned macOS image + Xcode, SPM cache, XcodeGen, lint, unit + UI tests on a simulator, `.xcresult` artifact. Repository variables for the public app ids.
  *Done when:* a PR shows a green check and downloadable test results.

## Phase 1 — Local data foundation

- [ ] **P1.1 Database & migrations** — GRDB `DatabaseQueue` in Application Support with file protection; migration v1 creating all tables in [`DATA_MODEL.md`](DATA_MODEL.md) incl. FTS5 + triggers.
  *Done when:* migration unit tests pass on an in-memory DB; FTS search returns rows by title and author.
- [ ] **P1.2 Repositories** ∥ — `BookRepository`, `CollectionRepository`, `SeriesRepository`, `BookmarkRepository`, `ReadingPositionRepository` with async `observe…` APIs.
- [ ] **P1.3 EPUB metadata parser** ∥ — OPF parsing (title, authors + roles + file-as, date, series, cover href) per [`EPUB_METADATA.md`](EPUB_METADATA.md); placeholders for missing fields; cover thumbnail generation; hardening limits.
  *Done when:* fixture tests cover EPUB 2, EPUB 3, missing fields, each cover-discovery strategy, and malformed archives (no crash).
- [ ] **P1.4 Author name normalisation** ∥ — stored-format detection, component parsing, `AuthorNameFormatter` with the three display modes.
  *Done when:* the tricky-names fixture table in `EPUB_METADATA.md` passes.
- [ ] **P1.5 Local import** — Files-app import (`.fileImporter` for `.epub`) and "Open in…" handling (`CFBundleDocumentTypes` for `org.idpf.epub-container`); copy into `Books/local/`, parse, insert.
  *Done when:* importing a fixture EPUB shows it in the DB with cover and metadata. This gives a usable app before any cloud source exists (also useful for App Review).

## Phase 2 — Book sources (iCloud Drive, Dropbox, OneDrive) & sync

The user can link any combination of the three. Spec: [`REMOTE_SOURCES.md`](REMOTE_SOURCES.md).

- [ ] **P2.1 Source abstraction** — `RemoteSource` protocol, `RemoteFile` / `RemoteChange` / `SyncCursor` types, `library_source` repository, `FakeRemoteSource` for tests.
- [ ] **P2.2 OAuth + Keychain** — shared PKCE flow on `ASWebAuthenticationSession` (state check, code exchange, refresh, revoke), `TokenStore` on the Keychain.
  *Done when:* unit tests cover PKCE generation, state mismatch rejection, refresh-before-expiry, and that tokens never touch UserDefaults or the DB.
- [ ] **P2.3 Remote ZIP reader** — provider-agnostic `ByteRangeReading` → EOCD / central-directory / entry fetch, inflate, ZIP64 support, full-download fallback.
  *Done when:* reads metadata from fixture EPUBs served by a fake ranged reader in tests, issuing ≤5 reads per book.
- [ ] **P2.4 iCloud Drive / Files adapter** ∥ — folder picker, bookmark persistence + security-scoped access, enumeration incl. `.icloud` placeholders, coordinated fetch + evict for metadata, copy-to-sandbox download.
- [ ] **P2.5 Dropbox adapter** ∥ — app key config + URL scheme, sign-in, folder browser, recursive `list_folder` with saved cursor (incl. `reset`), ranged and full download.
- [ ] **P2.6 OneDrive adapter** ∥ — Entra client id config + redirect, sign-in, folder browser, BFS `children` walk (+ `delta` on personal accounts), ranged and full download via pre-authenticated URL.
  *Done when (P2.4–P2.6):* each adapter passes tests against sanitised recorded responses (or a temp directory for iCloud), including pagination, deletions, and auth expiry.
- [ ] **P2.7 Sync engine** — provider-agnostic: diff (new / changed / missing), bounded-concurrency metadata fetch, respects `userEditedFields`, saves cursor only on success, progress stream, cancellation, idempotent resume, multiple sources.
  *Done when:* fake-source tests cover nested folders, pagination, cursor resume, deletions, version changes, rate-limit retry, and two sources linked at once.
- [ ] **P2.8 Sources UI** — Settings *Book Sources* section (link / change folder / unlink per service, with the outcome-stating unlink confirmation), in-app folder browser for Dropbox and OneDrive, *Sync Now* with per-source progress, library banner, re-link prompts.
- [ ] **P2.9 On-demand download** — `DownloadManager` actor; tap-to-download with progress, cancel, atomic move, backup exclusion; *Remove Download*.
- [ ] **P2.10 Unlink & detached books** — per [`REMOTE_SOURCES.md`](REMOTE_SOURCES.md#unlinking--detached-books): remote files untouched; not-downloaded books deleted; downloaded books detached (backup flag cleared); deleting a detached book's file deletes the book; launch-time integrity pass; re-attach on re-link.
  *Done when:* tests cover unlink with mixed downloaded/not-downloaded books, cascade cleanup, Remove Download on a detached book, a missing detached file, and re-link re-attachment without duplicates.

## Phase 3 — Library UI

- [ ] **P3.1 Grid & List views** with download state badges, placeholder covers, progress %.
- [ ] **P3.2 Sort menu** — Recently viewed, Title, Author, Publication date, Downloaded/Not downloaded; asc/desc; persisted.
- [ ] **P3.3 Search bar** — FTS5-backed, debounced, both author orders.
- [ ] **P3.4 Collections view mode** — grouped accordion inside the library (shares component with P4.1).
- [ ] **P3.5 Tap behaviour** — open if downloaded, otherwise download then open.
- [ ] **P3.6 Long-press menu** — Edit Details sheet (incl. author stored format & custom cover), Add to Collection, Add to Series, Download/Remove Download, Remove from Library.
- [ ] **P3.7 Empty states & accessibility pass** (Dynamic Type, VoiceOver, dark mode).
  *Phase done when:* every library item in the concept works end-to-end against the local DB and at least one linked source of each kind.

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
- [ ] **P6.4 Provider approvals** — apply for Dropbox production status; complete Microsoft publisher verification. Both are free. See [`SECURITY_AND_APP_STORE.md`](SECURITY_AND_APP_STORE.md#provider-requirements).
- [ ] **P6.5 App Store assets** — icon, screenshots (no copyrighted covers), privacy label, privacy policy page, reviewer notes + demo account.
- [ ] **P6.6 Release workflow** — `release.yml` per [`CI_AND_BUILD.md`](CI_AND_BUILD.md#githubworkflowsreleaseyml-manual-workflow_dispatch-or-v-tags-on-main-only): signing secrets in a protected `release` environment, archive, export, upload to TestFlight. Set this up early (after Phase 1) so the owner can test on a real iPhone throughout.
- [ ] **P6.7 TestFlight beta → App Store submission.**

## Later / nice-to-have (not in concept, don't build without asking)
- Background sync (`BGAppRefreshTask`), multiple root folders per source, cross-source duplicate detection, built-in Google Drive (needs restricted-scope assessment), WebDAV / OPDS servers (Calibre-Web, Kavita), highlights & notes, iCloud sync of reading positions/bookmarks, per-book reader preferences, iPad layout, widgets, text-to-speech (Readium TTS).

## Open questions for the owner
1. **Distribution:** personal use only, or public App Store? (Public needs Dropbox production approval and Microsoft publisher verification, both free.)
2. **Bundled fonts:** any specific fonts wanted beyond system serif/sans and an accessibility font?
