import SwiftUI

/// Shown right after the photo(s) are chosen, before anything is sent for
/// OCR. Lets the person draw one or more rectangles over parts of the page
/// that should be skipped entirely — a different recipe's text bleeding in
/// from the same page, or an app's buttons and overlays in a screenshot.
///
/// Boxes are stored as fractions of the image (0...1, top-left origin), so
/// they stay put if the screen rotates and are independent of how large the
/// image is drawn. `OCRTextExtractor` drops any recognized line whose center
/// falls inside one, and the AI vision path paints them white.
///
/// A tall image (several stitched screenshots) is shown at full width inside
/// a scroll view, with a Scroll / Draw switch because a drag can't both
/// scroll and draw.
struct MaskEditorView: View {
    let source: StitchedImage
    /// Bound to the caller's "is this being parsed right now" state, so this
    /// view can show its own spinner and disable editing while the OCR/AI
    /// call the Continue button kicked off is in flight.
    @Binding var isParsing: Bool
    /// Called once, with the chosen exclusion rects (possibly empty), when
    /// the person taps Continue.
    let onContinue: ([CGRect]) -> Void

    /// Completed boxes, as fractions of the image.
    @State private var boxes: [CGRect] = []
    /// The box being dragged right now, in on-screen points.
    @State private var currentDrag: CGRect?
    @State private var drawMode = false

    private var image: UIImage { source.composite }

    private var isTall: Bool {
        image.size.width > 0 && image.size.height / image.size.width > 2.6
    }

    /// A normal-shaped photo is always drawable; a tall one only in Draw mode.
    private var canDraw: Bool { !isTall || drawMode }

    var body: some View {
        VStack(spacing: 8) {
            Text(hint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if source.sourceCount > 1 {
                Text(stitchNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isTall {
                Picker("Mode", selection: $drawMode) {
                    Text("Scroll").tag(false)
                    Text("Draw boxes").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
            }

            imageArea
                .overlay {
                    if isParsing {
                        ZStack {
                            Color.black.opacity(0.35)
                            ProgressView("Reading recipe…")
                                .tint(.white)
                                .foregroundStyle(.white)
                        }
                    }
                }

            HStack {
                Button(role: .destructive) {
                    boxes.removeAll()
                } label: {
                    Label("Clear Boxes", systemImage: "trash")
                }
                .disabled(boxes.isEmpty || isParsing)

                Spacer()

                Button {
                    onContinue(boxes)
                } label: {
                    Label(
                        boxes.isEmpty ? "Continue" : "Continue (\(boxes.count) blocked)",
                        systemImage: "arrow.right.circle.fill"
                    )
                    .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isParsing)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .navigationTitle(isTall ? "Joined Photos" : "Block Out Areas")
        .navigationBarTitleDisplayMode(.inline)
        .helpDrawer(.blockOut)
    }

    private var hint: String {
        if isTall {
            return "Scroll to look over the joined page. To block out something that shouldn't be read — an app's buttons, or another recipe's text — switch to Draw boxes and drag over it. Tap a box to remove it."
        }
        return "Draw a box over anything that shouldn't be read — like a different recipe's text on the same page. Tap a box to remove it."
    }

    private var stitchNote: String {
        let joins = source.overlapsRemoved
        let overlapText = joins == 0
            ? "no overlap removed"
            : "\(joins) overlap\(joins == 1 ? "" : "s") removed"
        return "\(source.sourceCount) photos joined, \(overlapText)"
    }

    @ViewBuilder
    private var imageArea: some View {
        if isTall {
            GeometryReader { outer in
                let width = max(outer.size.width - 32, 1)
                let height = width * image.size.height / image.size.width
                ScrollView {
                    canvas(size: CGSize(width: width, height: height))
                        .padding(.horizontal, 16)
                }
                .scrollDisabled(drawMode)
            }
        } else {
            // The GeometryReader is constrained to the image's own aspect
            // ratio, so geo.size is exactly the drawn image's size.
            GeometryReader { geo in
                canvas(size: geo.size)
            }
            .aspectRatio(image.size, contentMode: .fit)
            .padding(.horizontal)
        }
    }

    /// The image with its boxes, drawn at `size`, plus the drawing gesture.
    private func canvas(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Image(uiImage: image)
                .resizable()
                .frame(width: size.width, height: size.height)

            ForEach(boxes.indices, id: \.self) { index in
                maskOverlay(pointsRect(boxes[index], in: size))
                    .onTapGesture {
                        guard !isParsing else { return }
                        boxes.remove(at: index)
                    }
            }

            if let currentDrag {
                maskOverlay(currentDrag)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(
            (!canDraw || isParsing) ? nil : DragGesture(minimumDistance: 4)
                .onChanged { value in
                    let bounds = CGRect(origin: .zero, size: size)
                    let rect = CGRect(
                        x: min(value.startLocation.x, value.location.x),
                        y: min(value.startLocation.y, value.location.y),
                        width: abs(value.location.x - value.startLocation.x),
                        height: abs(value.location.y - value.startLocation.y)
                    )
                    currentDrag = rect.intersection(bounds)
                }
                .onEnded { _ in
                    if let drag = currentDrag, drag.width > 8, drag.height > 8,
                       size.width > 0, size.height > 0 {
                        boxes.append(CGRect(
                            x: drag.minX / size.width,
                            y: drag.minY / size.height,
                            width: drag.width / size.width,
                            height: drag.height / size.height
                        ))
                    }
                    currentDrag = nil
                }
        )
    }

    private func pointsRect(_ fraction: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: fraction.minX * size.width,
            y: fraction.minY * size.height,
            width: fraction.width * size.width,
            height: fraction.height * size.height
        )
    }

    private func maskOverlay(_ rect: CGRect) -> some View {
        Rectangle()
            .fill(Color.red.opacity(0.35))
            .overlay(Rectangle().stroke(Color.red, lineWidth: 2))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }
}
