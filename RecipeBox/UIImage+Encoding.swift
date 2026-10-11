import UIKit

extension UIImage {
    /// Downscales (if needed) and JPEG-encodes the image to a base64
    /// string, keeping API request size and cost reasonable.
    func jpegBase64(maxDimension: CGFloat, quality: CGFloat) -> String? {
        let scale = min(1, maxDimension / max(size.width, size.height))
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }

        return resized.jpegData(compressionQuality: quality)?.base64EncodedString()
    }
}
