# Security & App Store Compliance

Concept requirement: *"the end result must be able to satisfy Apple security requirements."* This file is the checklist. Every release candidate must pass all items; agents should tick items in PR descriptions when they touch an area.

## Apple platform security
- [ ] **App Transport Security** left at defaults — no `NSAllowsArbitraryLoads` or per-domain exceptions. All network traffic is HTTPS to `*.googleapis.com` / `accounts.google.com`.
- [ ] **Keychain** holds all credentials (GoogleSignIn does this). No tokens in `UserDefaults`, files, logs, or crash reports.
- [ ] **Data Protection**: database and book files written with `FileProtectionType.completeUntilFirstUserAuthentication` (or `.complete` if background sync is never needed). Enable the *Data Protection* entitlement.
- [ ] **Backup hygiene**: re-downloadable Drive books marked `isExcludedFromBackup`; caches in `Caches/`.
- [ ] **Untrusted input**: EPUB parsing hardened (zip-slip, zip-bomb, XXE, size caps) — see [`EPUB_METADATA.md`](EPUB_METADATA.md#security-of-untrusted-archives). Fuzz the metadata parser with malformed fixtures.
- [ ] **WebView content**: book content cannot reach native code or the network; external links open only on explicit user tap.
- [ ] **Logging**: use `os.Logger` with `privacy: .private` for titles, file names, emails. No `print` in release builds.
- [ ] **Least privilege**: Drive scope is read-only; no camera/mic/location/contacts/tracking entitlements. Photo access, if used for custom covers, via `PhotosPicker` (no permission prompt needed).
- [ ] **No private APIs**, no dynamic code download/execution (Guideline 2.5.2).
- [ ] **Dependencies** pinned via SPM `Package.resolved`; review release notes / advisories when bumping. Only the four planned third-party packages without discussion (Readium, GRDB, GoogleSignIn, ZIPFoundation).

## App Store Review Guidelines
- [ ] **Privacy manifest** `PrivacyInfo.xcprivacy` in the app target: declare *Required Reason APIs* used (e.g. `NSPrivacyAccessedAPICategoryUserDefaults` – `CA92.1`, `NSPrivacyAccessedAPICategoryFileTimestamp` – `C617.1`, `NSPrivacyAccessedAPICategoryDiskSpace` if showing free space – `E174.1`), `NSPrivacyTracking = false`, no tracking domains. Confirm third-party SDKs ship their own manifests (GoogleSignIn does).
- [ ] **App Privacy "nutrition label"** in App Store Connect: data linked to the user = email address (from Google sign-in, used for app functionality only, stored on device). No tracking, no analytics in v1.
- [ ] **Privacy policy URL** (required by both Apple and Google OAuth verification). Host a simple page; include Google API *Limited Use* disclosure.
- [ ] **Guideline 4.8 (Login services):** Google is used only to access the user's Drive content, not as an app account, so *Sign in with Apple* is not required. Do not add any app account system in v1.
- [ ] **Guideline 5.1.1(v) (account deletion):** no app account is created; still provide *Unlink Google Drive* (revokes grant) and *Delete All App Data* in Settings.
- [ ] **Export compliance:** only OS-provided HTTPS → set `ITSAppUsesNonExemptEncryption = NO` in `Info.plist`.
- [ ] **Content rights:** the app ships no books; users bring their own. Don't feature copyrighted covers in screenshots.
- [ ] **Accessibility & quality:** Dynamic Type, VoiceOver labels on all icon buttons, no crashes on review device, works offline for downloaded books, works without linking Drive (local import path) so reviewers can test.
- [ ] **Reviewer notes:** provide a demo Google account (in Testing mode, add it as a test user) and/or explain the local-import path with a bundled public-domain sample EPUB option.

## Google OAuth requirements
- [ ] Consent screen configured with app name, support email, privacy policy, authorised domains.
- [ ] `drive.readonly` is a **restricted** scope: public release needs Google verification + CASA security assessment. Personal use can stay in Testing mode (≤100 test users, 7-day refresh-token expiry). See [`GOOGLE_DRIVE_SYNC.md`](GOOGLE_DRIVE_SYNC.md#scope-choice--important).

## Release gate
Before any TestFlight/App Store build: run the full test suite, run the static analyser (`xcodebuild analyze`), verify `PrivacyInfo.xcprivacy` via Xcode's *Generate Privacy Report*, and re-check this list.
