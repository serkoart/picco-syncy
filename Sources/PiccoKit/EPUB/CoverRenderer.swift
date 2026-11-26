import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Draws a greyscale 2:3 cover for an article, used as its thumbnail in the Picco's library.
///
/// With a photo: the photo fills the top, the headline and site name sit underneath.
/// Without one: a black band with the site name, the headline below. Either way the headline
/// is on the cover, so articles stay recognisable even when the photo is generic.
public enum CoverRenderer {
    public static let width = 480
    public static let height = 720

    public static func jpeg(title: String, site: String, image: CGImage?, quality: Double = 0.8) -> Data? {
        let w = CGFloat(width)
        let h = CGFloat(height)
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let margin: CGFloat = 32
        let siteLabel = site.trimmingCharacters(in: .whitespaces).uppercased()
        // Core Graphics puts the origin at the bottom left; "top" below means high y.
        let bandBottom: CGFloat

        if let image {
            bandBottom = (h * 0.44).rounded()
            let area = CGRect(x: 0, y: bandBottom, width: w, height: h - bandBottom)
            ctx.saveGState()
            ctx.clip(to: area)
            ctx.draw(image, in: aspectFill(CGSize(width: image.width, height: image.height), in: area))
            ctx.restoreGState()
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: bandBottom - 3, width: w, height: 3))
        } else {
            bandBottom = (h * 0.62).rounded()
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: bandBottom, width: w, height: h - bandBottom))
            if !siteLabel.isEmpty {
                let box = CGRect(x: margin, y: bandBottom + margin, width: w - margin * 2, height: h - bandBottom - margin * 2)
                drawFitting(siteLabel, in: box, fontName: "Georgia-Bold", sizes: [40, 34, 28, 24, 20], gray: 1,
                    maxLines: 3, align: .bottom, tracking: 1.5, ctx: ctx)
            }
        }

        // Site name along the bottom (on photo covers; typographic covers already show it in the band).
        var textBottom = margin
        if image != nil, !siteLabel.isEmpty {
            let siteBox = CGRect(x: margin, y: margin, width: w - margin * 2, height: 24)
            drawFitting(siteLabel, in: siteBox, fontName: "HelveticaNeue-Medium", sizes: [15, 13, 11], gray: 0.25,
                maxLines: 1, align: .bottom, tracking: 1.2, ctx: ctx)
            textBottom = margin + 24 + 14
        }

        let titleBox = CGRect(x: margin, y: textBottom, width: w - margin * 2, height: bandBottom - 3 - 26 - textBottom)
        drawFitting(title, in: titleBox, fontName: "Georgia-Bold", sizes: [44, 40, 36, 32, 29, 26, 23, 21],
            gray: 0, maxLines: 8, align: .top, tracking: 0, ctx: ctx)

        guard let cover = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cover, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Decodes downloaded image data, ignoring anything too small to make a decent cover.
    public static func decode(_ data: Data, minSide: Int = 200) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            image.width >= minSide, image.height >= minSide
        else { return nil }
        return image
    }

    // MARK: - Drawing helpers

    enum VerticalAlign { case top, bottom }

    static func aspectFill(_ size: CGSize, in area: CGRect) -> CGRect {
        let scale = max(area.width / size.width, area.height / size.height)
        let w = size.width * scale
        let h = size.height * scale
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }

    /// Draws text at the largest of `sizes` that fits the box within `maxLines`; at the smallest size,
    /// whatever doesn't fit is cut off with an ellipsis.
    static func drawFitting(
        _ text: String, in box: CGRect, fontName: String, sizes: [CGFloat], gray: CGFloat,
        maxLines: Int, align: VerticalAlign, tracking: CGFloat, ctx: CGContext
    ) {
        guard !text.isEmpty, box.width > 0, box.height > 0 else { return }
        for (i, size) in sizes.enumerated() {
            let isLast = i == sizes.count - 1
            let attributed = attributedText(text, fontName: fontName, size: size, gray: gray, tracking: tracking)
            let setter = CTFramesetterCreateWithAttributedString(attributed)
            let frame = CTFramesetterCreateFrame(
                setter, CFRange(location: 0, length: 0),
                CGPath(rect: CGRect(x: 0, y: 0, width: box.width, height: 10_000), transform: nil), nil)
            let lines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
            let lineHeight = size * 1.18
            // Never let a single word be broken across lines (e.g. "PAULGRAHAM.CO / M").
            let widestWord = text.split(whereSeparator: \.isWhitespace).map { word in
                CTLineGetTypographicBounds(
                    CTLineCreateWithAttributedString(
                        attributedText(String(word), fontName: fontName, size: size, gray: gray, tracking: tracking)),
                    nil, nil, nil)
            }.max() ?? 0
            let fits = lines.count <= maxLines && CGFloat(lines.count) * lineHeight <= box.height
                && CGFloat(widestWord) <= box.width
            if fits || isLast {
                let maxFitting = max(1, min(maxLines, Int(box.height / lineHeight)))
                let shown = Array(lines.prefix(maxFitting))
                let truncated = lines.count > shown.count
                let blockHeight = CGFloat(shown.count) * lineHeight
                var baseline = align == .top ? box.maxY - size : box.minY + blockHeight - size
                ctx.textMatrix = .identity
                for (n, line) in shown.enumerated() {
                    var drawn = line
                    if truncated && n == shown.count - 1 {
                        // Lay out everything from this line to the end as one line, then cut it with "…".
                        let start = CTLineGetStringRange(line).location
                        let rest = (text as NSString).substring(from: start)
                        let long = CTLineCreateWithAttributedString(
                            attributedText(rest, fontName: fontName, size: size, gray: gray, tracking: tracking))
                        let ellipsis = CTLineCreateWithAttributedString(
                            attributedText("…", fontName: fontName, size: size, gray: gray, tracking: tracking))
                        drawn = CTLineCreateTruncatedLine(long, Double(box.width), .end, ellipsis) ?? line
                    }
                    ctx.textPosition = CGPoint(x: box.minX, y: baseline)
                    CTLineDraw(drawn, ctx)
                    baseline -= lineHeight
                }
                return
            }
        }
    }

    static func attributedText(_ text: String, fontName: String, size: CGFloat, gray: CGFloat, tracking: CGFloat)
        -> CFAttributedString
    {
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: gray, alpha: 1),
            kCTKernAttributeName: tracking,
        ]
        return CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
    }
}
