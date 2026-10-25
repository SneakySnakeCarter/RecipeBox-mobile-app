import UIKit

/// Prepares a recipe page for the AI vision path. Each source photo is sent
/// as its own downscaled JPEG (one very tall stitched image would have to be
/// shrunk until its text was unreadable), cropped to the rows the stitcher
/// kept, and with any areas the person blocked out in MaskEditorView painted
/// solid white so the model never sees that text.
enum RecipeImageEncoder {
    /// - Parameter blockingRegions: composite-fraction rects (0...1, top-left
    ///   origin) — the same rects MaskEditorView produces.
    /// - Returns: JPEG data for each photo, top to bottom.
    static func jpegPieces(
        from source: StitchedImage,
        blockingRegions: [CGRect],
        maxDimension: CGFloat = 1600,
        quality: CGFloat = 0.8
    ) -> [Data] {
        source.segments.compactMap { segment in
            let size = segment.image.size // orientation-aware, in points
            guard size.width > 0, size.height > 0 else { return nil }
            let keptHeight = size.height * (segment.srcBottom - segment.srcTop)
            guard keptHeight >= 24 else { return nil } // a sliver with nothing to read

            let longest = max(size.width, keptHeight)
            let factor = longest > maxDimension ? maxDimension / longest : 1
            let target = CGSize(
                width: (size.width * factor).rounded(),
                height: (keptHeight * factor).rounded()
            )

            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1 // pixels == points, so `target` is the real pixel size
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: target, format: format)

            let destSpan = segment.destBottom - segment.destTop
            let rendered = renderer.image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: target))
                // Draw the whole source shifted up so only the kept rows land in view.
                segment.image.draw(in: CGRect(
                    x: 0,
                    y: -segment.srcTop * size.height * factor,
                    width: size.width * factor,
                    height: size.height * factor
                ))
                UIColor.white.setFill()
                for region in blockingRegions where destSpan > 0 {
                    // The part of this mask that falls on this photo's kept rows.
                    let top = max(region.minY, segment.destTop)
                    let bottom = min(region.maxY, segment.destBottom)
                    guard bottom > top else { continue }
                    context.fill(CGRect(
                        x: region.minX * target.width,
                        y: (top - segment.destTop) / destSpan * target.height,
                        width: region.width * target.width,
                        height: (bottom - top) / destSpan * target.height
                    ))
                }
            }
            return rendered.jpegData(compressionQuality: quality)
        }
    }
}
