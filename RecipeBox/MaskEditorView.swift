import SwiftUI

/// Shown right after a photo is picked, before it's sent for OCR. Lets the
/// person draw one or more rectangles over parts of the photo that should
/// be skipped entirely — most commonly a different recipe's text bleeding
/// in from the same page (a cookbook photo where the previous recipe's
/// last paragraph is still visible above the one being captured).
///
/// The boxes are drawn in this view's own on-screen coordinates, then
/// converted to image-fraction rects (0...1, top-left origin, independent
/// of how large the image is shown on screen) before being handed back via
/// `onContinue` — see `normalizedRects()`. `OCRTextExtractor` converts them
/// again into Vision's own bottom-left-origin normalized space and drops
/// any recognized line whose center falls inside one, before column
/// splitting or wrap-merging ever sees it.
struct MaskEditorView: View {
    let image: UIImage
    /// Bound to the caller's "is this photo being parsed right now" state,
    /// so this view can show its own spinner and disable editing while the
    /// OCR/AI call the Continue button kicked off is in flight.
    @Binding var isParsing: Bool
    /// Called once, with the chosen exclusion rects (possibly empty), when
    /// the person taps Continue.
    let onContinue: ([CGRect]) -> Void

    @State private var boxes: [CGRect] = []
    @State private var currentDrag: CGRect?
    @State private var displaySize: CGSize = .zero

    var body: some View {
        VStack(spacing: 12) {
            Text("Draw a box over anything that shouldn't be read — like a different recipe's text on the same page. Tap a box to remove it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()

                    ForEach(boxes.indices, id: \.self) { index in
                        maskOverlay(boxes[index])
                            .onTapGesture {
                                guard !isParsing else { return }
                                boxes.remove(at: index)
                            }
                    }

                    if let currentDrag {
                        maskOverlay(currentDrag)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    isParsing ? nil : DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            let bounds = CGRect(origin: .zero, size: geo.size)
                            let rect = CGRect(
                                x: min(value.startLocation.x, value.location.x),
                                y: min(value.startLocation.y, value.location.y),
                                width: abs(value.location.x - value.startLocation.x),
                                height: abs(value.location.y - value.startLocation.y)
                            )
                            currentDrag = rect.intersection(bounds)
                        }
                        .onEnded { _ in
                            if let currentDrag, currentDrag.width > 8, currentDrag.height > 8 {
                                boxes.append(currentDrag)
                            }
                            currentDrag = nil
                        }
                )
                .onAppear { displaySize = geo.size }
                .onChange(of: geo.size) { newSize in displaySize = newSize }
            }
            // Constrains the GeometryReader itself to the image's own aspect
            // ratio, so it exactly matches the rendered `.scaledToFit()`
            // image with no letterboxing to account for — geo.size above is
            // already the image's own displayed size.
            .aspectRatio(image.size, contentMode: .fit)
            .padding(.horizontal)
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
                    onContinue(normalizedRects())
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
        .navigationTitle("Block Out Areas")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func maskOverlay(_ rect: CGRect) -> some View {
        Rectangle()
            .fill(Color.red.opacity(0.35))
            .overlay(Rectangle().stroke(Color.red, lineWidth: 2))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    /// Converts the drawn on-screen boxes into image-fraction rects
    /// (0...1, top-left origin) so they stay correct regardless of the
    /// device, screen size, or how large the image was rendered.
    private func normalizedRects() -> [CGRect] {
        guard displaySize.width > 0, displaySize.height > 0 else { return [] }
        return boxes.compactMap { box in
            let normalized = CGRect(
                x: box.minX / displaySize.width,
                y: box.minY / displaySize.height,
                width: box.width / displaySize.width,
                height: box.height / displaySize.height
            )
            return (normalized.width > 0 && normalized.height > 0) ? normalized : nil
        }
    }
}
