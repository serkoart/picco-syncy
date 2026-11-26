# Picco Syncy — Design Spec

**Status:** draft, agreed in conversation on 2026-11-25. Nothing is built yet.

## Goal

Send anything worth reading from the Mac to a BOOX Picco e-reader, in a form that reads well on a 3.97" 480×800 e-ink screen:

- a web page shared from Safari (or any app's Share menu),
- a Word document or PDF from Finder.

Everything becomes a small EPUB and waits in an outbox on the Mac. When the Picco is plugged in and put into USB transfer mode, the app copies new items over, reads back reading progress, and ejects the device.

## Scope

**Version 1**

- A native macOS menu-bar app.
- A macOS **Share extension** ("Send to Picco") that works from Safari, Finder, and any app that shares a URL or file.
- Web articles, Word/RTF documents, and PDFs (text and scanned).
- Optional images: greyscale and sized for the screen, or text only.
- USB delivery into `books/Articles/` on the Picco.
- Reading progress shown on the Mac. Nothing is deleted from the device automatically.

**Out of scope for v1** (decided, may come back later)

- iPhone app or iPhone share extension.
- Instapaper, or any other read-later service.
- Writing Boox's own `.opub` format. This is a fallback only (see [Fallback: `.opub`](#fallback-opub)).
- Wi-Fi delivery through the BOOX Tiles app.

**Why a Share extension and not a Safari Web Extension:** a single Share extension covers Safari, Finder, and other apps. In Safari it can still capture the page as you see it, logged-in content included, using a JavaScript preprocessing file. A Safari Web Extension would only cover Safari and adds a second extension model to maintain.

## What we know about the device

All of the following was tested on a real Picco on 2026-11-25, not taken from documentation.

| Fact | Detail |
|---|---|
| Mounting | It does **not** mount on plug-in. On the device: **Transfer → USB → Start USB-C transfer**. It then mounts as a FAT32 volume named **`BOOX TILE`** (~16 GB, removable). |
| Folder layout | `books/`, `images/`, `fonts/`, `screenshots/`, `update/`, and a hidden `.onyx/` (library index, settings, per-account reading data). |
| Plain EPUB in `books/` | **Works.** It shows in the library and opens. The file stays `.epub`. The device builds a parsed cache in `.onyx/covers/<hash>/`. |
| EPUB in a subfolder (`books/Articles/`) | **Works.** |
| `.txt`, `.html`, `.pdf` in `books/` | **Ignored.** They don't show up in the library. PDFs must be converted on the Mac. |
| Title and author in the library | Taken from the EPUB's `dc:title` and `dc:creator`, not from the file name. |
| Files sent by BOOX Tiles | Arrive as `.opub`, a proprietary binary format with a FlatBuffers-like layout, magic `BFPE`, and uncompressed text inside. Wallpapers are `.opg` (magic `BLAG`). The conversion runs in the browser on booxtiles.com (or in the Tiles app), not on the device. |
| Reading progress | `.onyx/<account-id>/local/books/<uuid>/state.json` is plain JSON: `path`, `title`, `author`, `progressPercent`, `finished`, `lastOpenedAt` (Unix seconds). For our files, `path` is `/books/Articles/<file>.epub`. |
| macOS side effects | Finder and Spotlight write `.Spotlight-V100`, `.fseventsd`, `.Trashes`, and `._*` AppleDouble files to the volume. Every file our process creates gets a `com.apple.provenance` tag, which can't be removed and is stored as a `._<name>` file. `FileManager` hides `._` files on FAT volumes; `unlink` on them works and drops the tag. |
| Ejecting | `NSWorkspace.unmountAndEjectDevice` failed with -47 (busy) with nothing open; `diskutil eject` succeeded immediately. |

There is no public API for any of this. The `.onyx/` layout is undocumented and may change with firmware updates. The app should read it defensively and never write to it.

## Architecture

```
 ┌─────────────────────┐      ┌──────────────────────────────────────────┐
 │ Share extension     │      │ Menu-bar app (PiccoSync)                 │
 │ "Send to Picco"     │      │                                          │
 │ - Safari: page HTML │ job  │  Inbox ──► Convert ──► Outbox ──► Sync   │
 │ - URL / file        ├─────►│           (PiccoKit)   (EPUBs)   (USB)   │
 │ - images on/off     │      │                                          │
 └─────────────────────┘      └──────────────────────────────────────────┘
          both in one App Group container           │
                                                     ▼
                                      /Volumes/BOOX TILE/books/Articles/
```

### Targets

| Target | Role |
|---|---|
| `PiccoKit` (Swift package) | All logic: capture models, article extraction, document conversion, EPUB building, device access, progress reading. It has no UI, so all of it can be unit-tested. |
| `PiccoSync` (macOS app) | Menu-bar app (`LSUIElement`). It runs conversions, holds the outbox, watches for the Picco, syncs, and shows status. |
| `SendToPicco` (Share extension) | Captures input and drops a job into the shared container. It does no heavy work, because extensions have tight memory and time limits. |
| `picco` (CLI, development only) | `picco send <url|file>`, `picco sync`. Exercises PiccoKit end to end without the UI. |

The extension and the app share data through an **App Group** container. Signing uses the maintainer's Apple developer team; contributors sign with their own. The main app is **not sandboxed**: it needs to write to a removable volume it doesn't own, and it ships outside the Mac App Store. The extension is sandboxed, as macOS requires.

## Pipeline

### 1. Capture (Share extension)

| Source | What the extension captures |
|---|---|
| Safari page | A JS preprocessing file runs in the page and returns `document.documentElement.outerHTML`, `document.URL`, and `document.title`. This keeps logged-in and paywalled content the user can see. |
| URL from another app | The URL only. The app fetches it later in an off-screen `WKWebView`. Content behind a login may not come through. |
| File from Finder | A copy of the file (`.docx`, `.doc`, `.rtf`, `.pdf`, `.md`, `.txt`). |

The extension UI is a small sheet with the title (editable), an **Include images** toggle (default on), and Send. It writes `Inbox/<uuid>/job.json` plus the payload, then returns.

### 2. Convert (app, PiccoKit)

Every source becomes clean, minimal XHTML first, and then an EPUB.

- **Web pages:** run **Defuddle** (MIT, from Obsidian Web Clipper; vendored, chosen over Mozilla Readability.js on 2026-11-25) on the captured HTML in an off-screen `WKWebView`, using its synchronous `parse()` only. The async variant may call third-party services as a fallback. Keep the title, byline, site name, and published date. If extraction fails, report the failure clearly instead of shipping the whole page with its navigation.
- **Word / RTF:** `NSAttributedString` document reading (the same engine as `textutil`) → HTML → the sanitizer below.
- **Markdown / text:** a simple Markdown → HTML conversion.
- **PDF:**
  1. Extract text per page with PDFKit, using line positions.
  2. Drop running headers, footers, and page numbers: lines that repeat at the same position across most pages.
  3. Rebuild paragraphs from line spacing and indentation. Join hyphenated line breaks.
  4. Detect headings from font size relative to the body text.
  5. Pages with no text layer get OCR with the **Vision** framework (`VNRecognizeTextRequest`, accurate mode).
  6. Pages that are mostly figures are kept as one greyscale image each.
  7. PDFs always open a **preview** before they're queued, because results vary with layout.
- **Sanitizer (all sources):** whitelist structural tags (`h1–h4, p, blockquote, ul, ol, li, em, strong, a, img, figure, figcaption, pre, code, table` basics). Remove scripts, styles, iframes, forms, and inline event handlers.
- **Images** (when on): download, convert to greyscale, scale to at most 480 px wide (no upscaling), encode as JPEG quality ~70, and drop anything under ~50 px (icons, trackers). When images are off, keep figure captions as text.

### 3. Build the EPUB (PiccoKit)

- EPUB 3 with an EPUB 2 `toc.ncx` alongside, for compatibility. The test file used only EPUB 3 nav and worked.
- `mimetype` stored first and uncompressed. Everything else deflated.
- Metadata: `dc:title` = article title, `dc:creator` = byline, or the site name if there's no byline, `dc:source` = URL, `dc:date` = published date, `dc:identifier` = the job's UUID.
- One minimal stylesheet: serif body text, modest margins, no fixed font sizes (the reader controls those), images `max-width: 100%`.
- One chapter for articles. Long documents are split at top-level headings so the Picco's table of contents is useful.
- Target size: under ~1 MB for a typical article with images.

### 4. Outbox

```
~/Library/Group Containers/<group>/
  Inbox/<uuid>/job.json + payload      ← written by the extension
  Outbox/<uuid>/item.json + book.epub  ← written by the app
```

`item.json` holds the title, source, created date, the device file name, state (`queued` / `delivered`), delivery date, and the last known progress.

The menu shows the queued and delivered items. You can preview, rename, or remove a queued item before it's sent.

### 5. Sync over USB

1. **Detect the Picco:** watch `NSWorkspace.didMountNotification`. A volume counts as the Picco when it's named `BOOX TILE` *and* has `books/` and `.onyx/`. A notification and the menu icon show "Picco connected".
2. **Copy queued items** into `books/Articles/`. Create the folder if it's missing.
   - File name: `<Title> — <Site>.epub`, cleaned for FAT32 (no `\ / : * ? " < > |`, no trailing dots or spaces, at most ~200 bytes of UTF-8). Duplicates get ` (2)`.
   - Write to a temporary name, flush to disk, then rename into place.
   - Write file contents only, with no extended attributes, so no `._*` files are created. Remove any `._*` files left in `books/Articles/`.
3. **Read progress:** scan `.onyx/*/local/books/*/state.json`. Match `path` to our delivered files and store `progressPercent`, `finished`, and `lastOpenedAt` in each `item.json`. Read only. Skip anything unparseable without failing.
4. **Eject** with `NSWorkspace.unmountAndEjectDevice(at:)` (setting: auto-eject after sync, default on). Report a busy volume instead of forcing the eject.
5. Put a `.metadata_never_index` file at the volume root so Spotlight stops indexing the device.

**Deleting:** nothing is deleted automatically. The menu has a manual **Remove finished from Picco** action. It only ever touches files inside `books/Articles/` that the app itself delivered.

## Menu-bar app UI

- Icon with a count badge for queued items.
- Sections: **Waiting** (queued), **On Picco** (delivered, with a progress bar and finished checkmark), and **Picco status** (connected / not connected, last sync time).
- Actions: Sync now (when connected), Remove finished from Picco, Open outbox folder, Settings.
- Settings: auto-sync on connect, auto-eject after sync, default for including images, launch at login.

## Fallback: `.opub`

This is only for the case where battery life with EPUB turns out to be a real problem in daily use. Two routes:

1. **Use the official converter:** leave the EPUBs in the outbox and upload them through booxtiles.com's USB-transfer page. The extra step is manual.
2. **Write our own `.opub` encoder:** study how booxtiles.com builds the format in the browser. This could break with any Boox update.

Neither is planned.

## Testing

- **Unit tests (PiccoKit):**
  - EPUB builder output passes `epubcheck`.
  - FAT32 file-name cleaning.
  - The sanitizer.
  - PDF heuristics against stored sample PDFs: single column, two columns, scanned, header/footer-heavy.
  - Readability extraction against saved HTML snapshots.
  - Parsing `state.json`, including the exact samples captured from the device.
- **Fake device:** a folder that mimics the `BOOX TILE` layout, with `.onyx/` sample files, to test sync without the Picco.
- **Manual checklist on the real device**, per release: delivered items show up with the right title and author; images render; the table of contents works on long documents; progress reads back after reading; eject works.

## Milestones

1. **M1 – PiccoKit core + CLI:** EPUB builder, sanitizer, web extraction, `picco send <url>` into a local outbox, `picco sync` to a mounted Picco. *Done when* an article sent from the CLI reads well on the device. **Status: done (2026-11-25).** Confirmed on the real Picco: Wikipedia (with images and a table of contents) and a Paul Graham essay both read well. The outbox is in `~/Library/Application Support/PiccoSync` until M3 moves it to the App Group. The `diskutil` eject fallback hasn't yet run on the device.
2. **M2 – Menu-bar app:** outbox UI, mount detection, auto-sync, progress readback, eject.
3. **M3 – Share extension:** Safari capture via JS preprocessing, URLs, Finder files, images toggle.
4. **M4 – Documents:** Word/RTF/Markdown, then PDF text extraction, OCR, and preview.
5. **M5 – Polish:** settings, launch at login, error reporting, the "Remove finished" action.

## Risks

- **Firmware changes:** the `.onyx/` layout or the USB-transfer flow could change. Progress reading must degrade gracefully, and delivery only relies on `books/`, which has been stable so far.
- **PDF quality:** complex layouts will never convert perfectly. The preview step manages expectations.
- **Battery:** there's a belief that native EPUB drains the battery faster than `.opub`. This is unverified. Keeping EPUBs lean is the first answer, and `.opub` is the fallback.
- **Paywalled pages from apps other than Safari:** URL-only capture can't see logged-in content. Safari is the recommended path.

## Test files

The test files from 2026-11-25 were deleted from the device after M1.
