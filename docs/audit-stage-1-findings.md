# Audit stage 1 — findings

Results of the audit planned in [`audit-stage-1.md`](audit-stage-1.md), run on 2026-11-27 against `feature/p2-sources` at `P2.4` (CI run 46060285544, green).

## Summary

| Severity | Count | Fix by |
|---|---|---|
| Critical | 0 | — |
| High | 1 | before P2.5 |
| Medium | 11 | before P2.7 (or the task named in Action) |
| Low | 13 | when the file is next touched |

**Verdict: stage 1 can continue once `A1.1` (F-B1) is fixed.**
- No secret, token, or credential handling was found broken.
- Keychain use meets `swift-security-expert`'s core rules.
- The XML, ZIP, and image limits work for local files.
- The one High finding is in the remote ZIP reader: a hostile book's central directory can size a single ranged read and its memory allocation.

**How the evidence was gathered:**
- Code reading (the file:line cited in each finding).
- The existing CI suite: 98 package tests and 1 UI test, all passing.
- For the Readium privacy-manifest question, Readium's public source tree.

The audit changed no code, so no new CI run was needed. Each fix task must include its own test and CI run.

**Deferred: these need a device or the app registrations, so they were not checked:**
- Manual VoiceOver and Dynamic Type passes.
- Real iCloud fetch and eviction.
- The real Keychain on a signed build.
- Real OAuth against Dropbox and Microsoft.
- Whether `ITMS-91053` (missing privacy declarations) is raised on the first TestFlight upload. See F-G1.

## Findings

Ordered by severity. "Rule" cites the skill reference or project doc each finding is judged against.

**Fix status (2026-11-27):** High and Medium findings are fixed (tasks A1.1–A1.10, merged to `main` in PR Nick-McCarthy/Mobile-Ereader#5). A1.10's check was shown failing in CI on a throwaway branch (run 46086173090). The Low findings outside those tasks (F-E2, F-E4, F-E5) move to Phase 3.

| Id | Area | Severity | File:line | Finding | Evidence | Rule | Action |
|---|---|---|---|---|---|---|---|
| F-B1 | B | **High** | `EPUBMetadata/EPUBArchive.swift:57-68`, `RemoteZipReader.swift:35`, `:112` | `EPUBArchive.data` checks an entry's declared *uncompressed* size against the limits, but never its *compressed* size. `expectEntry` then sizes the next ranged read from that unchecked value. A hostile central directory (for example, compressed 2 GB, uncompressed 1 KB) makes one fetch cover the rest of the file and allocate it as a single `Data`: memory exhaustion while syncing. The 32 MB cache cap only applies after the block arrives. A compressed size near `Int64.max` also makes `offset + size` overflow, which traps. Confirms lead L2. | Code path: `data(at:)` → `expectEntry(compressedSize:)` → `RangeCache.bytes` → `fetch(offset..<min(offset + size, length))`. No test covers a lying compressed size. | `EPUB_METADATA.md` Security ("treat every EPUB as untrusted"; limits apply remotely) | `A1.1` |
| F-A1 | A | Medium | `RemoteSources/OAuth/TokenStore.swift` (no cleanup exists) | Keychain items survive app deletion; the database doesn't. After a reinstall, Dropbox / OneDrive tokens stay in the Keychain with no `library_source` row pointing at them. They are never used or revoked, and a later link creates a new item beside them. Confirms lead L1. | No first-launch cleanup anywhere in `App/` or `RemoteSources`. | `swift-security-expert` `common-anti-patterns.md` #9 | `A1.2` (with P2.5) |
| F-A2 | A | Medium | `TokenStore.swift:35`, `TokenProvider.swift:39-44` | A Keychain item that won't decode (corrupt, or from an older format) makes `tokens(forSource:)` throw a decoding error. That error comes before `deleteTokens`, so `signOut()` throws and the item can never be removed through the app. `validAccessToken()` surfaces it as a generic error rather than `needsRelink`, so the user isn't asked to link again. | Read path: `try store.tokens(...)` throws before line 43. | `credential-storage-patterns.md` (logout cleanup always completes) | `A1.3` |
| F-A3 | A | Medium | `TokenProvider.swift:55-57` | If a refresh succeeds but saving the new tokens to the Keychain fails, the new tokens are thrown away. Microsoft rotates refresh tokens, so the old one may already be invalid, and the user is forced to re-link at the next refresh. | `try store.save(fresh, ...)` inside the shared task; its error propagates and `fresh` is dropped. | `credential-storage-patterns.md` (refresh token rotation) | `A1.3` |
| F-B2 | B | Medium | `EPUBMetadata/Markup.swift:43` | The entity-declaration guard is a byte search for UTF-8 `<!ENTITY`. A package document encoded as UTF-16 (which `XMLParser` accepts) passes the guard, and its internal entities are expanded. External entities stay off, and libxml2's amplification checks plus the 10 MB entry cap probably stop a billion-laughs attack. But the documented guarantee ("entity declarations are refused") doesn't hold. | The existing `hostileXML` test is UTF-8 only. | `EPUB_METADATA.md` Security | `A1.4` |
| F-C1 | C | Medium | `RemoteSources/Files/FilesRemoteSource.swift:89` | The whole folder tree is walked synchronously inside the actor (`FileManager.enumerator` plus `resourceValues` per item). On a large or cloud-backed folder, this holds a cooperative-pool thread for the whole walk. The walk can't be cancelled until it finishes, because `Task.checkCancellation` runs only while yielding. Confirms lead L4. | Synchronous `listEPUBs` called from the stream's `Task`. | `swift-concurrency-pro` `structured.md`, `cancellation.md` | `A1.5` |
| F-D1 | D | Medium | `Tests/RemoteSourcesTests/OAuthTests.swift:232` | The "Concurrent callers share one refresh" test passes even with no sharing. If the calls ran one after the other, the first would save a non-expiring token and the second would return it without a request, so `requestCount == 1` either way. It also depends on a 100 ms sleep. | Logic of the test with `expires_in` far in the future. | `swift-testing-pro` `async-tests.md` (no timing-based tests; test the behaviour) | `A1.6` |
| F-D2 | D | Medium | `LibraryServices/LocalBookImporter.swift:73` | A book's series (`seriesName` / `seriesPosition`) is parsed but never saved on import, so series from local books are lost. Confirms lead L5. | `makeBook` sets no series. | `ACTION_PLAN.md` P1.5, `DATA_MODEL.md` series | `A1.7` |
| F-D3 | D | Medium | `LocalBookImporter.swift:30` | Importing the same file twice creates two books. Confirms lead L6. | No identifier or content check before `save`. | `UI_SPEC.md` (library shows each book once) | `A1.7` |
| F-E1 | E | Medium | `App/Features/Library/LibraryView.swift:104` | Each row decodes its cover with `UIImage(contentsOfFile:)` inside `body`, on the main actor, on every re-render. Fine for today's short list; it will stutter in the Phase 3 grid. | Synchronous file read and decode in a view body. | `swiftui-pro` `performance.md` (no expensive work in `body`) | `A1.8` (with P3.x) |
| F-F1 | F | Medium | `UITests/AppLaunchTests.swift` | There is no automated accessibility check. The UI test only opens the tabs. `XCUIApplication.performAccessibilityAudit()` (Xcode 15+, iOS 17) can run in the existing CI UI-test job and catch missing labels, contrast, and Dynamic Type clipping. Confirms lead L8. | Test file. | `ios-accessibility` `testing-automated.md` | `A1.9` |
| F-G1 | G | Medium | `App/Resources/PrivacyInfo.xcprivacy` | Readium 3.11.1 ships **no** privacy manifest (GRDB and ZIPFoundation do), and its code is compiled into our binary. So our manifest must declare every required-reason API that Readium code we link calls. Readium's current `main` calls `ProcessInfo.systemUptime` (System Boot Time) in `NowPlayingPushFilter.swift`; that file isn't in the 3.11.1 tag, and a full search of 3.11.1 was cut short by GitHub's rate limit. Readium also uses `UserDefaults`, which we already declare. `check-compliance.sh` only checks tracking and collected data, not required-reason APIs. | `swift-toolkit` tree at `3.11.1` has no `*.xcprivacy`; GRDB's tree has `GRDB/PrivacyInfo.xcprivacy`. | `appstore-review` §1.2 (ITMS-91053) | `A1.10` |
| F-A4 | A | Low | `TokenProvider.swift:71`, `OAuthClient.swift` | `status: 0` is overloaded: it means both "no refresh token" and an error returned in the callback, and `isRejectedGrant` treats every 0 as a rejected grant. Correct today, but fragile. A dedicated error case would be clearer. | Code. | — | `A1.3` |
| F-B3 | B | Low | `RemoteZipReader.swift:25` | `UInt64(try await cache.length())` traps if an adapter reports a negative length, for example from a bad `Content-Length`. Adapters (P2.5/P2.6) should validate it, or the reader should throw. | Code. | — | `A1.1` |
| F-B4 | B | Low | `BookStorage/BookFileStore.swift:67` | Covers live in `Caches`, which iOS may purge. Nothing regenerates a missing cover, so the book shows the placeholder from then on. | Design. | `ARCHITECTURE.md` file storage | Phase 3 (note in `UI_SPEC.md`) |
| F-C2 | C | Low | `EPUBArchive.swift:77`, `RemoteZipReader.swift:79` | `bytesRead` (read, then `await`, then write) and the shared `fetchHint` are only correct because entries are read one at a time. Concurrent reads would let the total-bytes limit be exceeded, or use each other's hints. Lead L3; latent, not live. | `EPUBMetadataReader` awaits each read in turn. | `swift-concurrency-pro` `actors.md` (reentrancy) | Document the assumption in code (`A1.1`) |
| F-C3 | C | Low | `FilesRemoteSource.swift:131` | A coordinated iCloud fetch and copy can't be cancelled. P2.9 needs "tap again to cancel". | No cancellation handler. | `cancellation.md` | P2.9 |
| F-D4 | D | Low | `Tests/RemoteSourcesTests/FilesRemoteSourceTests.swift` | Two untested cases: a file deleted between two listings (the P2.4 "Done when" asks for deletions), and the stale-bookmark refresh path (lead L7). | Test list. | `ACTION_PLAN.md` P2.4 | `A1.6` |
| F-E2 | E | Low | `App/Features/Library/BookImportController.swift:21-35` | Two imports at once (an "Open in…" during a picker import) share `isImporting` and `errorMessage`. The first one to finish clears the spinner, and the later failure message replaces the earlier one. | Code. | `swiftui-pro` `data.md` | `A1.8` |
| F-E3 | E | Low | `App/EreaderApp.swift:25` | `onOpenURL` hands every URL to the importer without checking `isFileURL`. Once P2.5 registers an OAuth redirect scheme, a stray callback URL would show "Couldn't import". | Code. | — | P2.5 |
| F-E4 | E | Low | `LibraryView.swift:49` | `Binding(get:set:)` built in `body` for the alert. | Code. | `swiftui-pro` `data.md` | `A1.8` |
| F-E5 | E | Low | `LibraryView.swift:66` | A database observation error silently empties the list and shows "No Books Yet", which looks like the library was lost. | Code. | `UI_SPEC.md` | `A1.8` |
| F-F2 | F | Low | `LibraryView.swift:35`, `:99-108` | The combined book row includes the cover image (unlabelled) or the `book.closed` symbol, which VoiceOver reads as "Closed Book". The toolbar `ProgressView` has no label. | Code. | `ios-accessibility` `playbook.md` ("Decorative image can be reached") | `A1.9` |
| F-G2 | G | Low | `scripts/check-compliance.sh` | No check ties required-reason API use in our own sources (`UserDefaults`, file timestamps, disk space, boot time) to the manifest. Today's manifest is correct (CA92.1, C617.1, 3B52.1); the risk is drift. | Script. | `appstore-review` §1.2 | `A1.10` |
| F-I1 | I | Low | `docs/ACTION_PLAN.md` P1.5 | P1.5 is ticked, but the Files picker and "Open in…" have never been tried by hand. Its "Done when" is met by tests, but the UI path is unverified. | No device run. | `AGENTS.md` rule 6 | Deferred (device) |

### Leads dismissed

| Lead | Why |
|---|---|
| L3 | Real but latent; recorded as F-C2 (Low), not a live bug. |
| L9 | `BookImportController` lives in the app's `@State` for the whole app lifetime, so an import outliving its view is intended. The real problem there is F-E2. |
| Path traversal in `ArchivePath` | Resolved paths are only used as keys for looking up entries inside the archive, never as file-system paths. Percent-decoding happens before `..` handling, so `%2e%2e%2f` is caught anyway (see the existing test). |

## Checklist results

Pass means checked against the code and meets the rule. N/A gives the reason.

**A. Credentials.**
- Pass:
  - `OSStatus` is handled, with `errSecItemNotFound` treated as absent; other statuses throw without deleting anything, which is non-destructive.
  - Explicit `AfterFirstUnlockThisDeviceOnly`, not synchronised; data-protection keychain.
  - Update-or-add is correct for this single writer. The skill's add-then-update order avoids a race between two writers, which `TokenProvider` already serialises.
  - No `SecItem*` on the main actor (`TokenProvider` is an actor).
  - Redacted `description`; errors carry no tokens.
  - `SecRandomCopyBytes` for PKCE and `state`; `state` is checked first.
  - Ephemeral `ASWebAuthenticationSession`; shared refresh.
  - `signOut` deletes even if revocation fails, except in the F-A2 case.
  - Ephemeral `URLSession`; no ATS exceptions.
- Findings: F-A1–F-A4.
- Note: the custom-scheme callback is protected by PKCE and by `ASWebAuthenticationSession`'s handling of the callback. On iOS 17.4+, `ASWebAuthenticationSession.Callback.https` with associated domains is stronger; consider it at P2.5/P2.6.

**B. Untrusted input.**
- Pass:
  - External entities off; depth cap.
  - Count, size, and ratio caps; real output is counted.
  - Pixel cap checked before an ImageIO thumbnail decode.
  - `FilesListing` rejects `.` / `..` and drops symlinks that resolve outside the folder.
  - The fallback's temporary copy is removed by `defer` on every path.
  - Limit errors don't trigger the fallback.
  - Import releases its security scope and cleans up on failure; the Inbox copy is deleted.
  - Book file names come from ids.
  - Data Protection is applied to the database and books.
- Findings: F-B1–F-B4.

**C. Concurrency.**
- Pass:
  - The three closure-form streams finish on every path and cancel their `Task` in `onTermination`. `makeStream(of:)` would be tidier, but this isn't a defect.
  - Both continuations resume exactly once (`NSFileCoordinator` always calls its accessor; `start() == false` resumes once).
  - `assumeIsolated` is valid, because `ASWebAuthenticationSession` asks for the anchor on the main thread.
  - `InMemoryTokenStore` locks every member.
  - `TokenProvider`'s shared task is safe across reentrancy.
- Findings: F-C1–F-C3.

**D. Tests.**
- Pass:
  - Every suite is a struct; temporary folders are removed with `defer`.
  - `#require` is used for preconditions; no force-unwraps.
  - Parameterised where cases repeat.
  - `#expect(throws:)` names specific errors.
  - Time is injected (`OAuthClient.now`); dates are fixed.
- Findings: F-D1–F-D4.

**E. SwiftUI.**
- Pass:
  - No deprecated APIs for iOS 17 (`@Observable`, `@Entry`, `foregroundStyle`, `ContentUnavailableView`).
  - Strings go through the catalog, with a locale-aware list format.
  - The database-open failure has a user-facing screen.
- N/A: "one type per file" (the project groups small record types on purpose, `CONVENTIONS.md`).
- Findings: F-E1–F-E5.

**F. Accessibility.**
- Pass: the import button has a text label; text uses text styles; colours are semantic.
- Deferred: manual VoiceOver and Dynamic Type passes (device).
- Findings: F-F1, F-F2.

**G. Compliance (Track 1).**
- Pass:
  - §1.5: no ATS keys.
  - §1.6: `ITSAppUsesNonExemptEncryption = NO`. Only HTTPS, plus SHA-256 for PKCE, which is exempt.
  - §1.7: only the Data Protection entitlement; `TARGETED_DEVICE_FAMILY = 1`; `SUPPORTS_MACCATALYST = NO`; `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO`.
  - §1.8: no `print`; no force-unwraps; `Secrets.example.xcconfig` holds empty public ids only.
  - Document types: EPUB `Viewer` / `Alternate`, not opened in place.
- N/A: §1.1 (app incomplete by design), §1.3/1.4 (no IAP, no account, no privacy policy yet; needed before TestFlight), Track 2.
- Not done: "`check-compliance.sh` fails CI on each broken rule" needs throwaway-branch runs; folded into `A1.10`.
- `-UITestMode` only swaps in an empty in-memory library, so it's harmless in release.
- Findings: F-G1, F-G2.

**H. Background readiness.**
- Pass:
  - Database, books, and covers use `completeUntilFirstUserAuthentication`, and Keychain items use `AfterFirstUnlockThisDeviceOnly`, so a locked-device `BGAppRefreshTask` can read both.
  - `AppEnvironment.live()` is built in `App.init`, which runs on background launches.
  - Repositories and remote sources have no main-actor dependency.
- Note for P2.7/P2.9: register `BGTaskScheduler` handlers in `App.init`, always set expiration handlers, and use a delegate-based background `URLSession` with the relaunch flow (`background-execution` core instructions).

**I. Process.**
- Pass:
  - Each ticked task has a green CI run.
  - Docs match the code (checked the P2.2–P2.4 "As implemented" sections against the source).
  - `Package.resolved` holds only Readium's own dependencies besides GRDB and ZIPFoundation: CryptoSwift, DifferenceKit, Fuzi, GCDWebServer, SQLite.swift, SwiftSoup, Zip.
  - CI pins `macos-15` and Xcode 26.3, pins actions to commit SHAs, runs `--strict` lint, and uses only `vars.*` (public ids).
  - A git-history scan for token-like strings found nothing; no `.epub` files are committed.
  - Commits name task ids.
- Finding: F-I1.
- Note: GCDWebServer is unmaintained. Confirm the app never links `ReadiumAdapterGCDWebServer` (it doesn't today: `project.yml` links only the Navigator, Shared, and Streamer modules).
