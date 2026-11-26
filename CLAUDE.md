# Picco Syncy

Mac app that sends web articles (later Word docs and PDFs) to a BOOX Picco e-reader as EPUB over USB.

**Read `SPEC.md` first.** It holds the agreed design, the device facts we tested on real hardware, and the milestones.

## Commands

```bash
swift build                      # build PiccoKit + the picco CLI
swift test                       # unit tests (Swift Testing)
.build/debug/picco help          # CLI usage
PICCO_HOME=/tmp/picco .build/debug/picco send <url>   # use a throwaway outbox while developing

# Menu-bar app (Xcode project in App/, uses the PiccoKit package at the repo root)
xcodebuild -project App/PiccoSyncy.xcodeproj -scheme PiccoSyncy -derivedDataPath .build/xcode -allowProvisioningUpdates build
open .build/xcode/Build/Products/Debug/PiccoSyncy.app
```

## Layout

- `Sources/PiccoKit/` — all logic, no UI. `EPUB/` (ZIP + EPUB writer, image processing), `Web/` (WKWebView extraction, article assembly), `Device/` (Picco volume access, file names), `Outbox/` (queue + sync).
- `Sources/PiccoKit/Resources/` — `defuddle.js` (vendored, see `ThirdParty/defuddle/`), `extract.js` (our sanitizer), `style.css`.
- `App/` — the menu-bar app (SwiftUI `MenuBarExtra`, not sandboxed, `LSUIElement`). `App/PiccoSyncy/` is a synchronized folder: new Swift files there are picked up without editing the project. Signing lives in `App/Config/Shared.xcconfig`; contributors override it in a git-ignored `App/Config/Local.xcconfig`.
- `Sources/picco/` — development CLI. Runs inside an invisible `NSApplication` because WKWebView needs a main run loop.

## Rules

- Never write to the Picco outside `books/Articles/` (plus the `.metadata_never_index` marker). Never write to `.onyx/`.
- macOS tags every file we create with `com.apple.provenance`, stored on FAT32 as a `._<name>` file that `FileManager` hides. `PiccoDevice.tidy()` lists with `readdir` and unlinks them after every sync. Don't replace that with a `FileManager` listing.
- New ways of adding articles go through `ArticleSender`, so the CLI, the app and the Share extension behave the same.
- `defuddle.js` is vendored unmodified. To update it, replace the file and update `ThirdParty/defuddle/VERSION` (version + SHA-256).
- The extracted article must stay well-formed XHTML: the Picco is likely to parse chapters as XML.
