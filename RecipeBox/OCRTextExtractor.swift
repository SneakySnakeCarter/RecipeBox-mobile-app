import Vision
import UIKit

/// Runs Apple's Vision OCR on a photo and returns the recognized lines,
/// reordered into a sensible reading order with wrapped lines already
/// rejoined into their full ingredient/step (see mergeWrappedLines).
///
/// Vision's VNRecognizeTextRequest does not do column-aware layout
/// analysis. For a two-column recipe card (a common print layout — one
/// ingredient list on the left, another list plus the steps on the
/// right) its observations, taken in raw or purely vertical order,
/// interleave left- and right-column lines by height instead of reading
/// one column fully before the other. That scrambled order is what gets
/// sent to the AI, and a cheap model can struggle enough with it to give
/// up on a section entirely rather than untangle it.
///
/// This applies a simple heuristic: if there's a clear vertical gap
/// between two horizontal clusters of text roughly in the middle of the
/// image, treat it as two columns and emit the left column fully (top to
/// bottom), then the right column fully. Otherwise, a normal single
/// top-to-bottom pass. This is a heuristic, not real layout analysis —
/// it won't handle three+ columns or a column split that shifts partway
/// down the page — but it fixes the common two-column recipe-card case.
///
/// Before any of that, `excludedRegions` (drawn by the person in
/// MaskEditorView, e.g. to black out a different recipe's text bleeding in
/// from the same page) removes matching OCR lines entirely — see
/// `extractLines` below.
enum OCRTextExtractor {
    /// Reads the text in a (possibly stitched) recipe page.
    ///
    /// Each source photo is recognized on its own — far more accurate than
    /// running OCR over one very tall stitched image — and its lines are then
    /// mapped into the composite's coordinate space, so everything after
    /// this (column splitting, wrap merging) sees one page.
    ///
    /// - Parameter excludedRegions: rects the person drew over the page to
    ///   mark "don't read this" (see MaskEditorView), in composite-fraction
    ///   coordinates (0...1, **top-left** origin). Any recognized line whose
    ///   center falls inside one is dropped before column splitting or
    ///   wrap-merging ever sees it.
    ///
    /// Runs synchronously on a background queue; `completion` is called from
    /// that queue.
    static func extractLines(
        from source: StitchedImage,
        excludedRegions: [CGRect] = [],
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var perSegment: [[PositionedLine]] = []
                for segment in source.segments {
                    perSegment.append(try recognize(segment, excludedRegions: excludedRegions))
                }

                // Where two photos weren't pixel-joined (e.g. hand-held camera
                // photos), their overlap can still show up as the same lines
                // at the end of one and the start of the next.
                var all: [PositionedLine] = []
                var previous: [PositionedLine] = []
                for (index, lines) in perSegment.enumerated() {
                    var current = sortedTopToBottom(lines)
                    if index > 0, !source.segments[index].joinedWithPrevious {
                        current = removeSeamDuplicates(previous: previous, current: current)
                    }
                    all.append(contentsOf: current)
                    previous = current
                }

                completion(.success(orderedLines(from: all)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// OCRs one segment's source image and returns its lines in composite
    /// space, keeping only the rows the stitcher kept and dropping masked ones.
    private static func recognize(
        _ segment: StitchSegment, excludedRegions: [CGRect]
    ) throws -> [PositionedLine] {
        let image = segment.image
        guard let cgImage = image.cgImage else { throw RecipeParserError.invalidImage }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        // A UIImage's pixel data (cgImage) is stored in the camera sensor's
        // orientation; `imageOrientation` says how to rotate it to appear
        // upright. Without telling Vision, a camera photo is OCR'd sideways,
        // which hurts recognition, and the bounding boxes come back in the
        // sideways frame — so the mask rects (drawn on the upright image)
        // wouldn't line up either. Passing the orientation makes Vision
        // read, and report boxes in, the upright frame.
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: CGImagePropertyOrientation(image.imageOrientation),
            options: [:]
        )
        try handler.perform([request])
        guard let observations = request.results as? [VNRecognizedTextObservation] else { return [] }

        let srcSpan = segment.srcBottom - segment.srcTop
        let destSpan = segment.destBottom - segment.destTop
        guard srcSpan > 0, destSpan > 0 else { return [] }

        // Source-image fraction (top-left origin) -> composite fraction.
        func toComposite(_ sourceY: CGFloat) -> CGFloat {
            segment.destTop + (sourceY - segment.srcTop) * destSpan / srcSpan
        }

        return observations.compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            // boundingBox is normalized 0...1 with origin at the bottom-left.
            let box = observation.boundingBox
            let centerY = 1 - box.midY
            guard centerY >= segment.srcTop, centerY < segment.srcBottom else { return nil }

            let compositeCenter = toComposite(centerY)
            let compositeTop = toComposite(1 - box.maxY)
            let center = CGPoint(x: box.midX, y: compositeCenter)
            if excludedRegions.contains(where: { $0.contains(center) }) { return nil }

            // yTop stays in bottom-left-origin terms, as before: larger = higher.
            return PositionedLine(text: text, xLeft: box.minX, xMid: box.midX, yTop: 1 - compositeTop)
        }
    }

    /// Drops the first lines of `current` that repeat the last lines of
    /// `previous` — the same text seen at the bottom of one photo and the top
    /// of the next. Requires two or more matching lines, or one reasonably
    /// long one, so a coincidental short repeat isn't removed.
    private static func removeSeamDuplicates(
        previous: [PositionedLine], current: [PositionedLine]
    ) -> [PositionedLine] {
        func key(_ line: PositionedLine) -> String {
            line.text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let tail = previous.suffix(15).map(key)
        let head = current.prefix(15).map(key)
        var k = min(tail.count, head.count)
        while k >= 1 {
            if Array(tail.suffix(k)) == Array(head.prefix(k)),
               k >= 2 || (head.first?.count ?? 0) >= 12 {
                return Array(current.dropFirst(k))
            }
            k -= 1
        }
        return current
    }

    private struct PositionedLine {
        let text: String
        let xLeft: CGFloat  // normalized 0...1, left edge of the bounding box
        let xMid: CGFloat   // normalized 0...1, midpoint — used only for column splitting
        let yTop: CGFloat   // normalized 0...1, origin bottom-left
    }

    /// Reorders lines top-to-bottom, splitting into two columns first if a
    /// clear central gap is detected, then rejoins wrapped lines within
    /// each column. See the type-level doc comment for the column logic
    /// and mergeWrappedLines for the line-rejoining logic.
    private static func orderedLines(from lines: [PositionedLine]) -> [String] {
        guard lines.count > 4, let split = columnSplitX(for: lines) else {
            return mergeWrappedLines(sortedTopToBottom(lines))
        }

        let leftColumn = sortedTopToBottom(lines.filter { $0.xMid < split })
        let rightColumn = sortedTopToBottom(lines.filter { $0.xMid >= split })

        var result = mergeWrappedLines(leftColumn)
        if !leftColumn.isEmpty && !rightColumn.isEmpty {
            // The transition from one column to the other is always a
            // real boundary — mark it with a blank line.
            result.append("")
        }
        result.append(contentsOf: mergeWrappedLines(rightColumn))
        return result
    }

    private static func sortedTopToBottom(_ lines: [PositionedLine]) -> [PositionedLine] {
        lines.sorted { $0.yTop > $1.yTop }
    }

    /// Rejoins a narrow column's word-wrapped lines back into complete
    /// ingredients/steps.
    ///
    /// The rule, confirmed against a real test photo: a new printed
    /// ingredient starts either with its quantity (a digit or fraction
    /// glyph like ½) OR flush at the same left indentation as the
    /// quantity-led lines — some ingredients print with no quantity at
    /// all (e.g. "Iceberg lettuce cups") but still start at the list's
    /// left margin. A wrapped continuation line, by contrast, is
    /// indented further right (e.g. "Seasoning" wrapping below "1
    /// teaspoon Old Bay" sits indented under the text, not at the
    /// margin). A short all-caps line (a section header, e.g. "TARTAR
    /// SAUCE:") always starts fresh regardless of indentation.
    ///
    /// The quantity-led lines double as this column's own calibration
    /// for "what counts as flush" — a fixed pixel/normalized threshold
    /// can't be assumed across different photos, framing, or crops, so
    /// the left margin is measured from this photo's own bullet lines
    /// each time rather than hard-coded.
    ///
    /// If a column has NO quantity-led lines at all (most likely a
    /// prose instructions paragraph with no printed step numbers, not
    /// an itemized list), there's nothing to calibrate a margin against
    /// — every line is merged into one flowing block instead, since
    /// letting the AI split flowing prose into steps by sentence
    /// boundary works far better than guessing list-item breaks blind.
    private static func mergeWrappedLines(_ lines: [PositionedLine]) -> [String] {
        let anchors = lines.filter { startsWithQuantity($0.text) }

        let isNewItemStart: (PositionedLine) -> Bool
        if anchors.isEmpty {
            isNewItemStart = { _ in false }
        } else {
            let bulletX = median(anchors.map { $0.xLeft })
            let tolerance: CGFloat
            if anchors.count > 1 {
                let maxDeviation = anchors.map { abs($0.xLeft - bulletX) }.max() ?? 0
                // Twice the anchors' own spread absorbs ordinary OCR
                // bounding-box jitter; the 0.01 floor keeps a tolerance
                // that's too tight when all anchors happen to line up
                // near-perfectly.
                tolerance = max(maxDeviation * 2, 0.01)
            } else {
                tolerance = 0.015
            }
            isNewItemStart = { line in
                startsWithQuantity(line.text) || abs(line.xLeft - bulletX) <= tolerance
            }
        }

        var result: [String] = []
        var current: String?
        for line in lines {
            let text = line.text
            if looksLikeHeader(text) {
                if let current { result.append(current) }
                result.append(text)
                current = nil
            } else if current == nil || isNewItemStart(line) {
                if let current { result.append(current) }
                current = text
            } else {
                current = (current ?? "") + " " + text
            }
        }
        if let current { result.append(current) }
        return result
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// A short, mostly-letters, all-caps line — a section header like
    /// "TARTAR SAUCE:" or "FOR CRAB CAKES:" — always starts a fresh item
    /// rather than being merged into whatever came before it.
    private static func looksLikeHeader(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 2, trimmed.count < 40 else { return false }
        let letters = trimmed.filter { $0.isLetter }
        guard !letters.isEmpty else { return false }
        return letters == letters.uppercased()
    }

    /// True when the line's first non-whitespace character is a digit or
    /// a common vulgar-fraction glyph — the signal a new printed
    /// ingredient/step reliably starts with, and this column's anchor
    /// for calibrating the left margin (see mergeWrappedLines).
    private static func startsWithQuantity(_ text: String) -> Bool {
        guard let first = text.trimmingCharacters(in: .whitespaces).first else { return false }
        if first.isNumber { return true }
        let fractionGlyphs: Set<Character> = ["½", "¼", "¾", "⅓", "⅔", "⅛", "⅜", "⅝", "⅞"]
        return fractionGlyphs.contains(first)
    }

    /// Looks for a wide, roughly-central gap between clusters of text
    /// x-midpoints. If found, returns the x-coordinate to split on;
    /// otherwise nil, meaning: treat this as a single column.
    private static func columnSplitX(for lines: [PositionedLine]) -> CGFloat? {
        let sortedX = lines.map { $0.xMid }.sorted()

        var bestGap: CGFloat = 0
        var bestSplit: CGFloat = 0
        for i in 1..<sortedX.count {
            let gap = sortedX[i] - sortedX[i - 1]
            let midpoint = (sortedX[i] + sortedX[i - 1]) / 2
            // Only consider a gap roughly in the middle third of the page —
            // a gap near either edge is just the ragged edge of one column
            // of text, not a boundary between two columns.
            guard midpoint > 0.3, midpoint < 0.7 else { continue }
            if gap > bestGap {
                bestGap = gap
                bestSplit = midpoint
            }
        }

        // Require a meaningfully wide gap (15% of image width) before
        // trusting it as a real column boundary rather than ordinary
        // ragged text spacing.
        return bestGap > 0.15 ? bestSplit : nil
    }
}

private extension CGImagePropertyOrientation {
    /// Standard UIImage.Orientation -> EXIF-style orientation mapping.
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
