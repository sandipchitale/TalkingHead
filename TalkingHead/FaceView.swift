import SwiftUI

/// The talking face: a portrait image with an animated mouth and blinking eyelids drawn
/// over it. While the mouth is closed the portrait's own smile shows; as it opens, a
/// mouthless skin patch fades in and the animated mouth is drawn on top.
struct FaceView: View {
    var mouth: MouthShape
    var portrait: Portrait = .man
    /// Disable to render a still frame (no blinking).
    var isAnimated = true
    /// Fixes the eyelids at a given openness (0 closed ... 1 open), e.g. for previews.
    var eyeOpenness: Double?

    var body: some View {
        TimelineView(.animation(paused: !isAnimated)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let eyeOpen = eyeOpenness ?? (isAnimated ? Self.blink(at: t) : 1)
            let mouth = mouth
            let portrait = portrait

            Canvas { context, size in
                let scale = min(size.width / portrait.size.width, size.height / portrait.size.height)
                context.translateBy(x: (size.width - portrait.size.width * scale) / 2,
                                    y: (size.height - portrait.size.height * scale) / 2)
                context.scaleBy(x: scale, y: scale)
                let bounds = CGRect(origin: .zero, size: portrait.size)
                context.clip(to: Path(roundedRect: bounds, cornerRadius: 28 / scale))
                context.draw(portrait.image, in: bounds)
                portrait.drawMouth(in: &context, shape: mouth)
                portrait.drawEyelids(in: &context, openness: eyeOpen)
            }
        }
        .aspectRatio(portrait.size, contentMode: .fit)
        .accessibilityLabel("Animated talking face")
    }

    /// Eye openness (0 closed ... 1 open) at time `t`: one quick blink per ~3.7 s cycle,
    /// at a pseudo-random point in each cycle so it doesn't look mechanical.
    private static func blink(at t: TimeInterval) -> Double {
        let period = 3.7
        let blinkDuration = 0.18
        let cycle = (t / period).rounded(.down)
        let jitter = (sin(cycle * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1).magnitude * 2.5
        let local = t - cycle * period - jitter
        guard local >= 0, local < blinkDuration else { return 1 }
        return abs(local - blinkDuration / 2) / (blinkDuration / 2)
    }
}

/// A portrait image, its voice, and where its features are (in image pixels).
struct Portrait: Identifiable {
    /// Name of the system voice that speaks for this portrait.
    let voiceName: String
    let size: CGSize
    let image: Image
    /// The skin around the mouth with the lips painted out (feathered edges).
    let mouthPatch: Image
    let mouthPatchRect: CGRect
    /// Skin across both eyes (each row blended between the skin at the eye's corners),
    /// revealed under the closing eyelids.
    let eyelids: Image
    let eyelidsRect: CGRect
    let eyes: [CGRect]
    let mouthCenter: CGPoint
    /// Converts `MouthShape` design units to image pixels.
    let mouthScale: Double
    let lip: Color

    var id: String { voiceName }

    init(voiceName: String, imageName: String, size: CGSize, mouthPatchRect: CGRect, eyelidsRect: CGRect,
         eyes: [CGRect], mouthCenter: CGPoint, mouthScale: Double, lip: Color) {
        func load(_ name: String) -> Image { Image(nsImage: NSImage(named: name) ?? NSImage()) }
        self.voiceName = voiceName
        self.size = size
        image = load(imageName)
        mouthPatch = load(imageName + "MouthPatch")
        eyelids = load(imageName + "Eyelids")
        self.mouthPatchRect = mouthPatchRect
        self.eyelidsRect = eyelidsRect
        self.eyes = eyes
        self.mouthCenter = mouthCenter
        self.mouthScale = mouthScale
        self.lip = lip
    }

    static let man = Portrait(
        voiceName: "Daniel", imageName: "Man", size: CGSize(width: 400, height: 580),
        mouthPatchRect: CGRect(x: 144, y: 296, width: 122, height: 54),
        eyelidsRect: CGRect(x: 116, y: 196, width: 176, height: 50),
        eyes: [CGRect(x: 125, y: 205, width: 56, height: 33), CGRect(x: 227, y: 205, width: 55, height: 33)],
        mouthCenter: CGPoint(x: 204, y: 318), mouthScale: 1.3,
        lip: Color(red: 0.70, green: 0.42, blue: 0.38))

    static let woman = Portrait(
        voiceName: "Samantha", imageName: "Woman", size: CGSize(width: 511, height: 744),
        mouthPatchRect: CGRect(x: 202, y: 380, width: 144, height: 58),
        eyelidsRect: CGRect(x: 158, y: 252, width: 230, height: 70),
        eyes: [CGRect(x: 171, y: 264, width: 72, height: 57), CGRect(x: 304, y: 262, width: 71, height: 57)],
        mouthCenter: CGPoint(x: 273, y: 405), mouthScale: 1.5,
        lip: Color(red: 0.76, green: 0.42, blue: 0.44))

    static let all = [man, woman]

    private var mouthInside: Color { Color(red: 0.30, green: 0.10, blue: 0.09) }
    private var tongue: Color { Color(red: 0.86, green: 0.45, blue: 0.44) }
    private var skinShadow: Color { Color(red: 0.55, green: 0.36, blue: 0.28) }
    private var lash: Color { Color(red: 0.23, green: 0.15, blue: 0.11) }

    // MARK: Mouth

    func drawMouth(in context: inout GraphicsContext, shape: MouthShape) {
        // Fade the animated mouth in as it opens, so a closed mouth shows the portrait's smile.
        let fade = min(1, (shape.top + shape.bottom) / 6)
        guard fade > 0.01 else { return }

        context.drawLayer { layer in
            layer.opacity = fade
            layer.draw(mouthPatch, in: mouthPatchRect)

            let center = mouthCenter
            layer.translateBy(x: center.x, y: center.y)
            layer.scaleBy(x: mouthScale, y: mouthScale)
            layer.translateBy(x: -center.x, y: -center.y)

            let w = shape.halfWidth
            // Two cubic curves between the corners; roundness pushes the control points out
            // toward the corners, turning a pointed grin into an oval.
            let reach = w * (0.45 + 0.55 * shape.roundness)
            let left = CGPoint(x: center.x - w, y: center.y)
            let right = CGPoint(x: center.x + w, y: center.y)
            var mouth = Path()
            mouth.move(to: left)
            mouth.addCurve(to: right,
                           control1: CGPoint(x: center.x - reach, y: center.y - shape.top * 1.33),
                           control2: CGPoint(x: center.x + reach, y: center.y - shape.top * 1.33))
            mouth.addCurve(to: left,
                           control1: CGPoint(x: center.x + reach, y: center.y + shape.bottom * 1.33),
                           control2: CGPoint(x: center.x - reach, y: center.y + shape.bottom * 1.33))
            mouth.closeSubpath()

            // Soft shadow under the lower lip.
            layer.drawLayer { shadow in
                shadow.addFilter(.blur(radius: 2.5))
                shadow.fill(Path(ellipseIn: CGRect(x: center.x - w * 0.55, y: center.y + shape.bottom + 3,
                                                   width: w * 1.1, height: 5)),
                            with: .color(skinShadow.opacity(0.5)))
            }

            layer.fill(mouth, with: .color(mouthInside))
            layer.drawLayer { inside in
                inside.clip(to: mouth)
                let opening = shape.top + shape.bottom
                let top = center.y - shape.top
                let bottom = center.y + shape.bottom
                if shape.tongue > 0.01 {
                    let height = shape.bottom * 1.1 * shape.tongue
                    inside.fill(Path(ellipseIn: CGRect(x: center.x - w * 0.55, y: bottom - height,
                                                       width: w * 1.1, height: height * 2)),
                                with: .color(tongue))
                }
                if shape.upperTeeth > 0.01 {
                    inside.fill(Path(CGRect(x: center.x - w, y: top - 2, width: w * 2, height: 2 + opening * shape.upperTeeth)),
                                with: .color(Color(white: 0.96)))
                }
                if shape.lowerTeeth > 0.01 {
                    let height = opening * shape.lowerTeeth
                    inside.fill(Path(CGRect(x: center.x - w, y: bottom - height, width: w * 2, height: height + 2)),
                                with: .color(Color(white: 0.88)))
                }
                // Inner shadow around the edges.
                inside.addFilter(.blur(radius: 2.5))
                inside.stroke(mouth, with: .color(.black.opacity(0.45)), lineWidth: 5)
            }
            layer.stroke(mouth, with: .color(lip), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
        }
    }

    // MARK: Eyelids

    func drawEyelids(in context: inout GraphicsContext, openness: Double) {
        guard openness < 0.98 else { return }
        for r in eyes {
            // The lid edge runs corner to corner: its middle travels from the top of the eye
            // (open) to a gentle downward curve a little below centre (closed).
            let closedY = r.midY + r.height * 0.22
            let edgeY = closedY + (r.minY - closedY) * openness
            let control = CGPoint(x: r.midX, y: 2 * edgeY - r.midY)
            var lid = Path()
            lid.move(to: CGPoint(x: r.minX - 2, y: r.minY - 6))
            lid.addLine(to: CGPoint(x: r.minX - 2, y: r.midY))
            lid.addQuadCurve(to: CGPoint(x: r.maxX + 2, y: r.midY), control: control)
            lid.addLine(to: CGPoint(x: r.maxX + 2, y: r.minY - 6))
            lid.closeSubpath()

            let eyeball = Path(ellipseIn: r.insetBy(dx: -2, dy: -2))
            context.drawLayer { layer in
                layer.clip(to: eyeball)
                layer.clip(to: lid)
                layer.draw(eyelids, in: eyelidsRect)
            }
            // As the lid finishes closing, cover the rest of the eye (below the lash line) too.
            let seal = min(1, max(0, (0.3 - openness) / 0.3))
            if seal > 0 {
                context.drawLayer { layer in
                    layer.opacity = seal
                    layer.clip(to: eyeball)
                    layer.draw(eyelids, in: eyelidsRect)
                }
            }
            context.drawLayer { layer in
                layer.clip(to: eyeball)
                layer.clip(to: lid)
                // A little shading toward the lash line gives the lid some roundness.
                layer.fill(lid, with: .linearGradient(Gradient(colors: [.clear, .black.opacity(0.07)]),
                                                      startPoint: CGPoint(x: r.midX, y: r.minY),
                                                      endPoint: CGPoint(x: r.midX, y: max(r.minY + 1, edgeY))))
            }
            var lashLine = Path()
            lashLine.move(to: CGPoint(x: r.minX + 1, y: r.midY))
            lashLine.addQuadCurve(to: CGPoint(x: r.maxX - 1, y: r.midY), control: control)
            context.drawLayer { layer in
                layer.clip(to: eyeball)
                layer.stroke(lashLine, with: .color(lash), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
    }
}

#Preview("Mouth shapes") {
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(160)), count: 4)) {
        ForEach(Viseme.allCases, id: \.self) { viseme in
            VStack {
                FaceView(mouth: viseme.shape, isAnimated: false)
                    .frame(width: 150, height: 220)
                Text(viseme.rawValue).font(.caption)
            }
        }
    }
    .padding()
}

#Preview("Blink") {
    HStack {
        ForEach([1.0, 0.5, 0.0], id: \.self) { openness in
            FaceView(mouth: .rest, isAnimated: false, eyeOpenness: openness)
                .frame(width: 200, height: 290)
        }
    }
    .padding()
}
