# Audit plan — stage 1

A plan for auditing everything built so far, before Phase 2 continues with the Dropbox / OneDrive adapters and the sync engine. It says **what** to check, **with which guidance**, and **what counts as evidence**. The audit itself records its results in `docs/audit-stage-1-findings.md` (template at the end).

## Scope

| Phase | Tasks | Where |
|---|---|---|
| P0 Foundations | P0.1–P0.6: bundle id, scaffolding, XcodeGen project, pinned dependencies, compliance skeleton, CI | `project.yml`, `Config/`, `App/Info.plist`, `App/Ereader.entitlements`, `App/Resources/PrivacyInfo.xcprivacy`, `scripts/check-compliance.sh`, `.github/workflows/ci.yml`, `Package.swift` / `Package.resolved` |
| P1 Local library | P1.1 database, P1.2 repositories, P1.3 EPUB parser, P1.4 author names, P1.5 local import | `Sources/Persistence`, `Sources/EPUBMetadata`, `Sources/Core`, `Sources/BookStorage`, `Sources/LibraryServices`, `App/` |
| P2 (first half) | P2.1 source abstraction, P2.2 OAuth + Keychain, P2.3 remote ZIP reader, P2.4 iCloud Drive / Files | `Sources/RemoteSources`, `Sources/RemoteSourcesTesting`, `Sources/EPUBMetadata/RemoteZipReader.swift` |

Branches: P1 is in PR #4 (`feature/p1-database` → `main`). P2.1–P2.4 are on `feature/p2-sources`, which is branched from P1. Audit `feature/p2-sources`: it contains both.

**Out of scope:**
- The reader (not built yet).
- The Dropbox and OneDrive adapters, the sync engine, and the Settings UI (P2.5+).
- Real OAuth sign-in and on-device iCloud behaviour. These need the deferred app registrations (P0.1a–c) and a device.
- `appstore-review` Track 2, the App Store Connect metadata. There is no App Store Connect record yet.

## How to run the audit

1. **There is no local Mac.** Most of the audit is reading code. Anything that must run (tests, the accessibility audit, compliance checks) runs on GitHub Actions (see [`CI_AND_BUILD.md`](CI_AND_BUILD.md)). Evidence is a CI run link or `.xcresult`, never "it should work".
2. **Use the skills in [`/skills`](../skills/README.md).** Each workstream below names the skill and the exact reference files to load. Load only those. **Project rules win:** where a skill disagrees with [`AGENTS.md`](../AGENTS.md) or `/docs`, follow the project, and note the conflict only if the project rule looks wrong. Examples of skill advice that doesn't apply here:
   - "iOS 27 is the default deployment target" (we target iOS 17).
   - SwiftData (we use GRDB).
   - Simulator or lldb steps (no local Mac).
3. **Audit, don't fix.** Record each finding. Fixes become action-plan tasks (`A1.n`, see [Output](#output)) so each gets its own commit and CI run. Exception: a fix of a line or two with no behaviour change (a typo, a doc mismatch) may be made directly, noted as "fixed in audit".
4. **Severity** (from `swift-security-expert`'s output rules, extended to all areas):
   - **Critical:** exploitable, or causes data loss.
   - **High:** a wrong security boundary, silent failure, or App Store rejection risk.
   - **Medium:** a correctness or robustness gap that isn't exploitable.
   - **Low:** hygiene and style.
5. **Leads are not findings.** The [known leads](#known-leads) below came from a quick sweep while writing this plan. Each must be confirmed or dismissed with evidence.

## Workstreams

Suggested order: A and B first (security and untrusted input), then C, D, and G, then E, F, H, and I.

### A. Credentials, Keychain, and OAuth
**Skill:** `swift-security-expert`. Load `common-anti-patterns.md` (backbone), `keychain-fundamentals.md`, `keychain-access-control.md`, `credential-storage-patterns.md`, and `testing-security-code.md`. Use the skill's *Top-Level Review Checklist* and *Agent Self-Review Checklist*.
**Project:** [`SECURITY_AND_APP_STORE.md`](SECURITY_AND_APP_STORE.md), [`REMOTE_SOURCES.md`](REMOTE_SOURCES.md) (P2.2 implementation section).
**Files:** `RemoteSources/OAuth/*`, `RemoteSources/HTTPClient.swift`, `RemoteSourcesTesting/InMemoryTokenStore.swift`, `Tests/RemoteSourcesTests/OAuthTests.swift`, `Tests/PersistenceTests/NoTokensInDatabaseTests.swift`.

Check:
- [ ] Every `SecItem*` status is handled, including `errSecInteractionNotAllowed`, which must not lead to deleting the tokens or re-linking (anti-pattern #4).
- [ ] Every keychain item sets `kSecAttrAccessible` explicitly (`AfterFirstUnlockThisDeviceOnly`), and none is set to synchronise (#5).
- [ ] Data-protection keychain is used. Save is update-or-add; compare it with the skill's add-or-update rule and judge whether the order matters here.
- [ ] No `SecItem*` call runs on the main actor (`TokenProvider` is an actor; check every other caller).
- [ ] No token, code, or verifier reaches logs, errors, the database, `UserDefaults`, or files (#1, #8). `OAuthTokens.description` is redacted, and error types don't carry token strings.
- [ ] PKCE and `state` use `SecRandomCopyBytes` (#10); `state` is checked before anything else in the callback.
- [ ] `ASWebAuthenticationSession` is ephemeral; the callback scheme is specific to the app. Consider whether another app could register the same scheme.
- [ ] Refresh handling: concurrent callers share one refresh, a rejected grant becomes `needsRelink`, and network errors don't sign the user out.
- [ ] `signOut` deletes local tokens even if revocation fails.
- [ ] `HTTPClient` uses an ephemeral session (no cookies, cache, or stored credentials). There are no ATS exceptions anywhere.
- [ ] Keychain items survive app deletion; decide what a reinstall should do (#9; see lead L1).

### B. Untrusted input: EPUBs, remote ZIPs, and picked folders
**Skill:** none covers this directly (`swift-security-expert` excludes it). Use its severity scale and `compliance-owasp-mapping.md` (M4 input validation) only if it helps. Use `swift-concurrency-pro`'s `actors.md` for the cache actor.
**Project:** [`EPUB_METADATA.md`](EPUB_METADATA.md) (Security and "As implemented (P2.3)"), [`REMOTE_SOURCES.md`](REMOTE_SOURCES.md) (P2.4 section).
**Files:** `EPUBMetadata/*`, `RemoteSources/Files/*`, `LibraryServices/LocalBookImporter.swift`, `BookStorage/BookFileStore.swift`.

Check:
- [ ] XML: external entities off, `<!ENTITY` rejected, depth capped. Try a billion-laughs and a deep-nesting fixture.
- [ ] ZIP: entry count, per-entry and total byte caps, compression-ratio check, and real output counted (declared sizes can lie). Check the 1 MB threshold below which ratio isn't checked.
- [ ] Images: the pixel cap is applied before decoding (ImageIO thumbnail only, never a full decode).
- [ ] Paths: `ArchivePath.resolve` rejects absolute paths, URLs, and `..` past the root, and percent-decoding can't reintroduce them (for example `%2e%2e%2f`). `FilesListing.url(for:)` rejects `.` and `..`, and symlinks inside a picked folder can't lead outside it.
- [ ] Remote reader: each fetch size is bounded by the file length and the limits, not by attacker-chosen central-directory values (lead L2). The 32 MB cache cap holds.
- [ ] Short reads, over-long replies, and a lying `length()` all fail safely.
- [ ] Fallback: the temporary download is always deleted (success, throw, and cancellation). Limit errors don't trigger a pointless full download.
- [ ] Import: the security-scoped resource is always released. The `Documents/Inbox` copy is deleted. A failed parse leaves no half-saved book or orphaned file.
- [ ] Book files: names come from ids, not from EPUB or remote names. Data Protection is applied to the books, covers, and database.

### C. Concurrency (Swift 6 strict)
**Skill:** `swift-concurrency-pro`. Start with `hotspots.md`, then `actors.md`, `bridging.md`, `async-streams.md`, `cancellation.md`, `unstructured.md`, and `bug-patterns.md`. Use `diagnostics.md` only if a fix needs it.
**Files:** all of `Packages/EreaderKit/Sources`, plus `App/EreaderApp.swift`, `App/Features/Library/*`.

Check each hotspot the sweep found:
- [ ] Closure-form `AsyncThrowingStream` in `DatabaseRepositories.swift:422`, `FilesRemoteSource.swift:68`, and `FakeRemoteSource.swift:121`. Check that each finishes on every path, cancels its inner `Task` in `onTermination`, and maps cancellation consistently. Consider `makeStream(of:)`.
- [ ] Continuations in `FilesRemoteSource.coordinatedCopy` and `WebAuthenticator`. Check that each resumes exactly once on every path, including when `NSFileCoordinator` reports an error before its accessor runs, and when the auth session is cancelled or never starts.
- [ ] Unstructured `Task {}` in `EreaderApp.swift:26` and `LibraryView.swift:76`: decide whether these should be `.task` or tied to a lifetime, and what happens on cancellation.
- [ ] Actor reentrancy (read → `await` → write):
  - `TokenProvider`: the shared refresh task, and clearing it on failure.
  - `RangeCache`: concurrent misses, and `fetchHint` shared between transactions.
  - `EPUBArchive.bytesRead`.
  - `FilesRemoteSource`: the bookmark refresh.
- [ ] Blocking work on actors: `FileManager` enumeration of a large tree, and keychain calls. Check whether either should move off the cooperative pool (`@concurrent` / a dedicated executor), following the skill's GCD guidance.
- [ ] `MainActor.assumeIsolated` in the presentation-anchor provider: is the call really always on main?
- [ ] `@unchecked Sendable` only on `InMemoryTokenStore` (test target, lock-protected). The skill allows this when the type really is lock-protected; confirm every member uses the lock.
- [ ] Cancellation reaches long operations: enumeration, remote reads, the fallback download, and import.

### D. Tests
**Skill:** `swift-testing-pro`. Load `core-rules.md`, `writing-better-tests.md`, and `async-tests.md`. `swift-concurrency-pro/references/testing.md` for timing.
**Files:** `Packages/EreaderKit/Tests/**` (98 `@Test` functions across 6 test targets) and `UITests/AppLaunchTests.swift`.

Check:
- [ ] Suites are structs. Setup uses `init` and cleanup uses `deinit` or `defer`, so temporary folders and files are always removed.
- [ ] `#require` is used for preconditions and `#expect` for checks. There are no force-unwraps (also enforced by lint).
- [ ] Parameterised tests are used where cases repeat. Test names say what behaviour they check.
- [ ] Hidden dependencies: `Date()`, `FileManager.default`, `temporaryDirectory`, `UUID()`. Tests that run in parallel can't share state. GRDB stores dates to the millisecond, so compare fixed dates.
- [ ] No timing-based waits. Async tests use `confirmation` or explicit awaits.
- [ ] `#expect(throws:)` checks the specific error, not just `Error.self`.
- [ ] Gaps against each task's "Done when" in the action plan; list what isn't tested. Candidates: leads L5–L7; the stale-bookmark path; cancelling enumeration; a real-Keychain integration test (`testing-security-code.md` covers CI keychains).
- [ ] The UI test only checks launch. Check that it is a meaningful smoke test of `-UITestMode`.

### E. SwiftUI app shell
**Skill:** `swiftui-pro`. Load `api.md`, `views.md`, `data.md`, `navigation.md`, `localization.md`, `hygiene.md`, and `performance.md` (not `performance-plus.md`).
**Project:** [`UI_SPEC.md`](UI_SPEC.md), [`ARCHITECTURE.md`](ARCHITECTURE.md).
**Files:** `App/**/*.swift`, `App/Resources/Localizable.xcstrings`.

Check:
- [ ] No deprecated APIs for the iOS 17 target. Uses `@Observable`, `@Entry`, and `foregroundStyle`.
- [ ] Data flow: `BookImportController` ownership and lifetime; `@AppStorage("authorDisplayFormat")` stores an enum raw value safely; the environment injection in `AppEnvironment`.
- [ ] Errors reach the user (import alert; the database-open failure view) and don't leak internal details.
- [ ] All user-facing text is in the string catalog, and formatting is locale-aware (dates, counts).
- [ ] `.fileImporter` and `onOpenURL` behave the same, and importing several files reports partial failure clearly.
- [ ] One type per file and a folder per feature, as the skill expects. Note where the project's own convention differs.

### F. Accessibility
**Skill:** `ios-accessibility`. Load `playbook.md` (Review Checklist and Verification Checklist), `voiceover-swiftui.md`, `dynamic-type-swiftui.md`, `testing-automated.md`, plus `swiftui-pro/references/accessibility.md`.
**Files:** `App/Features/**`.

Check:
- [ ] Every control has a label, and icon-only buttons (the `+` import button) have a text label.
- [ ] Book rows are read as one element with title, author, and state, in a useful order.
- [ ] Text uses text styles (Dynamic Type) and layouts survive accessibility sizes. Colours are semantic.
- [ ] Touch targets are at least 44 pt. Nothing relies on `onTapGesture` alone.
- [ ] **Automated evidence in CI:** propose a UI test that calls `XCUIApplication().performAccessibilityAudit()` (Xcode 15+, iOS 17) on the library screen (lead L8). Manual VoiceOver testing waits for a device; record it as deferred, not passed.

### G. Compliance and App Store readiness (Track 1 only)
**Skill:** `appstore-review`. Run Track 1 sections 1.2, 1.5, 1.6, 1.7, and 1.8. Report 1.1 (completeness) and 1.3/1.4 (IAP, privacy policy) as "not yet applicable", with a note. Use `references/appstore-review-ref.md` for sources.
**Project:** [`SECURITY_AND_APP_STORE.md`](SECURITY_AND_APP_STORE.md), `scripts/check-compliance.sh`.

Check:
- [ ] Privacy manifest: every required-reason API the code uses is declared with a correct reason. Today that is `UserDefaults` (CA92.1) and file timestamps (C617.1, 3B52.1; `FilesListing` reads `contentModificationDate`). Confirm 3B52.1 fits files from a user-picked folder. Disk space isn't used yet. `NSPrivacyCollectedDataTypes` is empty and `NSPrivacyTracking` is false; confirm both against the code.
- [ ] ATS: no `NSAppTransportSecurity` exceptions. `ITSAppUsesNonExemptEncryption = NO` is justified (HTTPS only, no custom crypto).
- [ ] Entitlements: only Data Protection. `TARGETED_DEVICE_FAMILY = 1` (iPhone only); no Catalyst or visionOS destinations by default.
- [ ] Document types: the `CFBundleDocumentTypes` entry for EPUB, `LSSupportsOpeningDocumentsInPlace = false`, and the `Documents/Inbox` handling.
- [ ] Code quality (1.8): no `print`, no force-unwraps outside tests, no secrets in source (`Config/Secrets.example.xcconfig` holds placeholders only), no debug-only UI in release builds (`-UITestMode` must be harmless in release).
- [ ] `check-compliance.sh` actually fails CI when each rule is broken (try one broken rule per check on a throwaway branch).

### H. Readiness for background work
**Skill:** `background-execution`. Load `fundamentals.md` and `bg-task-scheduler.md`. Nothing uses background execution yet; this checks that stage 1 doesn't block it later (`BGAppRefreshTask` sync, background downloads).

Check:
- [ ] The database, books, and covers use `completeUntilFirstUserAuthentication`, which a locked-device background refresh can open. Keychain tokens use `AfterFirstUnlockThisDeviceOnly` to match.
- [ ] Nothing that a background launch needs is set up only in view code (`.onAppear` / `.task`). Note what `AppEnvironment.live()` would need for a background launch.
- [ ] Remote sources and repositories can run without UI. Report anything tied to the main actor that wouldn't be.
- [ ] Note for P2.7 / P2.9: the skill's rules on registering handlers in `App.init`, expiration handlers, and the background `URLSession` relaunch flow.

### I. Docs, process, and supply chain
**Project:** [`AGENTS.md`](../AGENTS.md) ground rules, [`CONVENTIONS.md`](CONVENTIONS.md), [`CI_AND_BUILD.md`](CI_AND_BUILD.md).

Check:
- [ ] Every ticked action-plan box meets its "Done when", with a passing CI run to point to.
- [ ] Every "As implemented" section in `/docs` matches the code (names, limits, error cases).
- [ ] `Package.resolved` holds only Readium, GRDB, ZIPFoundation, and their own dependencies. Versions are pinned `exact:`.
- [ ] The CI workflow pins its macOS image and Xcode. Third-party actions are pinned to a commit SHA, or a decision is recorded. Lint runs `--strict`. Secrets are not printed.
- [ ] No secrets or copyrighted books in git history (`git log -p` search for token-like strings; fixtures are synthetic).
- [ ] Commits name task ids. `skills/README.md` pins the commit each skill was copied from.

## Known leads

Found while writing this plan; **unverified**. Confirm or dismiss each in the findings log.

| Id | Area | Lead |
|---|---|---|
| L1 | A | Keychain items survive app deletion, but the database doesn't. After a reinstall, Dropbox / OneDrive tokens would be orphaned (`swift-security-expert` anti-pattern #9). Likely fix: a first-launch cleanup keyed on a flag in the database or `UserDefaults`. |
| L2 | B | `RemoteZipReader.expectEntry` sizes the next fetch from the entry's declared `compressedSize`. `EPUBArchive` checks the *uncompressed* size against the limits first, but not the compressed size. A hostile central directory could make one ranged read as large as the whole file, which is bounded by file length but larger than intended. |
| L3 | C | `RangeCache.fetchHint` is one value shared by every transaction, so concurrent entry reads could use each other's hints. Today reads are sequential; confirm, or scope the hint to the transaction. |
| L4 | C | `FilesRemoteSource` walks the folder tree synchronously on its actor, holding a cooperative thread for the whole walk on large or slow (cloud-backed) trees. |
| L5 | D | Known gap from P1.5: a book's series isn't saved on import. |
| L6 | D | Known gap from P1.5: importing the same file twice adds a duplicate book. |
| L7 | D | The stale-bookmark refresh path in `FilesRemoteSource.resolveRoot` has no test. Hard to trigger on a temporary folder, so at least document it. |
| L8 | F | No automated accessibility check exists. `performAccessibilityAudit()` can run in the existing UI-test job. |
| L9 | E | `.fileImporter` and `onOpenURL` start unstructured `Task`s. If the view goes away, the import keeps running with no owner. |

## Output

1. **`docs/audit-stage-1-findings.md`**, one row per finding:

   | Id | Workstream | Severity | File:line | Finding | Evidence (CI run, test, or quote) | Skill rule / project rule | Action |
   |---|---|---|---|---|---|---|---|
   | F-A1 | A | High | `…/TokenStore.swift:42` | … | … | `common-anti-patterns.md` #4 | `A1.1` |

   `Action` is one of: an action-plan task id, "fixed in audit (commit)", "won't fix (reason)", or "dismissed (reason)".
2. **A new "Audit stage 1 fixes" section in [`ACTION_PLAN.md`](ACTION_PLAN.md)**, with tasks `A1.1`, `A1.2`, … Critical and High findings are fixed before P2.5 starts; Medium ones before P2.7; Low ones whenever their file is next touched.
3. **A short summary** at the top of the findings file: counts by severity, what was deferred (device-only checks), and whether stage 1 is cleared to continue.

## Done when

- Every checkbox in workstreams A–I is ticked, marked N/A with a reason, or linked to a finding.
- Every lead L1–L9 is confirmed (with a finding) or dismissed (with a reason).
- Every Critical and High finding has an `A1.n` task, and the audit summary is committed with the CI run that backs any test-based evidence.
