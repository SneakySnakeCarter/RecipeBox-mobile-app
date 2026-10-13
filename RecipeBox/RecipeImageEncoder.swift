import UIKit

/// Prepares a photo for the AI vision path: downscales it (image tokens
/// scale with pixel count, so a 12-megapixel camera photo costs far more
/// than it needs to and 1600px on the long edge is still plenty to read
/// print) and paints any regions the person blocked out in MaskEditorView
/// solid white, so the model never sees that text.
enum RecipeImageEncoder {
    /// - Parameter blockingRegions: image-fraction rects (0...1, top-left
    ///   origin) — the same rects MaskEditorView produces.
    static func jpegData(
        from image: UIImage,
        blockingRegions: [CGRect],
        maxDimension: CGFloat = 1600,
        quality: CGFloat = 0.8
    ) -> Data? {
        let size = image.size // orientation-aware, in points
        guard size.width > 0, size.height > 0 else { return nil }
        let longest = max(size.width, size.height)
        let factor = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1 // pixels == points, so `target` is the real pixel size
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)

        let rendered = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target)) // applies orientation
            UIColor.white.setFill()
            for region in blockingRegions {
                context.fill(CGRect(
                    x: region.minX * target.width,
                    y: region.minY * target.height,
                    width: region.width * target.width,
                    height: region.height * target.height
                ))
            }
        }
        return rendered.jpegData(compressionQuality: quality)
    }
}
