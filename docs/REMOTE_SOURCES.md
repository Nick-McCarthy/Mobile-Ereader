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
- **Unlink:** revoke server-side where the API allows (Dropbox `POST /2/auth/token/revoke`; Microsoft has no per-token revoke for consumer apps, so delete the tokens locally and link to account.live.com/consent/Manage in the UI). Then delete the Keychain items and the `library_source` row, and (user's choice) remove or keep that source's books.

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
- Metadata needs the bytes locally. For each new or changed item: do a coordinated read (`NSFileCoordinator`, `.withoutChanges`), which makes iCloud fetch the file. Parse it in place with ZIPFoundation, then call `FileManager.evictUbiquitousItem(at:)` if it wasn't downloaded before, to avoid filling the device. Limit to 2 concurrent fetches.
- "Download" in the library means copying the file into the app's own `Books/remote/` folder (offline-safe, protected, consistent with the other sources).

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

### Robustness
- Exponential backoff with jitter on `429` / `503` / provider rate-limit errors. Honour `Retry-After`.
- On `401`: refresh once, retry once, then mark the source *needs re-link* and show a prompt.
- All endpoints are HTTPS (`*.dropboxapi.com`, `*.dropbox.com`, `graph.microsoft.com`, `login.microsoftonline.com`, OneDrive download hosts), so there are no ATS exceptions.

## Downloading a book (tap in library)
`DownloadManager` actor: `RemoteSource.download(_:to:progress:)` → temp file → verify size → atomic move to `Books/remote/<bookId>.epub` → set file protection and `isExcludedFromBackup`. Show inline progress; tap again to cancel; open the reader when done. *Remove Download* frees space and keeps metadata, bookmarks and progress.

## Testing
- Each adapter has a fake: `FakeRemoteSource` (configurable tree, pagination, cursors, deletions, 429s, auth expiry) for `SyncEngine` tests.
- Adapter unit tests decode recorded **sanitised** JSON fixtures of Dropbox and Graph responses. Never hit real APIs in CI. Never commit real tokens or account data.
- The iCloud adapter is tested against a temporary local directory tree (including fake `.icloud` placeholder names).
