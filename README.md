# Picco Syncy

Send web articles from your Mac to a **BOOX Picco** e-reader, as clean, small EPUBs that read well on its 3.97" e-ink screen.

The Picco doesn't run Android, so the usual BOOX tools (Send2Boox, BOOXDrop) don't apply. It does mount as a USB drive and reads plain EPUB files. Picco Syncy uses that:

1. **Grab** a web page and extract just the article (headline, text, images), without menus, ads, or comments.
2. **Convert** it to a small EPUB: greyscale images sized for the 480 px screen, a table of contents built from the headings, and the title and author set so the Picco's library lists it properly.
3. **Queue** it in an outbox on your Mac.
4. **Sync** when the Picco is plugged in: copy new articles to `books/Articles/`, read your reading progress back, and eject.

> **Status:** early. The core library, a command-line tool and a menu-bar app work, and have been tested on a real Picco. A "Send to Picco" Share extension (Safari, Finder, any app) is next. Word and PDF conversion come after that. See [SPEC.md](SPEC.md) for the full design and roadmap.

## Requirements

- macOS 14 or later
- Swift 6 toolchain (Xcode 16 or later)
- A BOOX Picco and a USB-C cable

## The menu-bar app and Share extension

```bash
xcodebuild -project App/PiccoSyncy.xcodeproj -scheme PiccoSyncy -derivedDataPath .build/xcode build
open .build/xcode/Build/Products/Debug/PiccoSyncy.app
```

A book icon appears in the menu bar, with a count of articles waiting. From its panel you can paste a link to add an article, see what's on the Picco and how far you've read, and sync. When the Picco is connected in USB mode, the app syncs and ejects on its own; both can be turned off in Settings.

The app includes a **Send to Picco** Share extension. In Safari, choose **Share → Send to Picco**: it sends the page as you see it, including articles you're logged in to. Other apps that share a link work too. Copy the app to `/Applications` and open it once so macOS registers the extension, then turn it on under Safari's **Share → Edit Extensions…** if it isn't listed.

To build it yourself, create `App/Config/Local.xcconfig` with your own `DEVELOPMENT_TEAM` and `PICCO_BUNDLE_ID`. The app and extension share an App Group named after both.

## The command-line tool

```bash
git clone https://github.com/serkoart/picco-syncy.git
cd picco-syncy
swift build

# Convert an article and queue it
.build/debug/picco send https://paulgraham.com/greatwork.html

# Or write a single EPUB to look at first
.build/debug/picco epub https://en.wikipedia.org/wiki/Electronic_paper -o paper.epub

# See what's queued and what you've read
.build/debug/picco list
```

To sync, put the Picco into USB mode. On the Picco, plug it in, then tap **Transfer → USB → Start USB-C transfer**. It mounts as **BOOX TILE**. Then run:

```bash
.build/debug/picco sync
```

**Covers:** every article gets a greyscale cover, with the article's photo and headline, or a typographic one if there's no photo. The Picco builds thumbnails in the background after a sync: go **Home → Books** twice and they appear. That's the Picco's library, not something an EPUB can change.

Add `--no-images` to `send` for text-only articles. The outbox lives in `~/Library/Application Support/PiccoSync`. Set `PICCO_HOME` to use a different folder.

## What we learned about the Picco

These facts were found by testing on the device. None of them are documented by BOOX:

- Plain `.epub` files in `books/`, or any subfolder of it, show up in the library and open. `.txt`, `.html` and `.pdf` files copied over USB don't show up.
- The library uses the EPUB's own title and author, not the file name, and the EPUB's standard cover image as the thumbnail. It renders thumbnails in the background, so they appear on the second visit to Books after a sync.
- Reading progress is kept as small JSON files under `.onyx/`, which lets the Mac show how far you've read.
- Files sent through BOOX's own Tiles app are converted to `.opub`, BOOX's own format. Picco Syncy doesn't need it.

Picco Syncy only ever writes inside `books/Articles/`, and never touches BOOX's own data.

## How it works

- **[Defuddle](https://github.com/kepano/defuddle)** (MIT) finds the article. It runs inside an off-screen WebKit view, so pages render as they do in Safari.
- A small sanitizer reduces the article to a safe subset of XHTML.
- PiccoKit, a Swift package with no dependencies, handles the EPUB writing, greyscale image conversion, and device sync.

## Not affiliated with BOOX

Picco Syncy is an independent project. It isn't made, endorsed, or supported by BOOX or Onyx International. "BOOX" and "Picco" are their trademarks, used here only to say which device this works with.

## License

[MIT](LICENSE). Defuddle is included unmodified under its own MIT license; see [ThirdParty/defuddle](ThirdParty/defuddle/).
