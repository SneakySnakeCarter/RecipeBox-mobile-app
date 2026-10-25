import SwiftUI

/// Shown when more than one photo was chosen or taken, before they're
/// stitched: reorder or remove photos, choose whether to cut out overlap,
/// then Stitch joins them top-to-bottom into one tall image.
struct StitchReviewView: View {
    @Binding var images: [UIImage]
    let onStitched: (StitchedImage) -> Void

    @State private var removeOverlap = true
    @State private var isStitching = false
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                        HStack(spacing: 12) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Text("Photo \(index + 1)")
                            Spacer()
                        }
                    }
                    .onMove { images.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { images.remove(atOffsets: $0) }
                } header: {
                    Text("Order, top to bottom")
                } footer: {
                    Text("Drag to reorder, or swipe to remove. Photos are joined in this order.")
                }

                Section {
                    Toggle("Remove overlapping areas", isOn: $removeOverlap)
                } footer: {
                    Text("For screenshots of a scrolling page, cuts the repeated rows (and repeated headers and footers) where one screenshot overlaps the next. Photos taken with the camera usually don't line up exactly, so they're simply stacked — repeated text is dropped when the text is read.")
                }
            }
            .environment(\.editMode, .constant(.active))

            Button {
                stitch()
            } label: {
                Group {
                    if isStitching {
                        HStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text("Stitching…")
                        }
                    } else {
                        Label("Stitch \(images.count) Photo\(images.count == 1 ? "" : "s")", systemImage: "square.stack.3d.down.right")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(images.isEmpty || isStitching)
            .padding()
        }
        .navigationTitle("Join Photos")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn't join the photos", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try removing a photo or choosing them again.")
        }
    }

    private func stitch() {
        isStitching = true
        let photos = images
        let overlap = removeOverlap
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ImageStitcher.stitch(photos, removeOverlap: overlap)
            DispatchQueue.main.async {
                isStitching = false
                if let result {
                    onStitched(result)
                } else {
                    failed = true
                }
            }
        }
    }
}
