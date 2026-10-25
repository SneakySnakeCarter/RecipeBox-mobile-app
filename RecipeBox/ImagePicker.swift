import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Maximum photos per recipe, from the library or the camera. Each photo
/// costs memory while it's held, so this is a safety limit.
enum PhotoImportLimits {
    static let maxPhotos = 10
}

/// Picks one or more photos from the user's library, in the order they were
/// selected. Photos are downsampled as they load (a 12-megapixel original
/// decoded in full is ~48 MB, and ten of them would be trouble) — to 4096 px
/// on the long edge for a single photo, 2400 px when several are chosen.
struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let onPicked: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = PhotoImportLimits.maxPhotos
        config.selection = .ordered
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoLibraryPicker
        init(_ parent: PhotoLibraryPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { return }

            let maxPixel = results.count == 1 ? 4096 : 2400
            var images = [UIImage?](repeating: nil, count: results.count)
            let lock = NSLock()
            let group = DispatchGroup()

            for (index, result) in results.enumerated() {
                group.enter()
                result.itemProvider.loadDataRepresentation(
                    forTypeIdentifier: UTType.image.identifier
                ) { data, _ in
                    defer { group.leave() }
                    guard let data, let image = Self.downsampledImage(from: data, maxPixel: maxPixel) else { return }
                    lock.lock()
                    images[index] = image
                    lock.unlock()
                }
            }

            group.notify(queue: .main) {
                self.parent.onPicked(images.compactMap { $0 })
            }
        }

        /// Decodes straight to a bounded size (applying the photo's
        /// orientation) instead of decoding the full image and shrinking it.
        private static func downsampledImage(from data: Data, maxPixel: Int) -> UIImage? {
            guard let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
            ) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary
            ) else { return nil }
            return UIImage(cgImage: cgImage)
        }
    }
}

/// Captures one photo from the camera. For a multi-photo recipe the caller
/// presents it again after each shot.
struct CameraPicker: UIViewControllerRepresentable {
    let onCaptured: (UIImage) -> Void
    var onCancel: () -> Void = {}

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            picker.dismiss(animated: true)
            if let original = info[.originalImage] as? UIImage {
                // Upright and bounded in size, like library photos.
                parent.onCaptured(original.uprightDownscaled(maxDimension: 3000))
            } else {
                parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            parent.onCancel()
        }
    }
}

extension UIImage {
    /// A copy drawn upright (orientation applied) and, if larger, scaled so
    /// its long edge is `maxDimension` pixels.
    func uprightDownscaled(maxDimension: CGFloat) -> UIImage {
        let pixelWidth = size.width * scale
        let pixelHeight = size.height * scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > 0 else { return self }
        let factor = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: (pixelWidth * factor).rounded(), height: (pixelHeight * factor).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
