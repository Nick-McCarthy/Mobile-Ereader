# Remote Book Sources: iCloud Drive, Dropbox, OneDrive

> **Decision (supersedes the Google Drive requirement in `Concept.md`):** the user chooses where their books live: **iCloud Drive**, **Dropbox**, or **Microsoft OneDrive**. Google Drive was dropped as a built-in service because its `drive.readonly` scope is *restricted* (a public release would need Google verification plus a paid annual CASA security assessment). Google Drive users can still use the iCloud Drive / Files option if the Google Drive app is installed (see below).

The concept's behaviour still applies to every source: the user links a service, picks a folder (or the whole drive), and the app recursively finds every `.epub` under it, extracts title / author / publication date / cover into the local database, and downloads books on demand.

## Source model

Each source kind has an adapter behind one protocol in the `RemoteSources` package:

```swift
protocol RemoteSource: Sendable {
    var kind: SourceKind { get }                       // .iCloud, .dropbox, .oneDrive
    func link() async throws -> LinkedAccount          // sign in / grant access
    func unlink() async throws                         // revoke + delete credentials
    func listFolders(in folder: RemoteFolder?) async throws -> [RemoteFolder]   // folder browser
    func enumerateEPUBs(under root: RemoteFolder, since cursor: SyncCursor?)
        -> AsyncThrowingStream<RemoteChange, Error>    // .upsert(RemoteFile) / .removed(remoteId) / .cursor(SyncCursor)
    func byteRangeReader(for file: RemoteFile) -> ByteRangeReading?  // nil if ranged reads aren't supported
    func download(_ file: RemoteFile, to destination: URL,
                  progress: @Sendable (Double) -> Void) async throws
}
```

`RemoteFile` holds `remoteId`, `displayPath`, `name`, `size`, `version` (provider-specific change token), `modifiedAt`.

As implemented (P2.1, `RemoteSources/RemoteSource.swift`):
- `enumerateEPUBs` returns a `RemoteChangeStream` of `RemoteChange`: `.reset`, `.upsert(RemoteFile)`, `.removed(remoteId:)`, `.cursor(SyncCursor)`. Every **full** listing (no cursor, or one the provider rejects, such as a Dropbox `reset` or a Graph `410`) starts with `.reset`. After it, any book of that source not upserted before the final `.cursor` is missing from the source. An incremental listing has no `.reset` and reports deletions as `.removed`. Every listing ends with `.cursor`, which the engine saves only after processing everything.
- `ByteRangeReading` lives in Core (so `EPUBMetadata` can use it without depending on `RemoteSources`): `func length() async throws -> Int64` and `func read(_ range: Range<Int64>) async throws -> Data`.
- Errors are `RemoteSourceError`: `.cancelled`, `.needsRelink`, `.rateLimited(retryAfter:)`, `.notFound`.
- `LinkedAccount(label:)` is what Settings shows after linking. `RemoteFolder.root` (id `""`) is the whole drive.
- `library_source` rows are read and written through `LibrarySourceRepository` (Persistence): add (one per service; `.local` is refused), change root (clears the cursor), record sync success (cursor, `ok`, time) or failure (status and message; the cursor is kept). Unlinking is `unlinkSource` (P2.10, below).

- **Linking:** the user can link **any combination** of the three. Each linked source has **one root folder** (a row in `library_source`). *Sync Now* syncs every linked source, each independently.
- **Identity:** a book is unique per `(sourceId, remoteId)`. The same file in two sources shows up as two books (no cross-source de-duplication in v1).

| | iCloud Drive / Files | Dropbox | OneDrive |
|---|---|---|---|
| Developer setup | **None** | App in the Dropbox App Console | App registration in Microsoft Entra (Azure portal) |
| Third-party approval | None | Free production review once past development-mode limits | None required; publisher verification recommended |
| Sign-in | None (folder picker) | OAuth 2.0 + PKCE | OAuth 2.0 + PKCE (Microsoft identity platform) |
| Read-only permissions | Folder picked by user | `files.metadata.read`, `files.content.read`, `account_info.read` | `Files.Read`, `User.Read`, `offline_access` |
| Recursive listing | Local `FileManager` enumeration | `list_folder` with `recursive: true` | Breadth-first `children` walk (or `delta`) |
| Incremental sync | Compare modified date + size | `list_folder/continue` with saved cursor | `delta` link (where supported) |
| Change token (`version`) | `contentModificationDate` + size | `content_hash` | `cTag` |
| Ranged reads (metadata without full download) | No (file is local once iCloud fetches it) | Yes (`Range` on `/files/download`) | Yes (`Range` on the download URL) |

## Authentication (Dropbox & OneDrive)

- **No vendor SDKs.** Both providers support the standard OAuth 2.0 authorisation-code flow with **PKCE** for public (mobile) clients. Implement it once in `RemoteSources/OAuth` using **`ASWebAuthenticationSession`** (system browser sheet: the app never sees the user's password) and `URLSession` for the token exchange.
  - Rejected: SwiftyDropbox and MSAL. They're fine but add large dependencies for features we don't need. Revisit MSAL only if work/school accounts with Conditional Access or broker (Authenticator app) sign-in become a requirement.
- **Tokens:** store the access and refresh tokens in the **Keychain** (`kSecClassGenericPassword`, service `ereader.<kind>`, account = `library_source.id`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). Never put them in UserDefaults, the database, files, or logs. Refresh proactively when within 5 minutes of expiry; on refresh failure, mark the source *needs re-link*.
- **App credentials** (Dropbox app key, Microsoft client id) are not secrets for public clients, but keep them in `Config/Secrets.xcconfig` (git-ignored; a committed `Secrets.example.xcconfig` documents the keys). No client secrets ever ship in the app.
- **Unlink:** revoke server-side where the API allows (Dropbox `POST /2/auth/token/revoke`; Microsoft has no per-token revoke for consumer apps, so delete the tokens locally and link to account.live.com/consent/Manage in the UI). Then delete the Keychain items and the `library_source` row, and apply the library rules in [Unlinking & detached books](#unlinking--detached-books).

### Implementation (P2.2, `RemoteSources/OAuth`)
- `OAuthConfiguration`: authorize / token URLs, client id, redirect URI (its scheme is the callback scheme), scopes, extra authorise parameters, and revocation (`.none` or `.bearerPost(url)`).
- `OAuthClient.signIn(using:)`:
  1. builds the URL with a fresh 16-byte `state` and a PKCE pair (32 random bytes → 43-character verifier, `S256` challenge)
  2. opens it with a `WebAuthenticator`
  3. checks the callback (the `state` must match before anything else is read, including `error`)
  4. exchanges the code with the verifier
  `refresh` keeps the old refresh token if the response omits one. `revoke` posts the bearer token when configured.
- `SystemWebAuthenticator` (iOS) wraps `ASWebAuthenticationSession` with `prefersEphemeralWebBrowserSession = true`. Closing the sheet throws `RemoteSourceError.cancelled`.
- `TokenProvider` (actor, one per linked source):
  - `validAccessToken()` refreshes when fewer than 5 minutes remain, and concurrent callers share one refresh.
  - `forceRefresh()` is for a `401`.
  - `signOut()` revokes on a best-effort basis, then deletes the tokens.
  - A refresh rejected with 400 / 401 (or no refresh token) becomes `RemoteSourceError.needsRelink`. Network errors pass through so a retry can work.
- `TokenStore` → `KeychainTokenStore`: generic password, service `ereader.<kind>`, account `library_source.id`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, data-protection keychain, value = JSON. `storedSourceIds()` lists the accounts that have items.
- Keychain items survive deleting the app, but the database doesn't. At every launch, `OrphanedTokenCleanup` (LibraryServices) deletes Dropbox and OneDrive items whose source id isn't the linked source of that kind (audit A1.2). UI tests (`-UITestMode`) skip it and never touch the Keychain. `OAuthTokens` redacts itself in `description`. Tests use `InMemoryTokenStore` (RemoteSourcesTesting) and check the Keychain query attributes rather than the real Keychain, which unsigned `swift test` binaries can't use.
- All HTTP goes through `HTTPClient` (`URLSession.ephemeralClient`: no cookies, cache, or stored credentials), so tests use recorded responses and never reach the network.

### Dropbox specifics
- App Console: **Scoped access**, **Full Dropbox** access type (so the user can choose any folder). Enable only the three read scopes above. Redirect URI: `db-<APP_KEY>://2/token` (register the URL scheme in `Info.plist`).
- Authorise: `https://www.dropbox.com/oauth2/authorize?client_id=…&response_type=code&code_challenge=…&code_challenge_method=S256&token_access_type=offline&redirect_uri=…`. Token: `POST https://api.dropboxapi.com/oauth2/token`.
- **Development mode** caps how many users can link and sets a deadline to apply for production once usage grows. Check the current limits in the App Console. Production approval is a free review of how the app uses the API. No security assessment.
- Folder browser: `POST /2/files/list_folder` `{ "path": "" }` (root is the empty string), filter `.tag == "folder"`.
- Sync: `POST /2/files/list_folder` `{ "path": "<root path or id>", "recursive": true, "include_deleted": false, "limit": 2000 }`, then page with `/2/files/list_folder/continue`. **Save the final `cursor`**: the next sync calls `/continue` with it and receives only changes, including `deleted` entries. Handle `reset` errors by doing a full listing. Use `id` (`id:…`) as `remoteId`; it survives renames and moves.
- Download: `POST https://content.dropboxapi.com/2/files/download` with header `Dropbox-API-Arg: {"path":"id:…"}`. Supports `Range` for metadata reads.

### OneDrive specifics
- Entra app registration: *Accounts in any organizational directory and personal Microsoft accounts*; platform **iOS/macOS** (public client) with redirect `msauth.<bundle-id>://auth`. Delegated permissions `Files.Read`, `User.Read`, `offline_access`, all user-consentable. Complete **publisher verification** (free, needs a Microsoft Partner Network ID) before public release so the consent screen doesn't say "unverified". Some organisations block consent to unverified apps.
- Authorise / token: `https://login.microsoftonline.com/common/oauth2/v2.0/{authorize,token}`.
- Folder browser: `GET https://graph.microsoft.com/v1.0/me/drive/root/children` then `/me/drive/items/{id}/children`, with `$select=id,name,folder,file,size,cTag,lastModifiedDateTime,parentReference`, paging via `@odata.nextLink`.
- Sync (baseline): breadth-first walk of `children` from the root item, keeping entries whose name ends in `.epub`. Track visited ids.
- Sync (optimisation): `GET /me/drive/items/{rootId}/delta`, saving the `@odata.deltaLink` as the cursor. Folder-scoped delta is supported on personal OneDrive. For work/school accounts fall back to the BFS walk (or root-level delta filtered by `parentReference.path`). Handle `410 Gone` / resync responses with a full walk.
- Download: `GET /me/drive/items/{id}/content` returns a 302 to a short-lived pre-authenticated URL (also available as `@microsoft.graph.downloadUrl`). Ranged GETs work on that URL. Don't send the bearer token to the redirected host.

### iCloud Drive / Files specifics
- No sign-in and no iCloud entitlement needed: the user picks a folder with `UIDocumentPickerViewController(forOpeningContentTypes: [.folder])`. The picker opens at iCloud Drive but also shows other installed file providers (Google Drive, Box, and so on). Label the option **"iCloud Drive / Files"** because that's a free bonus path for Google Drive users.
- Persist access with a **bookmark** (`url.bookmarkData()`), stored as a BLOB in `library_source.rootBookmark`. On every use: resolve it, call `startAccessingSecurityScopedResource()`, and stop when done. If the bookmark is stale, re-create it; if it fails to resolve, mark the source *needs re-link*.
- Enumerate with `FileManager.enumerator(at:includingPropertiesForKeys:)` requesting `.contentModificationDateKey`, `.fileSizeKey`, `.ubiquitousItemDownloadingStatusKey`, `.isDirectoryKey`. Not-yet-downloaded iCloud items may appear as hidden placeholders named `.<name>.epub.icloud`, so map those back to the real name.
- `remoteId` = path relative to the root, so a rename looks like remove + add. That's acceptable: reading data is matched by the `isMissingFromSource` flow and the user can merge in a later version.
- Metadata needs the bytes locally. For each new or changed item: do a coordinated read (`NSFileCoordinator`, `.withoutChanges`), which makes iCloud fetch the file. Parse it in place with `ReadiumZIPFoundation`, then call `FileManager.evictUbiquitousItem(at:)` if it wasn't downloaded before, to avoid filling the device. Limit to 2 concurrent fetches.
- "Download" in the library means copying the file into the app's own `Books/remote/` folder (offline-safe, protected, consistent with the other sources).

#### As implemented (P2.4, `RemoteSources/Files`)
- `FilesRemoteSource(bookmark:picker:)` is an actor.
  - `link()` asks a `FolderPicking` for a folder. The app links through SwiftUI's `.fileImporter` instead (P2.8, below).
  - `link(folderAt:)` keeps a bookmark to the folder. The account label is the folder's name.
  - The caller saves `bookmark` to `library_source.rootBookmark` after `link`, after each sync (a stale bookmark is re-created in place), and after `unlink` (which only forgets it).
  - A missing bookmark, one that won't resolve, or a folder that's gone throws `needsRelink`.
- Every listing is a full one: `.reset`, then every book, then a `files:<time>` cursor.
  - The walk runs off the source's actor (`@concurrent`), yields each book as it finds it (in file-system order, not sorted), and checks cancellation before every item, so stopping a sync of a huge folder is prompt (audit A1.5).
  - Ids are paths relative to the picked folder, so listing a sub-folder still gives root-relative ids.
  - Hidden files and folders and package contents are skipped.
  - `.Name.epub.icloud` is listed as `Name.epub`. Its size comes from the real item when the system has it, otherwise nil. A real file wins over a leftover placeholder with the same name: the placeholder is skipped when the real file exists.
  - `version` is `<modified ms>-<size>`.
- Ids containing `.` or `..` are rejected (`notFound`), so a stored id can't reach outside the folder.
- `byteRangeReader` is nil. Metadata uses `download` to a temporary file instead of parsing in place, because `NSFileCoordinator`'s accessor is synchronous and the parser is async.
  - `download` does a coordinated `.withoutChanges` read on its own queue and copies the file.
  - If the file wasn't on the device before, it is evicted again afterwards.
  - Progress is reported only as 0 and 1.
- Tests run against a temporary folder tree with placeholder names (`RemoteSourcesTests/FilesRemoteSourceTests`).

### Linking in the app (P2.8, `LibraryServices/BookSources.swift`)
- `BookSources.remote(for:)` builds the adapter for a linked source: `FilesRemoteSource(bookmark:)` for iCloud, nil for Dropbox and OneDrive until their adapters exist. `syncTargets(for:)` skips sources without an adapter, and `isAvailable(_:)` tells Settings which rows can be linked.
- `linkFolder(at:)` takes the security-scoped folder URL from the system picker and saves an iCloud source: label = folder name, root id `""`, the bookmark, display path `/<name>`.
- `changeFolder(of:to:)` saves a new bookmark and path (and clears the cursor). The same action re-links a folder after `needsRelink`.
- `saveRefreshedBookmarks(_:)` runs after each sync and saves a bookmark the adapter re-created because the old one was stale (`LibrarySourceRepository.saveRootBookmark`).
- The app links with SwiftUI's `.fileImporter` for `.folder` rather than the adapter's `FolderPicking` hook, which stays for callers without SwiftUI.

## Folder browser
- Dropbox and OneDrive: an in-app browser with breadcrumbs, a *This Folder* button, and a *Whole Dropbox/OneDrive* shortcut. Persist the folder id and display path to `library_source`.
- iCloud Drive / Files: the system folder picker.

## Sync algorithm (`SyncEngine` actor, provider-agnostic)
Triggered by **Sync Now** in Settings (and pull-to-refresh in the library; `BGAppRefreshTask` later).

1. For each linked source (sequentially; it's simpler and avoids competing for bandwidth): stream `RemoteChange`s from `enumerateEPUBs(under:since:)`.
2. **Diff** against `book` rows for that source:
   - New `remoteId` → insert a row and queue a metadata fetch.
   - Known id with a different `version` → queue a metadata refresh (respect `userEditedFields`). If downloaded, mark it stale and re-download on next open.
   - `.removed`, or (for full listings) not seen → set `isMissingFromSource = true`. Never hard-delete, so bookmarks and progress are kept.
3. **Fetch metadata** with bounded concurrency (4 for Dropbox/OneDrive, 2 for iCloud). Use the provider's `ByteRangeReading` and `RemoteZipReader` when available, otherwise read the local/coordinated file. See [`EPUB_METADATA.md`](EPUB_METADATA.md#reading-metadata-without-downloading-the-book). One DB transaction per book.
4. Save the new cursor only after the whole listing has been processed, so a crash re-runs the listing (sync is idempotent).
5. Report progress (`source · found N · processed M · errors E`) via `AsyncStream<SyncProgress>` to Settings and the library banner. Support cancellation.

#### As implemented (P2.7, `LibraryServices/SyncEngine.swift`)
- `SyncEngine.sync(_ targets: [SyncTarget], progress:)` returns a `SyncOutcome` per source: `.synced`, `.incomplete(failedBooks:)`, `.needsRelink`, `.failed(message:)`, or `.cancelled`. `run(_:)` wraps it as an `AsyncStream<SyncProgress>`; ending the stream cancels the sync. A second sync while one runs throws `SyncEngineError.alreadySyncing`.
- A `SyncTarget` is a `LibrarySource` plus its `RemoteSource`. The engine re-reads the source row first (the caller's copy may hold an old cursor) and skips a source that has been unlinked.
- The whole listing is collected before anything is written (`Listing.collect`). A listing that fails or ends without `.cursor` changes nothing.
- The diff is applied in one transaction (`BookRepository.applyListing`): new books are inserted with placeholders, books seen again get their path, size and modified date and stop being missing, and books not seen (full listings) or `.removed` are flagged `isMissingFromSource`.
- Metadata is read for new books and books whose `version` differs from `remoteVersion`: ranged reads where `byteRangeReader` exists (falling back to a full download), otherwise a temporary full copy. Up to 4 at once (2 for iCloud). Each book is saved with `BookRepository.updateBook`, which reads and writes in one transaction so an edit made meanwhile isn't lost.
- Saving metadata keeps `userEditedFields`, reading state, the download and memberships. A new version without a cover keeps the old cover. The EPUB's series is saved unless the user already put the book in one (P4.5).
- **Idempotent resume:** `remoteVersion` is set only after a book's metadata is saved. A book that failed (network error, still rate-limited after retries, `notFound`) keeps its old version, the sync ends `.incomplete`, and the cursor isn't saved, so the next sync lists it again and reads only what's left.
- A file that isn't a readable EPUB (`EPUBMetadataError`) keeps its placeholders (or its previous metadata) and gets the new `remoteVersion`, so it isn't read again until it changes. It's counted as `unreadable`, not as an error.
- `RetryPolicy` (4 attempts, 1 s doubling to at most 60 s, jitter 0.5–1) retries `rateLimited` for both listing and metadata. A `Retry-After` is honoured; one longer than the maximum delay isn't waited for.
- `needsRelink` stops that source and records `needsRelink`. Other failures record `error` with a short message (`SyncMessages`) that never contains paths, names or provider responses. Cancelling leaves the source's status and cursor as they were.
- Not yet: re-attaching detached books on re-link (P2.10), and background sync (`BGAppRefreshTask`, later).

### Robustness
- Exponential backoff with jitter on `429` / `503` / provider rate-limit errors. Honour `Retry-After`.
- On `401`: refresh once, retry once, then mark the source *needs re-link* and show a prompt.
- All endpoints are HTTPS (`*.dropboxapi.com`, `*.dropbox.com`, `graph.microsoft.com`, `login.microsoftonline.com`, OneDrive download hosts), so there are no ATS exceptions.

## Downloading a book (tap in library)
`DownloadManager` actor: `RemoteSource.download(_:to:progress:)` → temp file → verify size → atomic move to `Books/remote/<bookId>.epub` → set file protection and `isExcludedFromBackup`. Show inline progress; tap again to cancel; open the reader when done. *Remove Download* frees space and keeps metadata, bookmarks and progress, **except for detached books** (see below), which are removed from the library entirely because they can no longer be re-downloaded.

### As implemented (P2.9, `LibraryServices/DownloadManager.swift`)
- `download(_ bookId:, from: RemoteSource) -> Book`. A book that's downloaded and not `isDownloadStale` is returned as it is. A second call for a book already downloading joins the running download, so it isn't fetched twice.
- The file goes to `Books/remote/<bookId>.partial` (same volume as the final file). Its size must match `fileSize` from the last sync, otherwise `DownloadError.sizeMismatch` (the file probably changed: sync, then retry). Then `BookFileStore.commitDownload` renames it to `<bookId>.epub`, replacing a stale copy in one step, applies Data Protection, and sets `isExcludedFromBackup`.
- The book saves `localFilePath`, `downloadState = downloaded`, and `localFileVersion` = the `remoteVersion` the download started at. If a sync moved the version on meanwhile, the copy is already stale.
- `downloadState` is `downloading` while it runs. On failure it's `failed`; on cancel (`cancel(_:)`, or cancelling the calling task) it goes back to what it was. A stale copy being replaced stays `downloaded` either way, since it's still readable. The partial file is always deleted. The state is restored from a task of its own, because GRDB refuses writes from a cancelled task.
- Rate limits are retried with the sync's `RetryPolicy`. `needsRelink` is passed on to the caller.
- `observeProgress()` streams the progress (0…1) of every running download, for the library's badges.
- `removeDownload(_:)` cancels a running download, then clears `localFilePath`, `localFileVersion`, and `downloadState` before deleting the file, so the database never points at a missing file. A detached book is removed from the library with its file and cover (`.removedFromLibrary`); the UI confirms first. Local imports are refused (`notDownloadable`); they're removed from the library instead.
- Not yet: the Library's tap-to-download and the *Download* / *Remove Download* menu items (P3.5, P3.6); no source can be linked from the UI until P2.8. Downloads use the adapter's foreground `download`; a background `URLSession` comes with the Dropbox and OneDrive adapters if needed. No free-space check yet: that would add the `DiskSpace` required-reason API (`E174.1`) to the privacy manifest.

## Unlinking & detached books
**Decision (owner):** unlinking never touches the user's remote files, and the library keeps only what is still readable.

1. **Remote files are left alone.** The app is read-only. Unlinking revokes or deletes the tokens (or, for iCloud, forgets the folder bookmark) and nothing else. No remote file is moved, renamed, or deleted.
2. **Not-downloaded books from that source are removed from the database** in one transaction when the source is unlinked: the `book` rows, and via cascade their bookmarks, reading position, collection and series memberships, FTS rows, and cover thumbnails. Collections and series themselves are kept even if they become empty.
3. **Downloaded books stay** and become **detached**: `sourceId` is set to null, while `sourceKind`, `remoteId` and `remotePath` are kept. Because the local copy is now the only copy, clear `isExcludedFromBackup` on the file so it's included in device backups. Detached books open and behave like any other downloaded book.
4. **If a detached book's file is deleted, the book is removed from the database.** This covers *Remove Download*, *Remove All Downloads*, and a file found missing or unreadable (checked when opening the book and during a lightweight launch-time integrity pass). The book's bookmarks, position, and memberships go with it. *Remove Download* on a detached book shows a confirmation: "This book is no longer linked to <service>. Removing the download will remove it from your library."
5. **Re-linking the same service** later: before inserting new rows, sync matches detached books by `(sourceKind, remoteId)` and re-attaches them (sets `sourceId`, restores `isExcludedFromBackup`), so bookmarks and progress survive and no duplicates appear. For iCloud, where `remoteId` is a relative path, also require the same `remoteVersion` to re-attach.

### As implemented (P2.10, `LibraryServices/SourceUnlinker.swift`)
- `SourceUnlinker.preview(sourceId:)` gives the confirmation's counts (`notDownloaded`, `downloaded`; "downloaded" means the book has a `localFilePath`).
- `unlink(sourceId:remote:)` first cancels the source's running downloads and waits for them (`DownloadManager.cancelAndWait`), so none finishes onto a removed or detached book. Then it calls `remote.unlink()`. A failure there doesn't stop the unlink: tokens left behind belong to no linked source, so `OrphanedTokenCleanup` deletes them at the next launch.
- `LibrarySourceRepository.unlinkSource(id:)` does rules 2 and 3 in one transaction: delete the books without a file (cascades and the `book_ad` trigger remove their bookmarks, position, memberships and search rows), set `sourceId = NULL` on the rest, and delete the source row. Afterwards the removed books' covers are deleted, and the detached files are put back into backups.
- `DetachedBookCheck.run()` (rule 4) removes detached books whose file is missing or unreadable, with their cover. It runs in `AppEnvironment.prepareAtLaunch`. `removeIfFileMissing(_:)` checks one book; the reader (P5.1) calls it when opening a book. *Remove Download* on a detached book is `DownloadManager.removeDownload` (P2.9).
- Re-attach (rule 5) happens in the sync diff: a listed file with no book in the source, but a detached book of the same kind with that `remoteId` (on iCloud, also the same `remoteVersion`), rejoins the source (`BookListingChanges.reattached`). Its file leaves backups again. If its version differs, its metadata is re-read and the download becomes stale.
- Not yet: the Settings screens that call this (P2.8).

The confirmation dialog for *Unlink* states the outcome up front: "N books that aren't downloaded will be removed from your library. M downloaded books will stay. Your files in <service> won't be changed."

## Testing
- Each adapter has a fake: `FakeRemoteSource` (configurable tree, pagination, cursors, deletions, 429s, auth expiry) for `SyncEngine` tests. It lives in the `RemoteSourcesTesting` package target, which only test targets depend on. Paths double as remote ids; `putFile` / `removeFile` change the tree, and `rateLimitNext`, `expireAuth`, `invalidateCursors`, and `failEnumeration(afterPages:)` inject failures. Its ranged reader counts reads (`rangeReadCount`). The P2.3 "≤5 reads per book" check lives in `EPUBMetadataTests/RemoteZipReaderTests` and uses its own counting reader. Adapters whose server answers a ranged request with `200` should throw `ByteRangeError.rangeNotSupported`, which makes `EPUBMetadataReader` fall back to a full download.
- Adapter unit tests decode recorded **sanitised** JSON fixtures of Dropbox and Graph responses. Never hit real APIs in CI. Never commit real tokens or account data.
- The iCloud adapter is tested against a temporary local directory tree (including fake `.icloud` placeholder names).
