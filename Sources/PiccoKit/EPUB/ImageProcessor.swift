import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns any image ImageIO can read into a small greyscale JPEG sized for the Picco's 480 px wide screen.
public enum ImageProcessor {
    public static let screenWidth = 480

    /// Returns nil for images that can't be decoded or are too small to be content (icons, tracking pixels).
    public static func greyscaleJPEG(
        from data: Data, maxWidth: Int = screenWidth, quality: Double = 0.7, minSide: Int = 50
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }

        let w = image.width
        let h = image.height
        guard w >= minSide, h >= minSide else { return nil }

        let targetW = min(w, maxWidth)
        let targetH = max(1, Int((Double(h) * Double(targetW) / Double(w)).rounded()))

        guard let ctx = CGContext(
            data: nil, width: targetW, height: targetH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        // Transparent areas become white, like paper.
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: targetW, height: targetH))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        guard let grey = ctx.makeImage() else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, grey, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
