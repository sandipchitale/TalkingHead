import SwiftUI

/// The text being spoken, word by word, with the current word highlighted. It scrolls
/// on its own to keep the highlighted word in view.
struct SpokenTextView: View {
    var text: String
    /// Range, in `text`, of the word being spoken.
    var highlight: NSRange?

    private struct Word: Identifiable {
        let range: NSRange
        let text: String
        var id: Int { range.location }
    }

    private var words: [Word] {
        text.ranges(of: /\S+/).map { range in
            Word(range: NSRange(range, in: text), text: String(text[range]))
        }
    }

    /// The word containing the start of the highlight (the synthesizer's ranges don't
    /// always match whitespace-separated words exactly).
    private var highlightedID: Int? {
        guard let highlight else { return nil }
        return words.last { $0.range.location <= highlight.location }?.id
    }

    var body: some View {
        let highlightedID = highlightedID
        ScrollViewReader { proxy in
            ScrollView {
                FlowLayout(spacing: 0, lineSpacing: 2) {
                    ForEach(words) { word in
                        Text(word.text)
                            .padding(.horizontal, 2)
                            .background(word.id == highlightedID ? Color.yellow.opacity(0.45) : .clear,
                                        in: .rect(cornerRadius: 4))
                            .id(word.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .onChange(of: highlightedID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: text) {
                if let first = words.first {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
        }
    }
}

/// Lays subviews out left to right, wrapping onto new lines like text.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(for: subviews, width: proposal.width ?? .infinity)
        let width = frames.map(\.maxX).max() ?? 0
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(for: subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(for subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}

#Preview {
    SpokenTextView(text: String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 12),
                   highlight: NSRange(location: 300, length: 5))
        .font(.title3)
        .frame(width: 500, height: 80)
        .padding()
}
