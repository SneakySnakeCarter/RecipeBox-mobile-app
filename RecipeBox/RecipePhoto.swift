import SwiftUI
import Photos
import ImageIO

/// Where a stored picture lives.
///
/// - `file`: a JPEG inside the app's own photo folder (name only, not the
///   path — the app's container path can change between launches). Used for
///   photos taken with the camera or received from the Share Extension.
/// - `asset`: a reference to an item in the person's photo library (its
///   local identifier). Nothing is copied; if the photo is deleted from the
///   library, the picture is gone from the recipe too.
enum StoredImageRef: Hashable {
    case file(String)
    case asset(String)

    var storage: String {
        switch self {
        case .file: return "file"
        case .asset: return "asset"
        }
    }
    var location: String {
        switch self {
        case .file(let name): return name
        case .asset(let id): return id
        }
    }
    init?(storage: String, location: String) {
        switch storage {
        case "file": self = .file(location)
        case "asset": self = .asset(location)
        default: return nil
        }
    }
}

/// What a recipe picture is attached to. With neither an ingredient nor a
/// step it belongs to the recipe as a whole (its name).
enum PhotoAttachment: Hashable {
    case recipe
    case ingredient(UUID)
    case step(UUID)
}

struct RecipePhoto: Identifiable, Equatable {
    let id: UUID
    var ref: StoredImageRef
    var attachment: PhotoAttachment
    var caption: String

    init(id: UUID = UUID(), ref: StoredImageRef, attachment: PhotoAttachment = .recipe, caption: String = "") {
        self.id = id
        self.ref = ref
        self.attachment = attachment
        self.caption = caption
    }
}

enum RecipePhotoLimits {
    /// Most pictures one recipe can hold. Also enforced by a trigger in the
    /// database (RecipeSchema).
    static let maxPerRecipe = 10
}

// MARK: - Storage

enum PhotoStore {

    /// Folder for photos taken with the camera. Application Support is
    /// private to the app and included in device backups.
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("RecipeBox/Photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func url(forFile name: String) -> URL {
        folder.appendingPathComponent(name)
    }

    /// Writes a camera / shared photo into the folder. nil if it can't be saved.
    static func saveToFolder(_ image: UIImage, maxDimension: CGFloat = 3000) -> StoredImageRef? {
        let prepared = image.uprightDownscaled(maxDimension: maxDimension)
        guard let data = prepared.jpegData(compressionQuality: 0.85) else { return nil }
        let name = UUID().uuidString + ".jpg"
        do {
            try data.write(to: url(forFile: name), options: .atomic)
            return .file(name)
        } catch {
            return nil
        }
    }

    /// The reference to store for a photo picked from the library: a
    /// library reference when the app is allowed to read the library (so
    /// nothing is copied), otherwise a copy in the folder so the picture
    /// isn't lost to a missing permission.
    static func refForLibraryPick(
        image: UIImage,
        assetID: String?,
        completion: @escaping (StoredImageRef?) -> Void
    ) {
        func fallback() -> StoredImageRef? { saveToFolder(image) }
        guard let assetID else {
            DispatchQueue.main.async { completion(fallback()) }
            return
        }
        func decide(_ status: PHAuthorizationStatus) {
            DispatchQueue.main.async {
                completion(status == .authorized ? .asset(assetID) : fallback())
            }
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { decide($0) }
        } else {
            decide(status)
        }
    }

    /// Loads a stored picture at up to `maxPixel` on its long edge.
    /// Calls back on the main queue; nil if it can't be found any more.
    static func loadImage(_ ref: StoredImageRef, maxPixel: CGFloat, completion: @escaping (UIImage?) -> Void) {
        switch ref {
        case .file(let name):
            DispatchQueue.global(qos: .userInitiated).async {
                let image = downsampled(url: url(forFile: name), maxPixel: maxPixel)
                DispatchQueue.main.async { completion(image) }
            }
        case .asset(let id):
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
            guard let asset = assets.firstObject else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            var finished = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: maxPixel, height: maxPixel),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded && image != nil { return } // wait for the final one
                DispatchQueue.main.async {
                    guard !finished else { return }
                    finished = true
                    completion(image)
                }
            }
        }
    }

    /// Async form for SwiftUI `.task`.
    static func loadImage(_ ref: StoredImageRef, maxPixel: CGFloat) async -> UIImage? {
        await withCheckedContinuation { continuation in
            loadImage(ref, maxPixel: maxPixel) { continuation.resume(returning: $0) }
        }
    }

    /// Removes a stored file (library references have nothing to remove).
    static func delete(_ ref: StoredImageRef) {
        if case .file(let name) = ref {
            try? FileManager.default.removeItem(at: url(forFile: name))
        }
    }

    /// Deletes any file in the photo folder that no saved recipe uses —
    /// leftovers from imports that were abandoned. Run once at launch,
    /// before anything new is saved.
    static func collectGarbage(keeping names: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where !names.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func downsampled(url: URL, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Views

/// Shows a stored picture, loading it in the background. Cropped to fill
/// its frame by default (thumbnails); pass `fill: false` to fit it whole.
struct StoredImageView: View {
    let ref: StoredImageRef
    var maxPixel: CGFloat = 300
    var fill = true

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                if fill {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            } else if failed {
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.exclamationmark")
                    Text("Unavailable").font(.caption2)
                }
                .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: ref) {
            image = nil
            failed = false
            let loaded = await PhotoStore.loadImage(ref, maxPixel: maxPixel)
            if let loaded { image = loaded } else { failed = true }
        }
    }
}

/// Rebuilds the page a saved recipe was read from, for the Compare screen:
/// reloads its stored photo(s) and, for several, stitches them again the
/// same way they were first joined.
enum SourceLoader {
    static func load(
        refs: [StoredImageRef],
        removeOverlap: Bool,
        completion: @escaping (StitchedImage?) -> Void
    ) {
        guard !refs.isEmpty else {
            completion(nil)
            return
        }
        let maxPixel: CGFloat = refs.count == 1 ? 4096 : 2400
        var images = [UIImage?](repeating: nil, count: refs.count)
        var remaining = refs.count
        for (index, ref) in refs.enumerated() {
            PhotoStore.loadImage(ref, maxPixel: maxPixel) { image in
                images[index] = image // completions arrive on the main queue
                remaining -= 1
                if remaining == 0 { finish() }
            }
        }

        func finish() {
            let loaded = images.compactMap { $0 }
            guard !loaded.isEmpty else {
                completion(nil)
                return
            }
            if loaded.count == 1 {
                completion(.single(loaded[0]))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let stitched = ImageStitcher.stitch(loaded, removeOverlap: removeOverlap)
                DispatchQueue.main.async { completion(stitched) }
            }
        }
    }
}
