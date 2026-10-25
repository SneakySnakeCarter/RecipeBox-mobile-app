import Foundation
import UIKit

/// The hand-off point between the Share Extension and the main app.
///
/// The extension can't run the OCR/AI flow itself (it has a small memory
/// budget and can't show the app's navigation), so it drops what was shared
/// into a folder inside the App Group container. The main app looks in that
/// folder whenever it becomes active and imports what it finds.
///
/// THIS FILE MUST BE A MEMBER OF BOTH TARGETS (RecipeBox and ShareExtension).
enum SharedInbox {

    /// ⚠️ Change this to the App Group you create in Xcode
    /// (Signing & Capabilities → + Capability → App Groups). It must be
    /// identical on both targets. Convention: "group." + your bundle ID.
    static let appGroupID = "group.com.chadchurch.RecipeBox"

    /// One share action: some images, some text, maybe links.
    struct Batch {
        let id: String
        let folder: URL
        let imageFiles: [URL]
        let text: String
        let links: [String]
    }

    private struct Manifest: Codable {
        var created: Date
        var imageFiles: [String]
        var text: String
        var links: [String]
    }

    private static var inboxURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("SharedInbox", isDirectory: true)
    }

    /// False when the App Group isn't set up (wrong ID, capability missing).
    static var isAvailable: Bool { inboxURL != nil }

    // MARK: - Writing (Share Extension)

    /// Stores one share action. Returns false if nothing could be saved.
    @discardableResult
    static func write(images: [Data], text: String, links: [String]) -> Bool {
        guard let inbox = inboxURL, !(images.isEmpty && text.isEmpty) else { return false }
        let id = UUID().uuidString
        let folder = inbox.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var names: [String] = []
            for (index, data) in images.enumerated() {
                let name = String(format: "%02d.jpg", index)
                try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                names.append(name)
            }
            let manifest = Manifest(created: Date(), imageFiles: names, text: text, links: links)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            // The manifest is written last: a batch without one is treated
            // as unfinished and ignored by the app.
            try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
            return true
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return false
        }
    }

    // MARK: - Reading (main app)

    /// Finished batches, oldest first.
    static func pendingBatches() -> [Batch] {
        guard let inbox = inboxURL,
              let folders = try? FileManager.default.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: nil
              ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var found: [(Date, Batch)] = []
        for folder in folders {
            let manifestURL = folder.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? decoder.decode(Manifest.self, from: data) else {
                // Unfinished or corrupt: clean up if it has been sitting a while.
                removeIfStale(folder)
                continue
            }
            let batch = Batch(
                id: folder.lastPathComponent,
                folder: folder,
                imageFiles: manifest.imageFiles.map { folder.appendingPathComponent($0) },
                text: manifest.text,
                links: manifest.links
            )
            found.append((manifest.created, batch))
        }
        return found.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    static func remove(_ batch: Batch) {
        try? FileManager.default.removeItem(at: batch.folder)
    }

    private static func removeIfStale(_ folder: URL) {
        let values = try? folder.resourceValues(forKeys: [.contentModificationDateKey])
        if let modified = values?.contentModificationDate, Date().timeIntervalSince(modified) > 3600 {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Decodes a batch's images, in the order they were shared.
    static func loadImages(from batch: Batch) -> [UIImage] {
        batch.imageFiles.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }
    }
}
