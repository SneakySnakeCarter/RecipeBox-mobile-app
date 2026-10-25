import UIKit
import UniformTypeIdentifiers
import ImageIO

/// The screen iOS shows when someone picks RecipeBox in a share sheet
/// (Instagram's "Share to…", Photos, Safari, Notes…).
///
/// It does the minimum: collect the shared images / text / links, save them
/// into the App Group inbox (SharedInbox.swift), and tell the person to open
/// RecipeBox. The main app does the OCR / AI work when it next opens, so
/// the extension stays well inside its small memory limit and never needs
/// the API key.
final class ShareViewController: UIViewController {

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)

    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildUI()
        showWorking()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        collectSharedItems()
    }

    // MARK: - Collecting

    /// Filled in from the item providers' background callbacks, so access
    /// goes through a lock. Keyed by position so the shared order is kept.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var _images: [Int: Data] = [:]
        private var _texts: [Int: String] = [:]
        private var _links: [Int: String] = [:]

        func add(image: Data, at i: Int) { lock.lock(); _images[i] = image; lock.unlock() }
        func add(text: String, at i: Int) { lock.lock(); _texts[i] = text; lock.unlock() }
        func add(link: String, at i: Int) { lock.lock(); _links[i] = link; lock.unlock() }

        var images: [Int: Data] { lock.lock(); defer { lock.unlock() }; return _images }
        var texts: [Int: String] { lock.lock(); defer { lock.unlock() }; return _texts }
        var links: [Int: String] { lock.lock(); defer { lock.unlock() }; return _links }
    }

    private func collectSharedItems() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        guard !providers.isEmpty else {
            showResult(.nothing)
            return
        }

        let collected = Collected()
        let group = DispatchGroup()

        for (index, provider) in providers.enumerated() {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                    let data = Self.jpegData(fromSharedImage: item)
                    if let data { collected.add(image: data, at: index) }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    var string: String?
                    if let text = item as? String { string = text }
                    else if let attributed = item as? NSAttributedString { string = attributed.string }
                    if let string { collected.add(text: string, at: index) }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    var link: String?
                    if let url = item as? URL { link = url.absoluteString }
                    else if let string = item as? String { link = string }
                    if let link { collected.add(link: link, at: index) }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.finish(with: collected)
        }
    }

    private func finish(with collected: Collected) {
        let images = collected.images.sorted { $0.key < $1.key }.map { $0.value }
        var links = collected.links.sorted { $0.key < $1.key }.map { $0.value }

        // Some apps share a bare link as *text*. Treat that as a link.
        var textParts: [String] = []
        for text in collected.texts.sorted(by: { $0.key < $1.key }).map({ $0.value }) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isBareLink(trimmed) { links.append(trimmed) }
            else if !trimmed.isEmpty { textParts.append(trimmed) }
        }
        let text = textParts.joined(separator: "\n\n")

        if images.isEmpty && text.isEmpty {
            showResult(links.isEmpty ? .nothing : .linkOnly)
            return
        }
        guard SharedInbox.isAvailable else {
            showResult(.setupProblem)
            return
        }
        if SharedInbox.write(images: images, text: text, links: links) {
            showResult(.saved(imageCount: images.count, hasText: !text.isEmpty))
        } else {
            showResult(.failed)
        }
    }

    private static func isBareLink(_ string: String) -> Bool {
        guard !string.contains(where: { $0.isWhitespace }),
              let url = URL(string: string),
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// The system hands over a file URL, raw Data, or a UIImage depending
    /// on the sending app. All of them end up as a downscaled JPEG.
    /// Downscaling while decoding (ImageIO) keeps a full-resolution photo
    /// from ever being fully decoded, which matters in an extension.
    private static func jpegData(fromSharedImage item: NSSecureCoding?) -> Data? {
        let maxPixel: CGFloat = 2400
        var source: CGImageSource?

        if let url = item as? URL {
            source = CGImageSourceCreateWithURL(url as CFURL, nil)
        } else if let data = item as? Data {
            source = CGImageSourceCreateWithData(data as CFData, nil)
        } else if let image = item as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
            source = CGImageSourceCreateWithData(data as CFData, nil)
        }
        guard let source else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // bake in rotation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.85)
    }

    // MARK: - UI

    private enum Outcome {
        case saved(imageCount: Int, hasText: Bool)
        case linkOnly, nothing, setupProblem, failed
    }

    private func showResult(_ result: Outcome) {
        spinner.stopAnimating()
        doneButton.isHidden = false

        switch result {
        case .saved(let imageCount, let hasText):
            iconView.image = UIImage(systemName: "checkmark.circle.fill")
            iconView.tintColor = .systemGreen
            titleLabel.text = "Saved to RecipeBox"
            var what: [String] = []
            if imageCount > 0 { what.append(imageCount == 1 ? "1 image" : "\(imageCount) images") }
            if hasText { what.append("text") }
            messageLabel.text = "\(what.joined(separator: " and ")) ready. Open RecipeBox to read the recipe."
            // Nothing to decide, so close on its own.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.complete() }
        case .linkOnly:
            iconView.image = UIImage(systemName: "link.badge.plus")
            iconView.tintColor = .systemOrange
            titleLabel.text = "Links can't be read"
            messageLabel.text = "RecipeBox can't open Instagram or other links. Share a screenshot of the recipe instead, or copy the recipe text and use “Paste Recipe Text” in RecipeBox."
        case .nothing:
            iconView.image = UIImage(systemName: "questionmark.circle")
            iconView.tintColor = .secondaryLabel
            titleLabel.text = "Nothing to import"
            messageLabel.text = "RecipeBox accepts images (screenshots or photos) and text."
        case .setupProblem:
            iconView.image = UIImage(systemName: "exclamationmark.triangle.fill")
            iconView.tintColor = .systemRed
            titleLabel.text = "Setup incomplete"
            messageLabel.text = "The App Group isn't set up for both RecipeBox and its Share Extension, or the ID in SharedInbox.swift doesn't match."
        case .failed:
            iconView.image = UIImage(systemName: "xmark.octagon.fill")
            iconView.tintColor = .systemRed
            titleLabel.text = "Couldn't save"
            messageLabel.text = "Something went wrong saving the shared item. Please try again."
        }
        iconView.isHidden = false
        titleLabel.isHidden = false
        messageLabel.isHidden = false
    }

    private func showWorking() {
        iconView.isHidden = true
        titleLabel.isHidden = true
        messageLabel.isHidden = true
        doneButton.isHidden = true
        spinner.startAnimating()
    }

    @objc private func doneTapped() { complete() }

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func buildUI() {
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 48, weight: .regular)

        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        var config = UIButton.Configuration.filled()
        config.title = "Done"
        doneButton.configuration = config
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [spinner, iconView, titleLabel, messageLabel, doneButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -16),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140)
        ])
    }
}
