// Draws the Picco Syncy app icon: a closed book, black ink on e-paper grey, full-bleed (macOS rounds it).
// Usage: swift Scripts/make-icon.swift App/PiccoSyncy/AppIcon.icon
import AppKit

let canvas: CGFloat = 1024

func drawIcon(in ctx: CGContext, background: Bool) {
    // Only the --preview PNG paints paper; in the Icon Composer document the paper is the document fill.
    if background {
        let paper = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceGray(),
            colors: [CGColor(gray: 0.97, alpha: 1), CGColor(gray: 0.86, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(paper, start: CGPoint(x: 0, y: canvas), end: .zero, options: [])
    }

    // The book, seen from the front: cover, spine band, and the page block peeking out at the bottom.
    let ink = CGColor(gray: 0.10, alpha: 1)
    let line: CGFloat = 34
    let book = CGRect(x: 312, y: 262, width: 400, height: 500)

    ctx.setStrokeColor(ink)
    ctx.setFillColor(ink)
    ctx.setLineWidth(line)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)

    // Cover outline. The bottom edge sits above the page block.
    let cover = CGRect(x: book.minX, y: book.minY + 56, width: book.width, height: book.height - 56)
    ctx.addPath(CGPath(roundedRect: cover, cornerWidth: 44, cornerHeight: 44, transform: nil))
    ctx.strokePath()

    // Spine: a solid band down the left side.
    let spine = CGRect(x: cover.minX, y: cover.minY, width: 92, height: cover.height)
    let spinePath = CGMutablePath()
    spinePath.addRoundedRect(in: spine, cornerWidth: 44, cornerHeight: 44)
    spinePath.addRect(CGRect(x: spine.midX, y: spine.minY, width: spine.width / 2, height: spine.height))
    ctx.addPath(spinePath)
    ctx.fillPath()

    // Page block: an open-bottomed curve from the spine to the right edge, under the cover.
    let pages = CGMutablePath()
    pages.move(to: CGPoint(x: spine.maxX - 4, y: book.minY))
    pages.addLine(to: CGPoint(x: book.maxX - 44, y: book.minY))
    pages.addQuadCurve(to: CGPoint(x: book.maxX, y: book.minY + 44), control: CGPoint(x: book.maxX, y: book.minY))
    pages.addLine(to: CGPoint(x: book.maxX, y: cover.minY + 22))
    ctx.addPath(pages)
    ctx.strokePath()
    pages.closeSubpath()
    let leftFoot = CGMutablePath()
    leftFoot.move(to: CGPoint(x: spine.minX + 22, y: cover.minY + 10))
    leftFoot.addQuadCurve(to: CGPoint(x: spine.maxX, y: book.minY), control: CGPoint(x: spine.minX + 22, y: book.minY))
    ctx.addPath(leftFoot)
    ctx.strokePath()

    // Title label on the cover.
    let label = CGRect(x: spine.maxX + 64, y: cover.maxY - 170, width: cover.maxX - spine.maxX - 128, height: 60)
    ctx.addPath(CGPath(roundedRect: label, cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.setLineWidth(26)
    ctx.strokePath()
}

func png(size: Int, background: Bool = true) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = gc.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(in: ctx, background: background)
    gc.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

// The app's icon is an Icon Composer document (macOS 26 and later frame plain icon sets in a grey plate):
// the paper is the document's fill, the book is one layer.
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let assets = out.appending(path: "Assets", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
try png(size: 1024, background: false).write(to: assets.appending(path: "book.png"))
let icon = """
    {
      "fill" : {
        "linear-gradient" : [
          "extended-gray:0.97000,1.00000",
          "extended-gray:0.86000,1.00000"
        ]
      },
      "groups" : [
        {
          "layers" : [
            {
              "image-name" : "book.png",
              "name" : "book"
            }
          ],
          "shadow" : {
            "kind" : "neutral",
            "opacity" : 0.5
          },
          "translucency" : {
            "enabled" : false,
            "value" : 0.5
          }
        }
      ],
      "supported-platforms" : {
        "squares" : [
          "macOS"
        ]
      }
    }

    """
try Data(icon.utf8).write(to: out.appending(path: "icon.json"))
print("Wrote \(out.path)")
