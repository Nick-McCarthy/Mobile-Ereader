# Security & App Store Compliance

Concept requirement: *"the end result must be able to satisfy Apple security requirements."* This file is the checklist. Every release candidate must pass all items; agents should tick items in PR descriptions when they touch an area.

## Apple platform security
- [ ] **App Transport Security** left at defaults: no `NSAllowsArbitraryLoads` or per-domain exceptions. All network traffic is HTTPS to Dropbox (`*.dropbox.com`, `*.dropboxapi.com`) and Microsoft (`login.microsoftonline.com`, `graph.microsoft.com`, OneDrive download hosts). iCloud Drive access goes through the OS, not our networking.
- [ ] **Keychain** holds all OAuth tokens (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, one item per linked source). No tokens in `UserDefaults`, the database, files, logs, or crash reports. No client secrets in the app: Dropbox and Microsoft are both configured as public clients using PKCE.
- [ ] **OAuth flow** uses `ASWebAuthenticationSession` (system browser; the app never handles passwords), PKCE `S256`, and a random `state` parameter verified on callback. Never use an embedded `WKWebView` for sign-in.
- [ ] **Security-scoped access** (iCloud / Files): always pair `startAccessingSecurityScopedResource()` with `stop…`; read via `NSFileCoordinator`; never write to the user's folder.
- [ ] **Data Protection**: database and book files written with `FileProtectionType.completeUntilFirstUserAuthentication` (or `.complete` if background sync is never needed). Enable the *Data Protection* entitlement.
- [ ] **Backup hygiene**: re-downloadable books in `Books/remote/` marked `isExcludedFromBackup`, and the flag cleared when a book becomes detached (its local copy is then the only one); caches in `Caches/`.
- [ ] **Untrusted input**: EPUB parsing hardened (zip-slip, zip-bomb, XXE, size caps); see [`EPUB_METADATA.md`](EPUB_METADATA.md#security-of-untrusted-archives). Fuzz the metadata parser with malformed fixtures. Treat API JSON as untrusted too (no force-unwrapping decoded fields).
- [ ] **WebView content**: book content cannot reach native code or the network; external links open only on explicit user tap.
- [ ] **Logging**: use `os.Logger` with `privacy: .private` for titles, file names, paths, account labels. Never log URLs that contain tokens or pre-authenticated download links. No `print` in release builds.
- [ ] **Unlink leaves remote data untouched**: no API call other than token revocation; tests assert the adapters issue no write requests.
- [ ] **Least privilege**: read-only scopes only (Dropbox `files.metadata.read`, `files.content.read`, `account_info.read`; Microsoft `Files.Read`, `User.Read`, `offline_access`). No camera/mic/location/contacts/tracking entitlements. Photo access, if used for custom covers, via `PhotosPicker` (no permission prompt needed).
- [ ] **No private APIs**, no dynamic code download/execution (Guideline 2.5.2).
- [ ] **Dependencies** pinned: direct dependencies with exact versions, everything else by the committed `Packages/EreaderKit/Package.resolved`, which CI enforces; review release notes / advisories when bumping. Only the three planned third-party packages without discussion (Readium, GRDB, Readium's ZIPFoundation fork). Readium's own transitive dependencies (CryptoSwift, Zip, Fuzi, SwiftSoup, DifferenceKit, and others) come with it; review them when bumping Readium.

## App Store Review Guidelines
- [ ] **Privacy manifest** `PrivacyInfo.xcprivacy` in the app target: declare *Required Reason APIs* used (e.g. `NSPrivacyAccessedAPICategoryUserDefaults` – `CA92.1`, `NSPrivacyAccessedAPICategoryFileTimestamp` – `C617.1` (iCloud modification dates), `NSPrivacyAccessedAPICategoryDiskSpace` if showing free space – `E174.1`), `NSPrivacyTracking = false`, no tracking domains. Confirm the bundled packages' own manifests.
- [ ] **App Privacy "nutrition label"** in App Store Connect: the developer receives no user data (no backend, no analytics). Account labels and book metadata stay on the device, and traffic goes directly between the device and the service the user linked. This should qualify as **Data Not Collected**; re-check Apple's current definitions before submitting.
- [ ] **Privacy policy URL** (required by Apple; also needed for Dropbox production approval and Microsoft publisher verification). Host a simple page stating what is accessed (read-only file listing and downloads from the services the user links), that it stays on the device, and how to revoke access.
- [ ] **Guideline 4.8 (Login services):** Dropbox and Microsoft sign-in are used only to access the user's files, not as an app account, so *Sign in with Apple* is not required. Do not add any app account system in v1.
- [ ] **Guideline 5.1.1(v) (account deletion):** no app account is created; still provide per-source *Unlink* (revokes / deletes tokens) and *Delete All App Data* in Settings.
- [ ] **Export compliance:** only OS-provided HTTPS → set `ITSAppUsesNonExemptEncryption = NO` in `Info.plist`.
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
