# Picco Syncy

Mac app that sends web articles (later Word docs and PDFs) to a BOOX Picco e-reader as EPUB over USB.

**Read `SPEC.md` first.** It holds the agreed design, the device facts we tested on real hardware, and the milestones.

## Commands

```bash
swift build                      # build PiccoKit + the picco CLI
swift test                       # unit tests (Swift Testing)
.build/debug/picco help          # CLI usage
PICCO_HOME=/tmp/picco .build/debug/picco send <url>   # use a throwaway outbox while developing
```

## Layout

- `Sources/PiccoKit/` — all logic, no UI. `EPUB/` (ZIP + EPUB writer, image processing), `Web/` (WKWebView extraction, article assembly), `Device/` (Picco volume access, file names), `Outbox/` (queue + sync).
- `Sources/PiccoKit/Resources/` — `defuddle.js` (vendored, see `ThirdParty/defuddle/`), `extract.js` (our sanitizer), `style.css`.
- `Sources/picco/` — development CLI. Runs inside an invisible `NSApplication` because WKWebView needs a main run loop.

## Rules

- Never write to the Picco outside `books/Articles/` (plus the `.metadata_never_index` marker). Never write to `.onyx/`.
- Write files to the device as raw data (`FileHandle`), not with `FileManager.copyItem`, so macOS doesn't create `._*` AppleDouble files.
- `defuddle.js` is vendored unmodified. To update it, replace the file and update `ThirdParty/defuddle/VERSION` (version + SHA-256).
- The extracted article must stay well-formed XHTML: the Picco is likely to parse chapters as XML.
