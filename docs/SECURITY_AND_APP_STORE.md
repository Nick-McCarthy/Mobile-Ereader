# Security & App Store Compliance

Concept requirement: *"the end result must be able to satisfy Apple security requirements."* This file is the checklist. Items marked **(CI)** are checked automatically on every run by [`scripts/check-compliance.sh`](../scripts/check-compliance.sh). Every release candidate must pass all items; agents should tick items in PR descriptions when they touch an area.

## Apple platform security
- [ ] **App Transport Security** **(CI)** left at defaults: no `NSAllowsArbitraryLoads` or per-domain exceptions. All network traffic is HTTPS to Dropbox (`*.dropbox.com`, `*.dropboxapi.com`) and Microsoft (`login.microsoftonline.com`, `graph.microsoft.com`, OneDrive download hosts). iCloud Drive access goes through the OS, not our networking.
- [ ] **Keychain** holds all OAuth tokens (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, one item per linked source). No tokens in `UserDefaults`, the database, files, logs, or crash reports. No client secrets in the app: Dropbox and Microsoft are both configured as public clients using PKCE.
- [ ] **OAuth flow** uses `ASWebAuthenticationSession` (system browser; the app never handles passwords), PKCE `S256`, and a random `state` parameter verified on callback. Never use an embedded `WKWebView` for sign-in.
- [ ] **Security-scoped access** (iCloud / Files): always pair `startAccessingSecurityScopedResource()` with `stop…`; read via `NSFileCoordinator`; never write to the user's folder.
- [ ] **Data Protection**: database and book files written with `FileProtectionType.completeUntilFirstUserAuthentication` (or `.complete` if background sync is never needed). The default class is set in `App/Ereader.entitlements` **(CI)**; it only takes effect in signed builds once the App ID has the Data Protection capability (P0.1a), so code must still set protection explicitly per file.
- [ ] **Backup hygiene**: re-downloadable books in `Books/remote/` marked `isExcludedFromBackup`, and the flag cleared when a book becomes detached (its local copy is then the only one); caches in `Caches/`.
- [ ] **Untrusted input**: EPUB parsing hardened (zip-slip, zip-bomb, XXE, size caps); see [`EPUB_METADATA.md`](EPUB_METADATA.md#security-of-untrusted-archives). Fuzz the metadata parser with malformed fixtures. Treat API JSON as untrusted too (no force-unwrapping decoded fields).
- [ ] **WebView content**: book content cannot reach native code or the network; external links open only on explicit user tap.
- [ ] **Logging**: use `os.Logger` with `privacy: .private` for titles, file names, paths, account labels. Never log URLs that contain tokens or pre-authenticated download links. No `print` in release builds.
- [ ] **Unlink leaves remote data untouched**: no API call other than token revocation; tests assert the adapters issue no write requests.
- [ ] **Least privilege**: read-only scopes only (Dropbox `files.metadata.read`, `files.content.read`, `account_info.read`; Microsoft `Files.Read`, `User.Read`, `offline_access`). No camera/mic/location/contacts/tracking entitlements. Photo access, if used for custom covers, via `PhotosPicker` (no permission prompt needed).
- [ ] **No private APIs**, no dynamic code download/execution (Guideline 2.5.2).
- [ ] **Dependencies** pinned: direct dependencies with exact versions, everything else by the committed `Packages/EreaderKit/Package.resolved`, which CI enforces; review release notes / advisories when bumping. Only the three planned third-party packages without discussion (Readium, GRDB, Readium's ZIPFoundation fork). Readium's own transitive dependencies (CryptoSwift, Zip, Fuzi, SwiftSoup, DifferenceKit, and others) come with it; review them when bumping Readium.

## App Store Review Guidelines
- [ ] **Privacy manifest** `App/Resources/PrivacyInfo.xcprivacy` **(CI: valid, no tracking, nothing collected, present in the built app)**. *Required Reason APIs* declared: `UserDefaults` – `CA92.1`; `FileTimestamp` – `C617.1` (app container) and `3B52.1` (user-picked iCloud/Files folders). Add `DiskSpace` – `E174.1` if the download manager starts checking free space (P2.9 does not). Keep the list in sync with the code **(CI: `check-compliance.sh` fails if our sources use a required-reason API category the manifest doesn't declare)**, and confirm the bundled packages' own manifests by hand when adding or bumping one. Checked for Readium 3.11.1 (audit A1.10): ReadiumShared/Streamer/Navigator use only `UserDefaults` (legacy preference migration, the app's own defaults: `CA92.1`); of their dependencies, Zip reads and sets file timestamps in files it is given (`C617.1`), and SwiftSoup, Fuzi and DifferenceKit use none; CryptoSwift, GRDB and ZIPFoundation ship their own manifests. Readium ships no manifest, so the app's declarations cover it.
- [ ] **App Privacy "nutrition label"** in App Store Connect: the developer receives no user data (no backend, no analytics). Account labels and book metadata stay on the device, and traffic goes directly between the device and the service the user linked. This should qualify as **Data Not Collected**; re-check Apple's current definitions before submitting.
- [ ] **Privacy policy URL** (required by Apple; also needed for Dropbox production approval and Microsoft publisher verification). Host a simple page stating what is accessed (read-only file listing and downloads from the services the user links), that it stays on the device, and how to revoke access.
- [ ] **Guideline 4.8 (Login services):** Dropbox and Microsoft sign-in are used only to access the user's files, not as an app account, so *Sign in with Apple* is not required. Do not add any app account system in v1.
- [ ] **Guideline 5.1.1(v) (account deletion):** no app account is created; still provide per-source *Unlink* (revokes / deletes tokens) and *Delete All App Data* in Settings.
- [ ] **Export compliance** **(CI):** only OS-provided HTTPS → `ITSAppUsesNonExemptEncryption = NO` in `Info.plist`.
- [ ] **Content rights:** the app ships no books; users bring their own. Don't feature copyrighted covers in screenshots.
- [ ] **Accessibility & quality:** Dynamic Type, VoiceOver labels on all icon buttons, no crashes on review device, works offline for downloaded books, works without linking any cloud service (local import and iCloud paths) so reviewers can test.
- [ ] **Reviewer notes:** explain the iCloud Drive / Files and local-import paths (no account needed), and optionally provide demo Dropbox / Microsoft accounts with a few public-domain EPUBs.

## Provider requirements
- [ ] **Dropbox:** app in the App Console with scoped access and only read scopes; branding follows Dropbox's guidelines; apply for **production status** before exceeding development-mode limits (free review, no security assessment).
- [ ] **Microsoft:** Entra app registration as a public client supporting personal and work/school accounts; complete **publisher verification** (free) before public release; follow Microsoft identity-platform branding guidance for the sign-in button.
- [ ] **iCloud Drive / Files:** no provider setup; nothing to register.
- Background: Google Drive was removed as a built-in source because its restricted scope needs a paid annual security assessment. See [`REMOTE_SOURCES.md`](REMOTE_SOURCES.md).

## Release gate
Before any TestFlight/App Store build: run the full test suite, run the static analyser (`xcodebuild analyze`), verify `PrivacyInfo.xcprivacy` via Xcode's *Generate Privacy Report*, and re-check this list.
