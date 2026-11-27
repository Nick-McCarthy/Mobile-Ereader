# Agents.md

Entry point for AI coding agents working in this repository. Read this first, then open only the helper files relevant to your task.

## Project in one paragraph
A native **iPhone e-reader** (Swift + SwiftUI, iOS 17+) that stores EPUB files on the device and links to the user's choice of **iCloud Drive, Dropbox, and/or OneDrive**: the user picks a folder in each linked service, the app recursively finds every `.epub`, extracts title / author / publication date / cover into a local SQLite database, and downloads books on demand. It has a Library (grid / list / collections views, sort, search, long-press edit menu), Collections, Settings (book sources & sync, author-name format, collections, series), and a Readium-based reader with tap-to-show tools, an "Aa" font/layout drawer, bookmarks, chapter navigation, and a draggable progress bar. It must satisfy Apple's security and App Store requirements.

Original requirements: [`Concept.md`](Concept.md) — the source of truth if anything below conflicts, **except** for decisions recorded here:

- **Book sources:** Concept.md asks for Google Drive. The owner replaced it with a user choice of iCloud Drive, Dropbox, and OneDrive, because Google's restricted Drive scope needs a paid annual security assessment. Rationale in [`docs/REMOTE_SOURCES.md`](docs/REMOTE_SOURCES.md).
- **Unlinking a source:** remote files are never touched. Not-downloaded books from that source are removed from the database. Downloaded books stay (detached), and if a detached book's file is later deleted, the book is removed from the database. Details in [`docs/REMOTE_SOURCES.md`](docs/REMOTE_SOURCES.md#unlinking--detached-books).
- **Builds:** there is no local Mac. All builds, tests, and TestFlight uploads run on GitHub Actions macOS runners. Details in [`docs/CI_AND_BUILD.md`](docs/CI_AND_BUILD.md).

## Helper file index (`/docs`)

| File | Read it when you are… |
|---|---|
| [`docs/ACTION_PLAN.md`](docs/ACTION_PLAN.md) | Picking up work. Phased task list with ids (`P2.5`), acceptance criteria, and open questions. **Start here.** |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Choosing where code goes; the tech stack and why; module layout; on-device file storage. |
| [`docs/DATA_MODEL.md`](docs/DATA_MODEL.md) | Touching the database, sorting, search, collections, series, bookmarks. |
| [`docs/REMOTE_SOURCES.md`](docs/REMOTE_SOURCES.md) | Working on iCloud Drive / Dropbox / OneDrive linking, OAuth + Keychain, folder browsing, sync, or downloads. |
| [`docs/EPUB_METADATA.md`](docs/EPUB_METADATA.md) | Parsing EPUBs, covers, placeholders, remote range-reading, author-name normalisation. |
| [`docs/UI_SPEC.md`](docs/UI_SPEC.md) | Building the Library, Collections, or Settings screens. |
| [`docs/READER.md`](docs/READER.md) | Building the reader: Readium integration, gestures, Aa drawer, bookmarks, TOC, progress bar. |
| [`docs/SECURITY_AND_APP_STORE.md`](docs/SECURITY_AND_APP_STORE.md) | Anything involving network, storage, credentials, untrusted input, privacy manifest, or release. |
| [`docs/CI_AND_BUILD.md`](docs/CI_AND_BUILD.md) | Touching `project.yml`, GitHub Actions workflows, signing, or release; or wondering how to verify your change. |
| [`docs/CONVENTIONS.md`](docs/CONVENTIONS.md) | Writing any code: style, concurrency, testing, git/branch rules, definition of done. |

## Ground rules for agents
1. **Work from the action plan.** Name the task id in your branch and commits; tick the box when done.
2. **Keep docs in sync.** If you change the schema, scopes, architecture, or a spec decision, update the matching file in `/docs` in the same change. If you add a new helper file, add a row to the table above.
3. **Security is a requirement, not a polish step.** Check [`SECURITY_AND_APP_STORE.md`](docs/SECURITY_AND_APP_STORE.md) before touching networking, storage, auth, or EPUB parsing. Tokens live only in the Keychain and are never logged; never add ATS exceptions; treat every EPUB as untrusted.
4. **No new third-party dependencies** beyond Readium (and what it pulls in), GRDB, and Readium's ZIPFoundation fork without the owner's approval.
5. **Never hit real Dropbox or Microsoft APIs in tests**; use `FakeRemoteSource` and sanitised recorded responses. Never commit secrets or copyrighted books.
6. **CI is the only build machine.** Push your branch and use the GitHub Actions result (and its `.xcresult` artifact) as evidence. Never claim something was built or tested based on a local run you couldn't do. Edit `project.yml`, never the generated `.xcodeproj`.
7. **Out-of-scope features** (see "Later" in the action plan) need owner sign-off first.
