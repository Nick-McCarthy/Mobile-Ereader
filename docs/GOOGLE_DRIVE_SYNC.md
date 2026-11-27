# Google Drive Linking & Sync

## Authentication
- SDK: **GoogleSignIn-iOS**. Configure an **iOS OAuth client** in Google Cloud Console; put `GIDClientID` and the reversed-client-id URL scheme in `Info.plist`. The client id is not a secret, but keep it in an `.xcconfig` (`Config/Secrets.xcconfig`, git-ignored, with a committed `Secrets.example.xcconfig`).
- Request scopes **incrementally** at the moment the user taps *Link Google Drive*, never at launch.
- Tokens are persisted by the SDK in the Keychain. Never log, copy, or persist tokens ourselves. Use `GIDGoogleUser.refreshTokensIfNeeded()` before each API session.
- *Unlink*: `GIDSignIn.sharedInstance.disconnect()` (revokes the grant), then delete `drive_root` and optionally (user choice) remove Drive-sourced books and their downloaded files.

### Scope choice — important
Recursively finding every EPUB under a user-chosen folder requires reading files the app did not create, which means **`https://www.googleapis.com/auth/drive.readonly`**. That is a Google **restricted scope**:
- **Personal / small use:** the app works in OAuth *Testing* mode with up to 100 listed test users. Caveat: in Testing mode refresh tokens expire after **7 days**, so the user will need to re-link weekly. Moving the consent screen to *In production* without verification removes the 7-day expiry but shows an "unverified app" warning and caps users at 100.
- **Public App Store release:** requires Google OAuth verification **plus** an annual third-party security assessment (CASA) for restricted scopes. Budget for this before launch.
- **Alternative we will also support (no restricted scope):** *Files app import*. The user picks a folder in the Google Drive File Provider via `UIDocumentPickerViewController(forOpeningContentTypes: [.folder])`; we store a security-scoped bookmark and enumerate `.epub` files. This works without any Google API key but depends on the Drive app being installed and its file provider's offline behaviour, so it is a fallback, not the primary path.

Document this trade-off in the in-app privacy text and the README. **Do not** request `drive` (full read/write) — we never modify the user's Drive.

## Folder selection
There is no native Google Picker on iOS. Build an in-app **folder browser**:
1. Roots: "My Drive" (`'root' in parents`) and each shared drive (`drives.list`).
2. List child folders: `files.list` with `q = "'<folderId>' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false"`, `fields = "nextPageToken, files(id,name)"`, `supportsAllDrives=true`, `includeItemsFromAllDrives=true`, `orderBy=name`.
3. User taps into folders (breadcrumb at top) and taps **Use This Folder**. Persist to `drive_root`.

## Sync algorithm (`SyncEngine` actor)
Triggered by the **Sync** button in Settings (and optionally pull-to-refresh on the library, plus a `BGAppRefreshTask` later).

1. **Enumerate** — breadth-first walk from the root folder. For each folder, page through `files.list` with
   `q = "'<id>' in parents and trashed = false and (mimeType = 'application/vnd.google-apps.folder' or mimeType = 'application/epub+zip' or name contains '.epub')"`
   `fields = "nextPageToken, files(id,name,mimeType,md5Checksum,modifiedTime,size,parents)"`, `pageSize=1000`.
   Filter out non-epub results client-side (`name` ends with `.epub`, case-insensitive). Track visited folder ids to guard against shortcut cycles; resolve `application/vnd.google-apps.shortcut` targets only if they point to folders/epubs.
2. **Diff** against `book` rows where `source = 'drive'`:
   - *New* id → insert + queue metadata fetch.
   - *Known* id with changed `md5Checksum` → queue metadata refresh (respect `userEditedFields`); if downloaded, mark the local copy stale and re-download on next open.
   - *Known* id not seen → set `isMissingFromSource = true` (don't delete; keep bookmarks/progress). Show a subtle badge; allow user to remove.
3. **Fetch metadata** for queued files with bounded concurrency (4 at a time) using the remote ZIP reader — see [`EPUB_METADATA.md`](EPUB_METADATA.md#reading-metadata-without-downloading-the-book). Each file is its own DB transaction so partial syncs are useful.
4. **Report** progress (`found N · processed M`) through an `AsyncStream<SyncProgress>` that the Settings view and a library banner observe. Support cancellation.

### Robustness
- Exponential backoff with jitter on `403 rateLimitExceeded/userRateLimitExceeded` and `429/5xx`; honour `Retry-After`.
- On `401` refresh tokens once, then surface "Re-link Google Drive".
- Sync must be idempotent and resumable: re-running after a crash only fetches what's still missing.
- All requests go to `https://www.googleapis.com` (ATS-compliant by default). No custom ATS exceptions.

## Downloading a book (tap in library)
- `DownloadManager` actor: `GET files/<id>?alt=media&supportsAllDrives=true` using a `URLSession` download task with an `Authorization: Bearer` header; write to a temp file, verify size (and MD5 if cheap), then atomically move to `Books/drive/<id>.epub`, set file protection + `isExcludedFromBackup`.
- Show inline progress on the cover / row; tap again to cancel. On completion, open the reader automatically.
- Allow "Remove download" from the long-press menu to free space (metadata, bookmarks, and progress are kept).

## Testing
- `DriveClient` is a protocol. Unit-test `SyncEngine` with a `FakeDriveClient` that serves a fixture folder tree (nested folders, duplicate names, shortcuts, non-epub files, pagination, a rate-limit error).
- Never hit the real Google API in CI.
