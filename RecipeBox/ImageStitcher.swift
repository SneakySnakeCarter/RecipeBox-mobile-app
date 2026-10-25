import UIKit

/// One source photo's contribution to a stitched image: which rows of it
/// were kept and where they sit in the combined picture. Positions are
/// fractions (0...1, top-left origin) so nothing depends on pixel scale.
struct StitchSegment {
    /// The source picture. For a stitched set this is an upright copy scaled
    /// to the composite's width; for a single photo it's the original.
    let image: UIImage
    /// Rows of `image` that are kept, as fractions of its height.
    let srcTop: CGFloat
    let srcBottom: CGFloat
    /// Where those kept rows sit in the composite, as fractions of its height.
    let destTop: CGFloat
    let destBottom: CGFloat
    /// True when overlap with the previous photo was found and removed here.
    let joinedWithPrevious: Bool
}

/// The recipe page as the rest of the app sees it: one tall picture
/// (`composite`) for showing and masking, plus the per-photo segments for
/// OCR and AI vision, which work better on the individual photos than on
/// one very tall image.
struct StitchedImage {
    let composite: UIImage
    let segments: [StitchSegment]
    let sourceCount: Int
    let overlapsRemoved: Int

    /// A single photo needs no stitching.
    static func single(_ image: UIImage) -> StitchedImage {
        StitchedImage(
            composite: image,
            segments: [StitchSegment(
                image: image, srcTop: 0, srcBottom: 1, destTop: 0, destBottom: 1,
                joinedWithPrevious: false
            )],
            sourceCount: 1,
            overlapsRemoved: 0
        )
    }
}

/// Stacks several photos top-to-bottom into one tall image.
///
/// Optionally removes overlap between consecutive photos. This is aimed at
/// screenshots of a scrolling page (e.g. a long Instagram caption): two
/// consecutive screenshots share some identical rows, plus fixed header and
/// footer bars that repeat in every one. For each pair, a strip from near
/// the top of the second photo (below its header) is searched for in the
/// first; where it matches, the run of identical rows is measured, and the
/// first photo's tail and the second photo's top (header plus the repeated
/// rows) are cut so the shared content appears once.
///
/// It is deliberately strict — screenshots match pixel-for-pixel, hand-held
/// camera photos don't — and falls back to plain stacking whenever it isn't
/// confident, so the worst case is some repeated content (which the OCR
/// step also de-duplicates), never lost content. The algorithm was
/// prototyped and tested in Python on synthetic scrolling screenshots
/// (headers, footers, gaps, duplicates, noise) before being ported here.
enum ImageStitcher {
    /// Pixel width everything is scaled to. Capped to keep the combined
    /// image's memory use reasonable with many photos.
    static let maxWidth: CGFloat = 1100

    /// Runs synchronously and can take a moment — call off the main thread.
    static func stitch(_ images: [UIImage], removeOverlap: Bool) -> StitchedImage? {
        guard !images.isEmpty else { return nil }
        if images.count == 1 { return .single(images[0]) }

        let widest = images.map { $0.size.width * $0.scale }.max() ?? maxWidth
        let width = min(maxWidth, widest).rounded()
        guard width >= 1 else { return nil }

        // 1. Upright copies, all the same pixel width.
        let scaled = images.compactMap { render($0, width: width) }
        guard scaled.count == images.count else { return nil }

        // 2. Work out which rows of each photo to keep.
        let count = scaled.count
        var keepTop = [Int](repeating: 0, count: count)
        var keepBottom = scaled.map { Int($0.size.height.rounded()) }
        var joined = [Bool](repeating: false, count: count)
        var joins = 0

        if removeOverlap {
            let grays = scaled.compactMap { gray($0) }
            if grays.count == count {
                let signatures = grays.map { rowSignatures($0) }
                for i in 1..<count {
                    if let overlap = findOverlap(
                        grays[i - 1], grays[i], sigA: signatures[i - 1], sigB: signatures[i]
                    ) {
                        keepBottom[i - 1] = min(keepBottom[i - 1], overlap.aKeepBottom)
                        keepTop[i] = overlap.bCropTop
                        joined[i] = true
                        joins += 1
                    }
                }
            }
        }

        // 3. Lay the kept rows out and draw the composite.
        let keptHeights = (0..<count).map { max(keepBottom[$0] - keepTop[$0], 0) }
        let totalHeight = keptHeights.reduce(0, +)
        guard totalHeight > 0 else { return nil }
        let total = CGFloat(totalHeight)

        var segments: [StitchSegment] = []
        var placements: [(image: UIImage, drawY: CGFloat, clip: CGRect)] = []
        var cursor: CGFloat = 0
        for i in 0..<count where keptHeights[i] > 0 {
            let image = scaled[i]
            let height = image.size.height
            let kept = CGFloat(keptHeights[i])
            segments.append(StitchSegment(
                image: image,
                srcTop: CGFloat(keepTop[i]) / height,
                srcBottom: CGFloat(keepBottom[i]) / height,
                destTop: cursor / total,
                destBottom: (cursor + kept) / total,
                joinedWithPrevious: joined[i]
            ))
            placements.append((
                image,
                cursor - CGFloat(keepTop[i]),
                CGRect(x: 0, y: cursor, width: width, height: kept)
            ))
            cursor += kept
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: total), format: format)
        let composite = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: total))
            for placement in placements {
                context.cgContext.saveGState()
                context.cgContext.clip(to: placement.clip)
                placement.image.draw(in: CGRect(
                    x: 0, y: placement.drawY, width: width, height: placement.image.size.height
                ))
                context.cgContext.restoreGState()
            }
        }

        return StitchedImage(
            composite: composite, segments: segments, sourceCount: count, overlapsRemoved: joins
        )
    }

    // MARK: - Rendering

    private static func render(_ image: UIImage, width: CGFloat) -> UIImage? {
        let size = image.size // orientation-aware
        guard size.width > 0, size.height > 0 else { return nil }
        let height = (size.height * width / size.width).rounded()
        guard height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    // MARK: - Overlap detection

    private struct Gray {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    private static let columnStep = 3
    private static let rowTolerance: Float = 2.5
    /// Where in the second photo (as a fraction of its height) to try
    /// taking the search strip from, nearest the top first — below the
    /// header, since a header repeats in every screenshot and proves nothing.
    private static let candidateFractions: [CGFloat] = [0.10, 0.14, 0.18, 0.22, 0.28, 0.35, 0.45]

    private static func gray(_ image: UIImage) -> Gray? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? Gray(width: w, height: h, pixels: pixels) : nil
    }

    /// Mean brightness of each row (sampling every few columns): a cheap
    /// 1-D fingerprint to scan with before doing any pixel-level compare.
    private static func rowSignatures(_ g: Gray) -> [Float] {
        var signatures = [Float](repeating: 0, count: g.height)
        g.pixels.withUnsafeBufferPointer { p in
            for y in 0..<g.height {
                let base = y * g.width
                var sum = 0, count = 0, x = 0
                while x < g.width {
                    sum += Int(p[base + x])
                    count += 1
                    x += columnStep
                }
                signatures[y] = Float(sum) / Float(max(count, 1))
            }
        }
        return signatures
    }

    /// How many consecutive rows, starting at `a[aRow]` / `b[bRow]`, are
    /// (near-)identical. Stops at four bad rows in a row, which tolerates a
    /// blinking cursor or an anti-aliasing blip but not a different image.
    private static func matchingRun(_ a: Gray, _ b: Gray, aRow: Int, bRow: Int) -> Int {
        let n = min(a.height - aRow, b.height - bRow)
        guard n > 0 else { return 0 }
        let w = min(a.width, b.width)
        var lastGood = 0
        var consecutiveBad = 0
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                for i in 0..<n {
                    let baseA = (aRow + i) * a.width
                    let baseB = (bRow + i) * b.width
                    var sum = 0, count = 0, x = 0
                    while x < w {
                        sum += abs(Int(pa[baseA + x]) - Int(pb[baseB + x]))
                        count += 1
                        x += columnStep
                    }
                    let mean = Float(sum) / Float(max(count, 1))
                    if mean > rowTolerance {
                        consecutiveBad += 1
                        if consecutiveBad >= 4 { break }
                    } else {
                        consecutiveBad = 0
                        lastGood = i + 1
                    }
                }
            }
        }
        return lastGood
    }

    /// Returns where to cut: keep `a`'s rows above `aKeepBottom` and `b`'s
    /// rows from `bCropTop` down, or nil when there's no confident overlap.
    private static func findOverlap(
        _ a: Gray, _ b: Gray, sigA: [Float], sigB: [Float]
    ) -> (aKeepBottom: Int, bCropTop: Int)? {
        guard a.width == b.width else { return nil }
        let hA = a.height, hB = b.height
        let minRun = max(48, Int(0.04 * Double(hB)))
        let stripHeight = max(24, Int(0.04 * Double(hB)))

        for fraction in candidateFractions {
            let t0 = Int(fraction * CGFloat(hB))
            guard t0 + stripHeight <= hB, hA - stripHeight >= t0 else { continue }

            let strip = Array(sigB[t0..<(t0 + stripHeight)])
            // A strip that's all one colour (blank paper) matches anywhere.
            var changes = 0
            for i in 1..<strip.count where abs(strip[i] - strip[i - 1]) > 1.0 { changes += 1 }
            guard changes >= 6 else { continue }

            let limit = rowTolerance * Float(stripHeight)
            var best: (y: Int, run: Int)?
            var y = t0 // the strip can only match at or below its own position
            while y <= hA - stripHeight {
                var sum: Float = 0
                var i = 0
                while i < stripHeight {
                    sum += abs(sigA[y + i] - strip[i])
                    if sum > limit { break }
                    i += 1
                }
                if sum <= limit {
                    let run = matchingRun(a, b, aRow: y, bRow: t0)
                    var accept = run >= minRun
                    if accept, abs(y - t0) <= 2 {
                        // Same position in both photos: a repeated header, or
                        // an exact duplicate. Only the duplicate is a real
                        // overlap, and then everything below matches too.
                        let remaining = min(hA - y, hB - t0)
                        accept = Double(remaining) >= 0.5 * Double(hB) && run >= remaining - 4
                    }
                    if accept, run > (best?.run ?? 0) { best = (y, run) }
                }
                y += 1
            }
            if let best {
                return (best.y + best.run, t0 + best.run)
            }
        }
        return nil
    }
}
