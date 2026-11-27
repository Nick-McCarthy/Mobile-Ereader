# Mobile E-reader

A native iPhone EPUB reader (Swift + SwiftUI, iOS 17+). Books can be imported on the device or synced from the user's choice of **iCloud Drive**, **Dropbox**, or **OneDrive**. The reader is built on the Readium Swift Toolkit.

- Requirements: [`Concept.md`](Concept.md)
- Agent and contributor guide: [`Agents.md`](Agents.md) → specs and the action plan in [`docs/`](docs)

## Status
Early scaffolding: an empty three-tab app. Progress is tracked in [`docs/ACTION_PLAN.md`](docs/ACTION_PLAN.md).

## How it's built
There's no local Mac. Every push runs the [CI workflow](.github/workflows/ci.yml) on GitHub's macOS runners. It lints, runs the package tests, generates the Xcode project, and runs the UI tests on an iPhone simulator. Each run uploads:
- **`screenshots`**: PNG screenshots taken by the UI tests (viewable on any OS)
- **`test-results`**: the full `.xcresult` bundle (needs Xcode to open)

Find them on the run's page under **Actions → CI → (run) → Artifacts**. Details: [`docs/CI_AND_BUILD.md`](docs/CI_AND_BUILD.md).

## Building on a Mac (optional)
```sh
brew install xcodegen
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # fill in when needed
xcodegen generate
open Ereader.xcodeproj
```
The `.xcodeproj` is generated from [`project.yml`](project.yml) and is not committed. Edit `project.yml` instead.

Package tests only: `swift test --package-path Packages/EreaderKit`

## Layout
```
App/                    SwiftUI app target
UITests/                XCUITest target (also produces CI screenshots)
Packages/EreaderKit/    Core, Persistence, EPUBMetadata, RemoteSources, BookStorage modules
Config/                 xcconfig files (Secrets.xcconfig is git-ignored)
docs/                   specs and action plan
project.yml             XcodeGen project definition
```

## License
See [`LICENSE`](LICENSE).
