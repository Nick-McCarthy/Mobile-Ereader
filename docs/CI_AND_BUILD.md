# CI & Build (GitHub Actions macOS runners)

> **Decision:** the owner develops on Windows, so **all builds, tests, and signed releases run on GitHub-hosted macOS runners**. There is no local Mac. Nothing is "tested" until CI has run it.

## Consequences for how we work
- **The Xcode project is generated, never hand-edited.** Use **XcodeGen**: `project.yml` is the source of truth, `*.xcodeproj` is git-ignored, and CI runs `xcodegen generate` first. (A `.pbxproj` can't be edited reliably without Xcode.) XcodeGen is a build tool, not an app dependency, so it's installed in CI with `brew install xcodegen`.
- **Pure-Swift packages** (`Core`, `EPUBMetadata`, `Persistence`, `RemoteSources` logic) should stay free of UIKit where practical, so most tests run with `swift test` and fail fast.
- **Feedback loop:** push a branch, then read the workflow result. UI tests attach screenshots to the `.xcresult` bundle, which is uploaded as a workflow artifact so you can see what the app looked like without a Mac.
- **Testing on a real iPhone** happens through **TestFlight** builds uploaded by the release workflow. Install the TestFlight app on the phone.

## Workflows

### `.github/workflows/ci.yml` (every push and pull request)
- Triggers: pushes to `main`, every pull request update, and manual runs (`workflow_dispatch`, for a branch without a PR). Feature-branch pushes don't trigger it on their own, so each PR update runs CI once.
- `runs-on: macos-15` (**pin** a runner image, not `macos-latest`, so Xcode doesn't change under us). Xcode is pinned to **26.3** (`XCODE_VERSION`), simulator **iPhone 17, iOS 26.2** (`SIMULATOR`). App Store uploads must use a current SDK, so stay on the latest Xcode the image offers. Bump these deliberately in their own PR after checking the runner image's readme.
- Steps: checkout → SPM cache (`Packages/EreaderKit/.build` and `build/SourcePackages`, keyed on the Xcode version and the manifests/resolved files) → `brew install xcodegen` → write `Config/Secrets.xcconfig` from **repository variables** (Dropbox app key, Microsoft client id: public identifiers, not secrets) → `xcodegen generate` → `swift-format lint --strict` → `swift test` per package → `xcodebuild test` on the simulator with `CODE_SIGNING_ALLOWED=NO` (simulator builds need no signing) → export UI-test screenshots as PNGs (`xcresulttool export attachments`) → upload the **`screenshots`** and **`test-results`** (`.xcresult`) artifacts, always, including on failure.
- **Package pinning:** direct dependencies use exact versions (`Package.swift`, `project.yml`). Transitive versions are pinned by two committed files:
  - `Packages/EreaderKit/Package.resolved`, used by `swift test --force-resolved-versions`.
  - `Config/Package.resolved`, which CI copies into the generated project (`Ereader.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/`) and builds with `-onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution`.

  Every run uploads the versions it resolved as the **`package-resolved`** artifact. **To add or bump a package** (without a Mac): change the manifest, delete the affected resolved file(s), push, then commit the files from that run's `package-resolved` artifact. The run fails on purpose (*Require committed Package.resolved files*) until they're committed.
- Fail on Swift warnings in **our** code only: `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES` in `project.yml` and `.treatAllWarnings(as: .error)` on every `EreaderKit` target. Don't pass it on the `xcodebuild` command line: it would also reach third-party packages, which Xcode builds with `-suppress-warnings`, and the two flags conflict.
- `permissions: contents: read`. Uses **no secrets**, so it is safe for pull requests from forks.
- `concurrency` group per branch with `cancel-in-progress: true` to save runner minutes.

### `.github/workflows/release.yml` (manual `workflow_dispatch` or `v*` tags on `main` only)
- Archives, signs, and uploads to TestFlight / App Store Connect.
- Signing material stored as **GitHub encrypted secrets** in a protected `release` **environment** (required reviewer = owner): distribution certificate (`.p12`, base64) + its password, provisioning profile (base64), and an **App Store Connect API key** (`.p8`, key id, issuer id).
- Import into a temporary keychain created for the job, and delete it in an `if: always()` step. Never `echo` secrets; never upload them as artifacts.
- Build: `xcodebuild archive` → `xcodebuild -exportArchive` with an `ExportOptions.plist` (method `app-store`) → upload with the App Store Connect API key (`xcrun altool --upload-app` or Apple's Transporter CLI; confirm which Apple currently recommends when implementing P6.6). Auto-increment `CURRENT_PROJECT_VERSION` from `github.run_number`.

## Security rules for a public repository
- Never use the `pull_request_target` trigger, and never expose secrets to workflows that build untrusted PR code.
- Pin third-party actions to a full commit SHA (not a tag), and keep them to the essentials (`actions/checkout`, `actions/cache`, `actions/upload-artifact`).
- `GITHUB_TOKEN` permissions are read-only by default. Grant more per job only when needed.
- Enable Dependabot for GitHub Actions and SPM version updates.

## Cost
GitHub-hosted runners are free for public repositories on standard runners. If the repo becomes private, macOS minutes are billed at a much higher rate than Linux ones. Check current pricing and keep `cancel-in-progress` and caching on. Verify the current policy before relying on it.
