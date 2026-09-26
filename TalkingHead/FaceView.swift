import SwiftUI

/// The talking face: a portrait image with an animated mouth, blinking eyelids and moving
/// eyebrows drawn over it. While the mouth is closed the portrait's own smile shows; as it
/// opens, a mouthless skin patch fades in and the animated mouth is drawn on top.
struct FaceView: View {
    var mouth: MouthShape
    var portrait: Portrait = .man
    /// How far the eyebrows are raised (1, or higher for "?" and "!") or lowered (negative) by
    /// stressed words; 0 at rest.
    var brows = 0.0
    /// The mood being shown (see `Mood`).
    var expression = FaceExpression.neutral
    /// Disable to render a still frame (no blinking).
    var isAnimated = true
    /// Fixes the eyelids at a given openness (0 closed ... 1 open), e.g. for previews.
    var eyeOpenness: Double?

    /// Driven by `blink()`; the face is only redrawn while a blink is under way or the
    /// mouth or eyebrows change, not every display frame.
    @State private var blinkOpenness = 1.0

    var body: some View {
        let eyeOpen = eyeOpenness ?? blinkOpenness
        let mouth = mouth
        let portrait = portrait
        let brows = brows
        let expression = expression

        Canvas { context, size in
            let scale = min(size.width / portrait.size.width, size.height / portrait.size.height)
            context.translateBy(x: (size.width - portrait.size.width * scale) / 2,
                                y: (size.height - portrait.size.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            let bounds = CGRect(origin: .zero, size: portrait.size)
            context.clip(to: Path(roundedRect: bounds, cornerRadius: 28 / scale))
            context.draw(portrait.image, in: bounds)
            portrait.drawBrows(in: &context, lift: expression.brows + brows, tilt: expression.tilt)
            portrait.drawMouth(in: &context, shape: mouth, frown: expression.frown)
            portrait.drawEyelids(in: &context, openness: eyeOpen)
        }
        .aspectRatio(portrait.size, contentMode: .fit)
        .accessibilityLabel("Animated talking face")
        .task(id: isAnimated) {
            if isAnimated { await blink() }
        }
    }

    /// Blinks every 2.5–5.5 s (randomised so it doesn't look mechanical): the lids close and
    /// open over about 180 ms, in 18 ms steps.
    private func blink() async {
        let steps = 10
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Double.random(in: 2.5...5.5)))
            for step in 1...steps {
                guard !Task.isCancelled else { return }
                blinkOpenness = abs(Double(step) - Double(steps) / 2) / (Double(steps) / 2)
                try? await Task.sleep(for: .milliseconds(18))
            }
        }
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
    let brows: [BrowRegion]
    /// How many pixels the brows rise at a lift of 1.
    let browLift: Double
    let mouthCenter: CGPoint
    /// Converts `MouthShape` design units to image pixels.
    let mouthScale: Double
    let lip: Color

    var id: String { voiceName }

    init(voiceName: String, imageName: String, size: CGSize, mouthPatchRect: CGRect, eyelidsRect: CGRect,
         eyes: [CGRect], brows: [BrowRegion], browLift: Double, mouthCenter: CGPoint, mouthScale: Double,
         lip: Color) {
        func load(_ name: String) -> Image { Image(nsImage: NSImage(named: name) ?? NSImage()) }
        self.voiceName = voiceName
        self.size = size
        image = load(imageName)
        mouthPatch = load(imageName + "MouthPatch")
        eyelids = load(imageName + "Eyelids")
        self.mouthPatchRect = mouthPatchRect
        self.eyelidsRect = eyelidsRect
        self.eyes = eyes
        self.brows = brows
        self.browLift = browLift
        self.mouthCenter = mouthCenter
        self.mouthScale = mouthScale
        self.lip = lip
    }

    static let man = Portrait(
        voiceName: "Daniel", imageName: "Man", size: CGSize(width: 360, height: 360),
        mouthPatchRect: CGRect(x: 146, y: 174, width: 68, height: 24),
        eyelidsRect: CGRect(x: 126, y: 110, width: 114, height: 36),
        eyes: [CGRect(x: 136, y: 120, width: 30, height: 20), CGRect(x: 195, y: 120, width: 32, height: 20)],
        brows: [BrowRegion(minX: 120, maxX: 172, top: 86, line: 108, bottom: 119),
                 BrowRegion(minX: 185, maxX: 238, top: 86, line: 108, bottom: 119)],
        browLift: 3,
        mouthCenter: CGPoint(x: 180, y: 184), mouthScale: 0.78,
        lip: Color(red: 0.72, green: 0.45, blue: 0.40))

    static let woman = Portrait(
        voiceName: "Samantha", imageName: "Woman", size: CGSize(width: 360, height: 360),
        mouthPatchRect: CGRect(x: 151, y: 146, width: 62, height: 26),
        eyelidsRect: CGRect(x: 114, y: 86, width: 132, height: 44),
        eyes: [CGRect(x: 125, y: 95, width: 41, height: 27), CGRect(x: 197, y: 95, width: 38, height: 27)],
        brows: [BrowRegion(minX: 118, maxX: 172, top: 66, line: 86, bottom: 94),
                 BrowRegion(minX: 188, maxX: 232, top: 66, line: 85, bottom: 94)],
        browLift: 2.5,
        mouthCenter: CGPoint(x: 182, y: 157), mouthScale: 0.7,
        lip: Color(red: 0.82, green: 0.50, blue: 0.50))

    static let all = [man, woman]

    private var mouthInside: Color { Color(red: 0.30, green: 0.10, blue: 0.09) }
    private var tongue: Color { Color(red: 0.86, green: 0.45, blue: 0.44) }
    private var skinShadow: Color { Color(red: 0.55, green: 0.36, blue: 0.28) }
    private var lash: Color { Color(red: 0.23, green: 0.15, blue: 0.11) }

    // MARK: Eyebrows

    /// Moves the eyebrows by redrawing the image over each brow region in narrow columns,
    /// each stretched vertically so the brow line moves up by `lift` × `browLift` pixels (down
    /// when `lift` is negative, and less toward the ends of the brow), while the forehead above
    /// and the eye below stay put. `tilt` also raises (or, negative, lowers) the inner ends by
    /// up to `tilt` × `browLift` pixels.
    func drawBrows(in context: inout GraphicsContext, lift: Double, tilt: Double = 0) {
        guard abs(lift) > 0.01 || abs(tilt) > 0.01 else { return }
        let lift = min(1.6, max(-1, lift))
        let column = 2.0
        for brow in brows {
            var x = brow.minX
            while x < brow.maxX {
                let middle = x + column / 2
                let rise = browLift * (lift * brow.weight(atX: middle)
                    + tilt * brow.tiltWeight(atX: middle, centerX: mouthCenter.x))
                if abs(rise) > 0.05 {
                    let raised = brow.line - rise
                    // Forehead: top ... line squeezed into (or stretched over) top ... raised.
                    drawSlice(in: &context, x: x, width: column, from: brow.top, brow.line,
                              to: brow.top, raised)
                    // Under the brow: line ... bottom stretched over (or squeezed into) raised ... bottom.
                    drawSlice(in: &context, x: x, width: column, from: brow.line, brow.bottom,
                              to: raised, brow.bottom)
                }
                x += column
            }
        }
    }

    /// Draws the image's rows `sourceTop ..< sourceBottom` over `top ..< bottom`, within one
    /// column.
    private func drawSlice(in context: inout GraphicsContext, x: Double, width: Double,
                           from sourceTop: Double, _ sourceBottom: Double, to top: Double, _ bottom: Double) {
        let stretch = (bottom - top) / (sourceBottom - sourceTop)
        context.drawLayer { layer in
            // A hair of overlap with the neighbouring columns and slices keeps seams from showing
            // (a half-covered pixel would let the unmoved image show through).
            layer.clip(to: Path(CGRect(x: x - 0.25, y: top - 0.5, width: width + 0.5, height: bottom - top + 1)))
            layer.draw(image, in: CGRect(x: 0, y: top - sourceTop * stretch,
                                         width: size.width, height: size.height * stretch))
        }
    }

    // MARK: Mouth

    /// Draws the mouth. `frown` (0 ... 1) turns the corners down and, since the portrait's own
    /// mouth smiles, covers it even when the mouth is closed.
    func drawMouth(in context: inout GraphicsContext, shape: MouthShape, frown: Double = 0) {
        // Fade the animated mouth in as it opens, so a closed mouth shows the portrait's smile.
        let fade = min(1, max((shape.top + shape.bottom) / 6, frown * 4))
        guard fade > 0.01 else { return }
        let droop = 5 * frown

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
            let left = CGPoint(x: center.x - w, y: center.y + droop)
            let right = CGPoint(x: center.x + w, y: center.y + droop)
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
            // A closed mouth is only a line: lips pressed together, with a dark crease between.
            let closed = max(0, 1 - (shape.top + shape.bottom) / 3)
            if closed > 0.01 {
                // Upper and lower lips as one lens along the mouth line, fuller below.
                var lips = Path()
                lips.move(to: left)
                lips.addCurve(to: right,
                              control1: CGPoint(x: center.x - reach, y: center.y - shape.top * 1.33 - 8),
                              control2: CGPoint(x: center.x + reach, y: center.y - shape.top * 1.33 - 8))
                lips.addCurve(to: left,
                              control1: CGPoint(x: center.x + reach, y: center.y + shape.bottom * 1.33 + 11),
                              control2: CGPoint(x: center.x - reach, y: center.y + shape.bottom * 1.33 + 11))
                lips.closeSubpath()
                layer.drawLayer { soft in
                    soft.addFilter(.blur(radius: 0.7))
                    soft.fill(lips, with: .color(lip.opacity(closed)))
                }
                layer.stroke(mouth, with: .color(mouthInside.opacity(0.6 * closed)),
                             style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
            }
            layer.stroke(mouth, with: .color(lip.opacity(1 - closed)), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
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

#Preview("Eyebrows") {
    HStack {
        ForEach(Portrait.all) { portrait in
            ForEach([-0.5, 0.0, 1.0, Emphasis.exclaimedLift], id: \.self) { lift in
                FaceView(mouth: .rest, portrait: portrait, brows: lift, isAnimated: false)
                    .frame(width: 200, height: 200)
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
