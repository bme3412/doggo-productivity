import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

struct DogPetting {
    let point: CGPoint
    let started: Date
    let scratchStarted: Date?
}

struct DogMotion {
    struct Frame {
        let time: TimeInterval
        let mood: Mood
        let elapsed: TimeInterval
        var facingRight = false
    }

    enum PairSide { case single, left, right }

    var alternatePace = false
    var pairSide: PairSide = .single
    var idleSince: Date? = nil
    var walkDelay: TimeInterval = 0
    var reactionDelay: TimeInterval = 0
    var buddyPettingSince: Date? = nil

    func frame(for mood: Mood, changedAt: Date, now: Date, reduceMotion: Bool) -> Frame {
        if reduceMotion { return Frame(time: 1, mood: mood, elapsed: 1.2) }

        let clock = now.timeIntervalSinceReferenceDate
        let time = alternatePace ? clock * 1.11 + 0.83 : clock
        let elapsed = max(0, now.timeIntervalSince(changedAt))

        if mood == .walking, elapsed < walkDelay {
            return Frame(time: time, mood: .alert, elapsed: elapsed)
        }
        if reactionDelay > 0, elapsed < reactionDelay, mood != .nap, mood != .petting {
            return Frame(time: time, mood: .nap, elapsed: elapsed)
        }

        // Notice when the other dog is getting petted and look over with a wag.
        if let buddySince = buddyPettingSince,
           [.nap, .happy, .mopey, .awake].contains(mood) {
            let watched = max(0, now.timeIntervalSince(buddySince))
            if watched >= 1.6 {
                return Frame(time: time, mood: .wag, elapsed: watched - 1.6, facingRight: pairSide == .left)
            } else if watched >= 0.5 {
                return Frame(time: time, mood: .alert, elapsed: watched - 0.5, facingRight: pairSide == .left)
            }
        }

        guard let idleSince, pairSide != .single else {
            return Frame(time: time, mood: mood, elapsed: elapsed)
        }

        // Shared pair choreography so the two dogs actually play off each other.
        let cycle = 44.0
        let idleTime = max(0, now.timeIntervalSince(idleSince))
        let phase = (idleTime + cycle - 6.0).truncatingRemainder(dividingBy: cycle)

        if mood == .happy {
            if pairSide == .left, (0..<5.5).contains(phase) {
                return Frame(time: time, mood: phase < 2.8 ? .wag : .happy, elapsed: phase, facingRight: true)
            }
            if pairSide == .right, (0.7..<5.9).contains(phase) {
                return Frame(time: time, mood: phase < 3.4 ? .wag : .happy, elapsed: phase - 0.7)
            }
            return Frame(time: time, mood: mood, elapsed: elapsed)
        }

        guard mood == .nap else {
            return Frame(time: time, mood: mood, elapsed: elapsed)
        }

        switch pairSide {
        case .left:
            switch phase {
            case 0..<1.3:
                return Frame(time: time, mood: .alert, elapsed: phase, facingRight: true)
            case 1.3..<3.6:
                return Frame(time: time, mood: .wag, elapsed: phase - 1.3, facingRight: true)
            case 3.6..<6.2:
                return Frame(time: time, mood: .happy, elapsed: phase - 3.6, facingRight: true)
            case 22.0..<25.0:
                return Frame(time: time, mood: .stretch, elapsed: phase - 22.0)
            case 25.0..<26.8:
                return Frame(time: time, mood: .awake, elapsed: phase - 25.0, facingRight: true)
            default:
                return Frame(time: time, mood: .nap, elapsed: phase)
            }
        case .right:
            switch phase {
            case 0.9..<2.1:
                return Frame(time: time, mood: .alert, elapsed: phase - 0.9)
            case 2.1..<4.2:
                return Frame(time: time, mood: .wag, elapsed: phase - 2.1)
            case 4.2..<6.6:
                return Frame(time: time, mood: .happy, elapsed: phase - 4.2)
            case 23.1..<26.1:
                return Frame(time: time, mood: .stretch, elapsed: phase - 23.1)
            case 26.1..<27.8:
                return Frame(time: time, mood: .wag, elapsed: phase - 26.1)
            default:
                return Frame(time: time, mood: .nap, elapsed: phase)
            }
        case .single:
            return Frame(time: time, mood: .nap, elapsed: elapsed)
        }
    }
}

/// The animated dog. Drawn every frame with Canvas so each mood can loop smoothly.
/// Coordinates match the prototype: the dog lives in a 150×96 box, with 60pt of room
/// on the left for the fetch ball and 14pt above for the z's.
struct DogView: View {
    var mood: Mood
    var moodChangedAt: Date
    var bandana: Color
    var hasTag = false
    var petting: DogPetting?
    var artwork: DogArtwork = .classic
    var scale: CGFloat = 1
    var motion = DogMotion()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moodStarts: [Mood: Date] = [:]

    struct Slot {
        let offset: CGPoint
        let scale: CGFloat
        let zIndex: Double

        var centerX: CGFloat { offset.x + 135 * scale }
        var visualLeft: CGFloat { offset.x + 74 * scale }
        var visualRight: CGFloat { offset.x + 200 * scale }
    }

    static let canvasSize = CGSize(width: 210, height: 110)
    static let earArea = CGRect(x: 106, y: 15, width: 44, height: 49)

    static func slot(at index: Int, count: Int) -> Slot {
        if count > 1 && index > 0 {
            return Slot(offset: CGPoint(x: 118, y: -6), scale: 0.92, zIndex: 0)
        }
        return Slot(offset: .zero, scale: 1, zIndex: 1)
    }

    static func groupSize(count: Int) -> CGSize {
        guard count > 1 else { return canvasSize }
        let back = slot(at: 1, count: count)
        return CGSize(width: ceil(back.offset.x + canvasSize.width * back.scale) + 4, height: canvasSize.height)
    }

    static func visualMidX(count: Int) -> CGFloat {
        guard count > 1 else { return 137 }
        let front = slot(at: 0, count: count)
        let back = slot(at: 1, count: count)
        return (front.visualLeft + back.visualRight) / 2
    }

    static func splitX(count: Int) -> CGFloat {
        guard count > 1 else { return canvasSize.width }
        return (slot(at: 0, count: count).centerX + slot(at: 1, count: count).centerX) / 2
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let now = timeline.date
            let frame = motion.frame(for: mood, changedAt: moodChangedAt, now: now, reduceMotion: reduceMotion)
            let tilt = petting.map { Double(min(1, max(-1, ($0.point.x - 126) / 24))) * 14 } ?? 0
            let scratching = !reduceMotion && (petting?.scratchStarted.map { now.timeIntervalSince($0) >= 1.3 } ?? false)
            let transition = reduceMotion ? nil : Animation.easeInOut(duration: 0.34)
            DogCanvas(frame: frame, now: now, moodStarts: moodStarts, bandana: bandana, hasTag: hasTag,
                      artwork: artwork, moods: MoodWeights(values: [frame.mood: 1]),
                      petTilt: tilt, scratchStrength: scratching ? 1 : 0)
                .animation(transition, value: frame.mood)
                .animation(transition, value: scratching)
                .onChange(of: frame.mood, initial: true) { _, mood in
                    moodStarts[mood] = now.addingTimeInterval(-frame.elapsed)
                }
        }
        .frame(width: DogView.canvasSize.width * scale, height: DogView.canvasSize.height * scale)
    }
}

// Interpolate the mix so an interrupted transition can start from its current pose.
private struct MoodWeights: VectorArithmetic {
    private(set) var values: [Mood: Double]

    init(values: [Mood: Double]) {
        self.values = values.filter { $0.value != 0 }
    }

    static let zero = Self(values: [:])
    var magnitudeSquared: Double { values.values.reduce(0) { $0 + $1 * $1 } }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(values: lhs.values.merging(rhs.values, uniquingKeysWith: +))
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        Self(values: lhs.values.merging(rhs.values.mapValues { -$0 }, uniquingKeysWith: +))
    }

    mutating func scale(by factor: Double) {
        self = Self(values: values.mapValues { $0 * factor })
    }
}

private struct DogCanvas: View, Animatable {
    let frame: DogMotion.Frame
    let now: Date
    let moodStarts: [Mood: Date]
    let bandana: Color
    let hasTag: Bool
    let artwork: DogArtwork
    var moods: MoodWeights
    var petTilt: Double
    var scratchStrength: Double

    var animatableData: AnimatablePair<MoodWeights, AnimatablePair<Double, Double>> {
        get { AnimatablePair(moods, AnimatablePair(petTilt, scratchStrength)) }
        set {
            moods = newValue.first
            petTilt = newValue.second.first
            scratchStrength = newValue.second.second
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let canvas = DogView.canvasSize
            let scale = min(size.width / canvas.width, size.height / canvas.height)
            ctx.translateBy(x: size.width - canvas.width * scale, y: size.height - canvas.height * scale)
            ctx.scaleBy(x: scale, y: scale)

            let layers = moods.values.filter { $0.value > 0.001 }
            guard layers.count > 1, let first = layers.first else {
                let solo = painter(for: layers.first?.key ?? frame.mood)
                solo.paintBody(bodyContext(ctx), movement: solo.movement)
                solo.paintEffects(ctx)
                return
            }

            let initial = (pose: DogPose(mood: first.key), movement: painter(for: first.key).movement, weight: first.value)
            let shape = layers.dropFirst().reduce(initial) { blend, layer in
                let total = blend.weight + layer.value
                let fraction = layer.value / total
                return (blend.pose.interpolated(to: DogPose(mood: layer.key), fraction: fraction),
                        blend.movement.interpolated(to: painter(for: layer.key).movement, fraction: fraction), total)
            }
            let primary = layers.max { a, b in
                a.value == b.value ? b.key == frame.mood : a.value < b.value
            }?.key ?? frame.mood
            painter(for: primary, pose: shape.pose).paintBody(bodyContext(ctx), movement: shape.movement)
            for (mood, weight) in layers {
                var effect = ctx
                effect.opacity *= weight / shape.weight
                painter(for: mood).paintEffects(effect)
            }
        }
    }

    private func bodyContext(_ ctx: GraphicsContext) -> GraphicsContext {
        guard frame.facingRight else { return ctx }
        var flipped = ctx
        flipped.translateBy(x: 135, y: 0)
        flipped.scaleBy(x: -1, y: 1)
        flipped.translateBy(x: -135, y: 0)
        return flipped
    }

    private func painter(for mood: Mood, pose: DogPose? = nil) -> DogPainter {
        let elapsed = mood == frame.mood ? frame.elapsed : (moodStarts[mood].map { now.timeIntervalSince($0) } ?? 1.2)
        return DogPainter(t: frame.time, since: elapsed, mood: mood, bandana: bandana, hasTag: hasTag,
                          petTilt: petTilt, scratchStrength: scratchStrength, artwork: artwork, pose: pose)
    }
}

// Match the parts of the resting, sitting, and walking drawings as the dog changes pose.
private struct DogPose {
    let head: CGRect
    let torso: CGRect
    let haunch: CGRect
    let paws: CGRect
    let neck: CGRect

    private static let lying = DogPose(
        head: CGRect(x: 26, y: 48, width: 36, height: 36),
        torso: CGRect(x: 44, y: 54, width: 88, height: 36),
        haunch: CGRect(x: 100, y: 79.5, width: 32, height: 13),
        paws: CGRect(x: 14, y: 80, width: 48, height: 13),
        neck: CGRect(x: 50, y: 61, width: 18, height: 15)
    )
    private static let sitting = DogPose(
        head: CGRect(x: 52, y: 12, width: 36, height: 36),
        torso: CGRect(x: 64, y: 35, width: 44, height: 54),
        haunch: CGRect(x: 80, y: 67, width: 44, height: 26),
        paws: CGRect(x: 68, y: 66, width: 30, height: 30),
        neck: CGRect(x: 62, y: 44, width: 30, height: 18)
    )
    private static let trotting = DogPose(
        head: CGRect(x: 38.5, y: 27.5, width: 33, height: 31),
        torso: CGRect(x: 57, y: 43, width: 72, height: 34),
        haunch: CGRect(x: 103, y: 53, width: 24, height: 21),
        paws: CGRect(x: 64, y: 65, width: 62, height: 26),
        neck: CGRect(x: 57, y: 49, width: 21, height: 18)
    )

    init(mood: Mood) {
        switch mood {
        case .nap, .sigh, .drowsy, .mopey, .stretch: self = .lying
        case .walking: self = .trotting
        default: self = .sitting
        }
    }

    private init(head: CGRect, torso: CGRect, haunch: CGRect, paws: CGRect, neck: CGRect) {
        self.head = head
        self.torso = torso
        self.haunch = haunch
        self.paws = paws
        self.neck = neck
    }

    func interpolated(to next: Self, fraction: Double) -> Self {
        func mix(_ a: CGRect, _ b: CGRect) -> CGRect {
            CGRect(x: a.minX + (b.minX - a.minX) * fraction, y: a.minY + (b.minY - a.minY) * fraction,
                   width: a.width + (b.width - a.width) * fraction, height: a.height + (b.height - a.height) * fraction)
        }
        return Self(head: mix(head, next.head), torso: mix(torso, next.torso), haunch: mix(haunch, next.haunch),
                    paws: mix(paws, next.paws), neck: mix(neck, next.neck))
    }
}

private struct DogMovement {
    struct Tail {
        let base: CGPoint
        let tip: CGPoint
        let control: CGPoint
        let angle: Double
    }

    let tail: Tail
    var lean = 0.0
    var bounce = 0.0
    var bow = 0.0
    var headAngle = 0.0
    var headLift = 0.0
    var pawLift = 0.0

    func interpolated(to next: Self, fraction: Double) -> Self {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * fraction }
        func point(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: mix(a.x, b.x), y: mix(a.y, b.y))
        }
        let tail = Tail(base: point(tail.base, next.tail.base), tip: point(tail.tip, next.tail.tip),
                        control: point(tail.control, next.tail.control), angle: mix(tail.angle, next.tail.angle))
        return Self(tail: tail, lean: mix(lean, next.lean), bounce: mix(bounce, next.bounce), bow: mix(bow, next.bow),
                    headAngle: mix(headAngle, next.headAngle), headLift: mix(headLift, next.headLift),
                    pawLift: mix(pawLift, next.pawLift))
    }
}

private struct DogPainter {
    let t: Double
    let since: Double
    let mood: Mood
    let bandana: Color
    let hasTag: Bool
    let petTilt: Double
    let scratchStrength: Double
    let artwork: DogArtwork
    let pose: DogPose?

    // Palette
    var look: DogLook? {
        if case .photo(let look) = artwork { return look }
        return nil
    }
    var isBlack: Bool { artwork == .black }
    var isDarkCoat: Bool {
        guard let rgb = look?.coat else { return isBlack }
        let r = Double((rgb >> 16) & 255) / 255
        let g = Double((rgb >> 8) & 255) / 255
        let b = Double(rgb & 255) / 255
        return 0.213 * r + 0.715 * g + 0.072 * b < 0.36
    }
    var coat: Color { Color(hex: look?.coat ?? (isBlack ? 0x35363E : 0xF1E4D1)) }
    var shadowCoat: Color { Color(hex: look.map { DogLook.shade($0.coat, by: -0.19) } ?? (isBlack ? 0x292B32 : 0xE8D6BD)) }
    var lightCoat: Color { Color(hex: look.map { DogLook.shade($0.coat, by: 0.13) } ?? (isBlack ? 0x50525D : 0xF4E9DA)) }
    var snout: Color { Color(hex: look?.muzzle ?? (isBlack ? 0x575963 : 0xF8F0E5)) }
    var patch: Color { Color(hex: look?.markingsColor ?? (isBlack ? 0x2F3038 : 0xC99A6E)) }
    var ears: Color { Color(hex: look?.earColor ?? (isBlack ? 0x23252C : 0xA9744A)) }
    var rimColor: Color { isDarkCoat ? Color.white.opacity(0.16) : Color(hex: 0x3A2C21, opacity: 0.16) }
    var coatSheen: Color { isDarkCoat ? Color.white.opacity(0.11) : Color.white.opacity(0.32) }
    var muzzleScale: Double { look?.longMuzzle == true ? 1.46 : 1 }
    var ink: Color { Color(hex: isBlack ? 0x15161C : 0x2A2420) }
    var browColor: Color { Color(hex: isBlack ? 0x757583 : 0x8A6040) }
    let blush = Color(hex: 0xF0B4A2, opacity: 0.5)
    let tongue = Color(hex: 0xE88A8A)
    let ballColor = Color(hex: 0xCFDC5F)

    // MARK: Helpers

    func phase(_ period: Double, offset: Double = 0) -> Double {
        let x = (t + offset).truncatingRemainder(dividingBy: period) / period
        return x < 0 ? x + 1 : x
    }

    /// Keyframe interpolation with smoothstep easing, like CSS keyframes.
    func kf(_ p: Double, _ keys: [(Double, Double)]) -> Double {
        guard let first = keys.first else { return 0 }
        if p <= first.0 { return first.1 }
        for i in 1..<keys.count {
            let (a, va) = keys[i - 1]
            let (b, vb) = keys[i]
            if p <= b {
                let u = b == a ? 1 : (p - a) / (b - a)
                let e = u * u * (3 - 2 * u)
                return va + (vb - va) * e
            }
        }
        return keys[keys.count - 1].1
    }

    func wave(_ period: Double, offset: Double = 0) -> Double {
        0.5 - 0.5 * cos(2 * .pi * phase(period, offset: offset))
    }

    func placed(_ context: GraphicsContext, _ part: KeyPath<DogPose, CGRect>) -> GraphicsContext {
        guard let pose else { return context }
        let from = DogPose(mood: mood)[keyPath: part]
        let to = pose[keyPath: part]
        var context = context
        context.translateBy(x: to.minX, y: to.minY)
        context.scaleBy(x: to.width / from.width, y: to.height / from.height)
        context.translateBy(x: -from.minX, y: -from.minY)
        return context
    }

    func with(_ ctx: GraphicsContext, pivot: CGPoint, rotate deg: Double = 0,
              scaleX: Double = 1, scaleY: Double = 1, dx: Double = 0, dy: Double = 0,
              _ draw: (GraphicsContext) -> Void) {
        var l = ctx
        l.translateBy(x: pivot.x + dx, y: pivot.y + dy)
        l.rotate(by: .degrees(deg))
        l.scaleBy(x: scaleX, y: scaleY)
        l.translateBy(x: -pivot.x, y: -pivot.y)
        draw(l)
    }

    func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> Path {
        Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
    }

    func rrect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
    }

    func path(_ build: (inout Path) -> Void) -> Path {
        var p = Path()
        build(&p)
        return p
    }

    func fill(_ c: GraphicsContext, _ p: Path, _ color: Color) {
        c.fill(p, with: .color(color))
    }

    func stroke(_ c: GraphicsContext, _ p: Path, _ color: Color, _ width: Double) {
        c.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    func drawMarkings(_ c: GraphicsContext, on body: Path, patchShape: Path) {
        switch look?.markings {
        case .solid: break
        case .brindle:
            var clipped = c
            clipped.clip(to: body)
            let bounds = body.boundingRect
            for stripe in 0..<7 {
                let x = bounds.minX + bounds.width * (0.13 + Double(stripe) * 0.14)
                let bend = Double(stripe % 3 - 1) * 4
                stroke(clipped, path {
                    $0.move(to: CGPoint(x: x + 6, y: bounds.minY - 2))
                    $0.addCurve(to: CGPoint(x: x - 7, y: bounds.maxY + 2),
                                control1: CGPoint(x: x - 6 + bend, y: bounds.minY + bounds.height * 0.3),
                                control2: CGPoint(x: x + 2, y: bounds.midY + 4))
                }, patch.opacity(stripe.isMultiple(of: 2) ? 0.75 : 0.48), stripe.isMultiple(of: 2) ? 3.8 : 2.2)
            }
        default: fill(c, patchShape, patch)
        }
    }

    func drawEar(_ c: GraphicsContext, x: Double, y: Double, length: Double) {
        let shape: Path
        switch look?.ears {
        case .upright:
            shape = path {
                $0.move(to: CGPoint(x: x - 6, y: y + 8))
                $0.addQuadCurve(to: CGPoint(x: x + 1, y: y - 9), control: CGPoint(x: x - 6, y: y - 4))
                $0.addQuadCurve(to: CGPoint(x: x + 10, y: y + 9), control: CGPoint(x: x + 12, y: y))
                $0.closeSubpath()
            }
        case .short:
            shape = ellipse(x + 4, y + length * 0.3, 7, length * 0.36)
        default:
            shape = path {
                $0.move(to: CGPoint(x: x - 3, y: y))
                $0.addCurve(to: CGPoint(x: x + 7, y: y + length),
                            control1: CGPoint(x: x + 11, y: y - 5), control2: CGPoint(x: x + 14, y: y + length * 0.6))
                $0.addQuadCurve(to: CGPoint(x: x - 3, y: y), control: CGPoint(x: x - 8, y: y + length * 0.95))
                $0.closeSubpath()
            }
        }
        fill(c, shape, ears)
        stroke(c, shape, rimColor, 0.9)
    }

    func drawCoatHighlights(_ c: GraphicsContext, on shape: Path, highlight: Path) {
        var clipped = c
        clipped.clip(to: shape)
        fill(clipped, highlight, coatSheen)
        stroke(c, shape, rimColor, 1.1)
    }

    func drawNose(_ c: GraphicsContext, cx: Double, cy: Double, rx: Double = 4, ry: Double = 3) {
        fill(c, ellipse(cx, cy, rx, ry), ink)
        fill(c, ellipse(cx - rx * 0.26, cy - ry * 0.28, rx * 0.28, ry * 0.22), Color.white.opacity(0.45))
    }

    func drawTail(_ c: GraphicsContext, from base: CGPoint, to tip: CGPoint, control: CGPoint) {
        switch look?.tail {
        case .fluffy:
            fill(c, path {
                $0.move(to: CGPoint(x: base.x - 2, y: base.y - 3))
                $0.addQuadCurve(to: CGPoint(x: tip.x + 4, y: tip.y + 1),
                                control: CGPoint(x: control.x, y: control.y - 7))
                $0.addQuadCurve(to: CGPoint(x: tip.x - 2, y: tip.y + 7),
                                control: CGPoint(x: tip.x, y: tip.y + 4))
                $0.addQuadCurve(to: CGPoint(x: base.x - 2, y: base.y - 3),
                                control: CGPoint(x: control.x - 6, y: control.y + 12))
                $0.closeSubpath()
            }, ears)
        case .short:
            stroke(c, path {
                $0.move(to: base)
                $0.addQuadCurve(to: CGPoint(x: base.x + 8, y: base.y + (tip.y > base.y ? 2 : -6)),
                                control: CGPoint(x: base.x + 6, y: base.y - 2))
            }, ears, 6)
        default:
            stroke(c, path { $0.move(to: base); $0.addQuadCurve(to: tip, control: control) }, ears, 6)
        }
    }

    func drawNeckwear(_ c: GraphicsContext, left: CGPoint, right: CGPoint, tip: CGPoint, tagOffset: Double = 0) {
        if let collar = look?.collar {
            let center = CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2 + 5)
            stroke(c, path { $0.move(to: left); $0.addQuadCurve(to: right, control: center) }, Color(hex: collar), 4.5)
            stroke(c, ellipse(left.x + 4, left.y + 4, 2.5, 2.5), Color(hex: 0xCCBBA4), 1)
        } else {
            let fold = path {
                $0.move(to: left); $0.addLine(to: right); $0.addLine(to: tip); $0.closeSubpath()
            }
            fill(c, fold, bandana)
            stroke(c, path { $0.move(to: left); $0.addLine(to: right) }, Color.black.opacity(0.14), 1.6)
            stroke(c, fold, Color.black.opacity(0.08), 0.7)
        }
        drawTag(c, x: tip.x - 1, y: tip.y + tagOffset)
    }

    // MARK: Paint

    private var napping: Bool { mood == .nap || mood == .drowsy }
    private var playful: Bool { [.excited, .happy, .petting, .wag, .highFive, .celebrate].contains(mood) }
    private var stretch: Double {
        mood == .stretch ? kf(min(1, max(0, since / 3)), [(0, 0), (0.35, 1), (0.7, 0.9), (1, 0)]) : 0
    }

    var movement: DogMovement {
        switch mood {
        case .nap, .sigh, .drowsy, .mopey, .stretch:
            let thump = napping ? kf(phase(5), [(0, 0), (0.7, 0), (0.76, -24), (0.82, 0), (0.88, -16), (1, 0)]) : 0
            let tail = DogMovement.Tail(base: CGPoint(x: 126, y: 74), tip: CGPoint(x: 142, y: 86),
                                        control: CGPoint(x: 142, y: 72), angle: thump)
            if mood == .stretch { return DogMovement(tail: tail, headAngle: -12 * stretch, headLift: -7 * stretch) }
            if mood == .mopey { return DogMovement(tail: tail, headAngle: 7, headLift: 5) }
            if napping { return DogMovement(tail: tail) }
            let breath = phase(2.8)
            return DogMovement(tail: tail, headAngle: kf(breath, [(0, 0), (0.35, -4), (0.55, 0), (1, 0)]),
                               headLift: kf(breath, [(0, 0), (0.35, -5), (0.55, 1), (1, 0)]))
        case .walking:
            let tail = DogMovement.Tail(base: CGPoint(x: 119, y: 59), tip: CGPoint(x: 140, y: 42),
                                        control: CGPoint(x: 139, y: 63), angle: -15 + 31 * wave(0.43))
            return DogMovement(tail: tail, bounce: 4 * wave(0.28))
        default:
            let fetch = mood == .fetch
            let bark = mood == .bark
            let fluffy = look?.tail == .fluffy
            let wag = -14 + (fluffy ? 32 : (playful ? 51 : 32)) * wave(fetch || bark || playful ? 0.26 : 0.9)
            let tail = DogMovement.Tail(base: CGPoint(x: 116, y: 76),
                                        tip: fluffy ? CGPoint(x: 144, y: 83) : CGPoint(x: 130, y: 48),
                                        control: look == nil ? CGPoint(x: 132, y: 68) : CGPoint(x: 134, y: 70),
                                        angle: wag)
            let jumping = mood == .excited || mood == .celebrate
            let bounce = jumping ? 9 * wave(0.51) : (mood == .happy ? 4 * wave(1.1) : 0)
            let lean = mood == .petting ? 1 - pow(1 - min(1, max(0, since / 0.4)), 3) : 0
            let bow = fetch ? kf(phase(3), [(0, 0), (0.55, 0), (0.68, 1), (0.8, 1), (1, 0)]) : 0
            let tilt = kf(phase(2.4), [(0, 0), (0.3, -10), (0.6, 5), (1, 0)]) * (bark ? 0.3 : 1)
            let pop = bark ? -4 * kf(phase(0.9), [(0, 0), (0.1, 1), (0.3, 0), (1, 0)]) : 0
            let pawLift = mood == .highFive ? kf(min(1, max(0, since / 0.35)), [(0, 0), (1, 1)]) : 0
            return DogMovement(tail: tail, lean: lean, bounce: bounce, bow: bow,
                               headAngle: mood == .petting ? petTilt : tilt,
                               headLift: pop + (mood == .alert ? -6 : 0), pawLift: pawLift)
        }
    }

    func paint(_ ctx: GraphicsContext) {
        paintBody(ctx, movement: movement)
        paintEffects(ctx)
    }

    func paintBody(_ ctx: GraphicsContext, movement: DogMovement) {
        var c = ctx
        c.translateBy(x: 60, y: 10)
        drawGroundShadow(c, movement: movement)

        with(c, pivot: CGPoint(x: 80, y: 96), rotate: -8 * movement.lean,
             dx: -7 * movement.lean, dy: -movement.bounce) { leaned in
            with(leaned, pivot: CGPoint(x: 95, y: 92), rotate: -7 * movement.bow, dy: 5 * movement.bow) { body in
                let tail = movement.tail
                with(body, pivot: tail.base, rotate: tail.angle) {
                    drawTail($0, from: tail.base, to: tail.tip, control: tail.control)
                }
                switch mood {
                case .nap, .sigh, .drowsy, .mopey, .stretch: drawLying(body, movement: movement)
                case .walking: drawTrotting(body, movement: movement)
                default: drawSitting(body, movement: movement)
                }
            }
        }
    }

    func drawGroundShadow(_ c: GraphicsContext, movement: DogMovement) {
        let currentPose = pose ?? DogPose(mood: mood)
        let stretchOffset = mood == .stretch ? -5 * stretch : 0
        let stretchExtra = mood == .stretch ? 7 * stretch : 0
        let minX = min(currentPose.paws.minX, currentPose.torso.minX) + stretchOffset
        let maxX = max(currentPose.haunch.maxX, currentPose.torso.maxX)
        let cx = (minX + maxX) / 2 - 5 * movement.lean
        let baseRx = (maxX - minX) / 2 + 4 + stretchExtra
        let lift = min(1, max(0, movement.bounce / 12))
        let scale = 1 - 0.18 * lift
        let alpha = 1 - 0.35 * lift
        let cy = mood == .walking ? 91.5 : 94.0
        fill(c, ellipse(cx, cy, baseRx * scale, 5.2 * scale), Color.black.opacity(0.11 * alpha))
        fill(c, ellipse(cx, cy - 0.5, baseRx * 0.72 * scale, 3.0 * scale), Color.black.opacity(0.16 * alpha))
    }

    func paintEffects(_ ctx: GraphicsContext) {
        var c = ctx
        c.translateBy(x: 60, y: 10)
        switch mood {
        case .nap, .drowsy: drawZs(c)
        case .sigh: drawPuffs(c)
        case .fetch: drawBall(c)
        case .bark: drawWoof(c)
        default: break
        }
    }

    // MARK: Lying (nap, sigh)

    func drawLying(_ c: GraphicsContext, movement: DogMovement) {
        let stretch = self.stretch
        // Body: slow breathing, or the big inhale-and-slump of a sigh
        var sx = 1.0, sy = 1.0
        if mood == .stretch {
            sx = 1 + 0.12 * stretch
            sy = 1 - 0.15 * stretch
        } else if napping || mood == .mopey {
            sy = 1 + 0.05 * wave(3.6)
        } else {
            let p = phase(2.8)
            sy = kf(p, [(0, 1), (0.35, 1.14), (0.55, 0.92), (0.75, 1), (1, 1)])
            sx = kf(p, [(0, 1), (0.35, 1.02), (0.55, 1.01), (0.75, 1), (1, 1)])
        }
        let torso = placed(c, \.torso)
        with(torso, pivot: CGPoint(x: 88, y: 90), scaleX: sx, scaleY: sy) { l in
            let body = ellipse(88, 72, 44, 18)
            fill(l, body, coat)
            drawMarkings(l, on: body, patchShape: path {
                $0.move(to: CGPoint(x: 60, y: 58))
                $0.addQuadCurve(to: CGPoint(x: 122, y: 60), control: CGPoint(x: 90, y: 46))
                $0.addQuadCurve(to: CGPoint(x: 90, y: 64), control: CGPoint(x: 110, y: 66))
                $0.addQuadCurve(to: CGPoint(x: 60, y: 58), control: CGPoint(x: 72, y: 64))
                $0.closeSubpath()
            })
            drawCoatHighlights(l, on: body, highlight: ellipse(84, 58, 32, 6))
        }

        fill(placed(c, \.haunch), ellipse(116, 86, 16, 6.5), shadowCoat)
        let paws = placed(c, \.paws)
        fill(paws, rrect(22 - 12 * stretch, 84, 40 + 8 * stretch, 9, 4.5), shadowCoat)
        fill(paws, rrect(14 - 20 * stretch, 80, 44 + 14 * stretch, 10, 5), lightCoat)
        if look?.chestPatch == true { fill(torso, ellipse(61, 75, 9, 6), Color(hex: 0xDBD0C1)) }
        if let harness = look?.harness {
            stroke(torso, path {
                $0.move(to: CGPoint(x: 59, y: 73))
                $0.addQuadCurve(to: CGPoint(x: 99, y: 69), control: CGPoint(x: 78, y: 78))
            }, Color(hex: harness), 4)
        }
        drawNeckwear(placed(c, \.neck), left: CGPoint(x: 50, y: 64), right: CGPoint(x: 68, y: 61),
                     tip: CGPoint(x: 60, y: 76))

        with(placed(c, \.head), pivot: CGPoint(x: 58, y: 80), rotate: movement.headAngle, dy: movement.headLift) { h in
            let headShape = ellipse(44, 66, 18, 18)
            fill(h, headShape, coat)
            drawCoatHighlights(h, on: headShape, highlight: ellipse(41, 52, 11, 5.5))
            with(h, pivot: CGPoint(x: 36, y: 74), scaleX: muzzleScale) { jaw in
                fill(jaw, ellipse(28, 74, 13, 8.5), snout)
                drawNose(jaw, cx: 17, cy: 71)
                let yawn = mood == .drowsy ? max(0, (wave(6) - 0.78) * 4.5) : stretch
                if yawn > 0.1 {
                    fill(jaw, ellipse(25, 78, 3.5 + 2 * yawn, 6 * yawn), ink)
                    fill(jaw, ellipse(26, 78 + 2 * yawn, 2.1, 2 * yawn), tongue)
                } else {
                    stroke(jaw, path { $0.move(to: CGPoint(x: 21, y: 78)); $0.addQuadCurve(to: CGPoint(x: 31, y: 78), control: CGPoint(x: 26, y: 80.5)) }, ink, 1.5)
                }
            }

            let twitch = napping ? kf(phase(4.2), [(0, 0), (0.86, 0), (0.89, -14), (0.92, 4), (0.95, -8), (1, 0)]) : 0
            with(h, pivot: CGPoint(x: 52, y: 51), rotate: twitch) { e in
                if look != nil { drawEar(e, x: 50, y: 51, length: 28); return }
                let ear = path {
                    $0.move(to: CGPoint(x: 50, y: 50))
                    $0.addQuadCurve(to: CGPoint(x: 60, y: 76), control: CGPoint(x: 64, y: 52))
                    $0.addQuadCurve(to: CGPoint(x: 48, y: 70), control: CGPoint(x: 53, y: 80))
                    $0.addQuadCurve(to: CGPoint(x: 50, y: 50), control: CGPoint(x: 45, y: 58))
                    $0.closeSubpath()
                }
                fill(e, ear, ears)
                stroke(e, ear, rimColor, 0.9)
            }

            if napping || stretch > 0.2 {
                stroke(h, path { $0.move(to: CGPoint(x: 33, y: 64)); $0.addQuadCurve(to: CGPoint(x: 41, y: 64), control: CGPoint(x: 37, y: 67)) }, ink, 2)
            } else {
                let blink = kf(phase(3.8), [(0, 1), (0.92, 1), (0.95, 0.1), (1, 1)])
                with(h, pivot: CGPoint(x: 37, y: 63), scaleY: blink) { e in
                    fill(e, ellipse(37, 63, 3.3, 3.3), ink)
                    fill(e, ellipse(38.2, 61.8, 1.1, 1.1), .white)
                }
                // Sad, upturned brow
                stroke(h, path { $0.move(to: CGPoint(x: 32, y: 55.5)); $0.addLine(to: CGPoint(x: 41.5, y: 57.5)) }, browColor, 2)
            }
            fill(h, ellipse(44, 74, 4, 2.5), blush)
        }
    }

    // MARK: Sitting (awake, fetch, bark)

    func drawSitting(_ b: GraphicsContext, movement: DogMovement) {
        let fetch = mood == .fetch
        let bark = mood == .bark

        fill(placed(b, \.haunch), ellipse(102, 80, 22, 13), shadowCoat)
        let torso = placed(b, \.torso)
        let body = ellipse(86, 62, 22, 27)
        fill(torso, body, coat)
        drawMarkings(torso, on: body, patchShape: path {
            $0.move(to: CGPoint(x: 92, y: 38))
            $0.addQuadCurve(to: CGPoint(x: 110, y: 68), control: CGPoint(x: 110, y: 44))
            $0.addQuadCurve(to: CGPoint(x: 88, y: 55), control: CGPoint(x: 100, y: 58))
            $0.closeSubpath()
        })
        drawCoatHighlights(torso, on: body, highlight: ellipse(76, 54, 9, 17))
        if look?.chestPatch == true {
            fill(torso, path {
                $0.move(to: CGPoint(x: 70, y: 49))
                $0.addQuadCurve(to: CGPoint(x: 79, y: 73), control: CGPoint(x: 65, y: 62))
                $0.addQuadCurve(to: CGPoint(x: 82, y: 49), control: CGPoint(x: 84, y: 58))
                $0.closeSubpath()
            }, Color(hex: 0xDBD0C1))
        }
        if let harness = look?.harness {
            stroke(torso, path {
                $0.move(to: CGPoint(x: 72, y: 63))
                $0.addQuadCurve(to: CGPoint(x: 104, y: 61), control: CGPoint(x: 86, y: 68))
                $0.move(to: CGPoint(x: 86, y: 50))
                $0.addQuadCurve(to: CGPoint(x: 94, y: 67), control: CGPoint(x: 92, y: 54))
            }, Color(hex: harness), 4)
            fill(torso, rrect(91, 61, 5.5, 4, 1), ink.opacity(0.75))
        }
        if mood == .petting && scratchStrength > 0 {
            let kick = wave(0.24) * scratchStrength
            var hip = placed(b, \.haunch)
            hip.opacity *= min(1, scratchStrength)
            with(hip, pivot: CGPoint(x: 106, y: 85), rotate: -10 - 23 * kick, dy: -4 * kick) { leg in
                fill(leg, ellipse(120, 85, 15, 5.5), shadowCoat)
                fill(leg, ellipse(132, 84, 7, 5), snout)
            }
        }

        // Front paws tap during fetch
        let tapping = fetch || mood == .excited || mood == .celebrate
        let tapBack = tapping ? -6 * wave(0.5, offset: 0.25) : 0
        let tapFront = tapping ? -6 * wave(0.5) : 0
        let paws = placed(b, \.paws)
        var back = paws
        back.translateBy(x: 0, y: tapBack)
        fill(back, rrect(84, 68, 10, 24, 5), shadowCoat)
        fill(back, ellipse(90, 92, 8, 3.5), artwork == .classic ? Color(hex: 0xEFE2CF) : lightCoat)
        let lift = movement.pawLift
        if lift > 0 {
            let paw = CGPoint(x: 76 - 34 * lift, y: 92 - 40 * lift)
            stroke(paws, path {
                $0.move(to: CGPoint(x: 77, y: 71 - 3 * lift))
                $0.addQuadCurve(to: CGPoint(x: paw.x, y: paw.y - 5 * (1 - lift)),
                                control: CGPoint(x: 76 - 12 * lift, y: 78))
            }, lightCoat, 10 - lift)
            fill(paws, ellipse(paw.x, paw.y, 8, 3.5 + 3.5 * lift), snout)
            let pads = blush.opacity(min(1, 3 * lift))
            fill(paws, ellipse(paw.x, paw.y + 1, 3.3, 2.8), pads)
            for offset in [-3.5, 0, 3.5] {
                fill(paws, ellipse(paw.x + offset, paw.y - 3, 1.45, 1.55), pads)
            }
        } else {
            var front = paws
            front.translateBy(x: 0, y: tapFront)
            fill(front, rrect(72, 66, 10, 26, 5), lightCoat)
            fill(front, ellipse(76, 92, 8, 3.5), snout)
        }

        drawNeckwear(placed(b, \.neck), left: CGPoint(x: 62, y: 46), right: CGPoint(x: 92, y: 44),
                     tip: CGPoint(x: 78, y: 62))

        let bp = phase(0.9)
        with(placed(b, \.head), pivot: CGPoint(x: 74, y: 46), rotate: movement.headAngle,
             dy: movement.headLift) { h in
            let headShape = ellipse(70, 30, 18, 18)
            fill(h, headShape, coat)
            drawCoatHighlights(h, on: headShape, highlight: ellipse(67, 16, 11, 5.5))
            with(h, pivot: CGPoint(x: 62, y: 37), scaleX: muzzleScale) { jaw in
                fill(jaw, ellipse(54, 37, 13, 8.5), snout)
                drawNose(jaw, cx: 43, cy: 34)

                if bark {
                    let open = kf(bp, [(0, 0.3), (0.1, 1), (0.3, 0.3), (1, 0.3)])
                    fill(jaw, ellipse(52, 44, 5, 4 * open), ink)
                } else {
                    if look == nil || playful || fetch {
                        let pant = 1 + 0.4 * wave(0.45)
                        with(jaw, pivot: CGPoint(x: 53.5, y: 43.5), scaleY: pant) { tg in
                            fill(tg, path {
                                $0.move(to: CGPoint(x: 50, y: 43.5))
                                $0.addQuadCurve(to: CGPoint(x: 57, y: 43.5), control: CGPoint(x: 53.5, y: 52.5))
                                $0.closeSubpath()
                            }, tongue)
                        }
                    }
                    stroke(jaw, path { $0.move(to: CGPoint(x: 46, y: 42)); $0.addQuadCurve(to: CGPoint(x: 57, y: 42), control: CGPoint(x: 51, y: 45)) }, ink, 1.5)
                }
            }

            if mood == .petting {
                stroke(h, path { $0.move(to: CGPoint(x: 60, y: 27)); $0.addQuadCurve(to: CGPoint(x: 69, y: 27), control: CGPoint(x: 64, y: 22)) }, ink, 2)
                fill(h, ellipse(65, 36, 4.5, 2.6), blush)
            } else {
                let blink = kf(phase(3.8), [(0, 1), (0.92, 1), (0.95, 0.1), (1, 1)])
                with(h, pivot: CGPoint(x: 64, y: 27), scaleY: blink) { e in
                    fill(e, ellipse(64, 27, 3.3, 3.3), ink)
                    fill(e, ellipse(65.2, 25.8, 1.1, 1.1), .white)
                }
            }

            let twitch = kf(phase(4.2), [(0, 0), (0.86, 0), (0.89, -14), (0.92, 4), (0.95, -8), (1, 0)])
            with(h, pivot: CGPoint(x: 76, y: 14), rotate: twitch + (mood == .alert ? -18 : 0)) { e in
                if look != nil { drawEar(e, x: 75, y: 15, length: 29); return }
                let ear = path {
                    $0.move(to: CGPoint(x: 74, y: 13))
                    $0.addQuadCurve(to: CGPoint(x: 88, y: 34), control: CGPoint(x: 91, y: 9))
                    $0.addQuadCurve(to: CGPoint(x: 77, y: 28), control: CGPoint(x: 81, y: 36))
                    $0.addQuadCurve(to: CGPoint(x: 74, y: 13), control: CGPoint(x: 72, y: 20))
                    $0.closeSubpath()
                }
                fill(e, ear, ears)
                stroke(e, ear, rimColor, 0.9)
            }
            if mood == .coverEyes {
                stroke(h, path { $0.move(to: CGPoint(x: 78, y: 55)); $0.addQuadCurve(to: CGPoint(x: 65, y: 28), control: CGPoint(x: 70, y: 41)) }, shadowCoat, 10)
                fill(h, ellipse(62, 27, 9, 7), lightCoat)
                stroke(h, path { $0.move(to: CGPoint(x: 68, y: 53)); $0.addQuadCurve(to: CGPoint(x: 59, y: 31), control: CGPoint(x: 60, y: 44)) }, coat, 8)
                fill(h, ellipse(57, 30, 7, 5), snout)
            }
        }
    }

    // MARK: Trotting

    func drawTrotting(_ b: GraphicsContext, movement: DogMovement) {
        let paws = placed(b, \.paws)
        for (index, x) in [70.0, 112.0, 76.0, 118.0].enumerated() {
            let offset = Double(index % 2 == index / 2 ? 0 : 1) * 0.28
            let stride = wave(0.56, offset: offset)
            with(paws, pivot: CGPoint(x: x, y: 67), rotate: -27 + 54 * stride, dy: -4 * stride) { leg in
                fill(leg, rrect(x - 4, 65, 8.5, 24, 4), index < 2 ? shadowCoat : lightCoat)
                fill(leg, ellipse(x - 1, 88, 6.5, 3.3), index < 2 ? shadowCoat : snout)
            }
        }
        let torso = placed(b, \.torso)
        let body = ellipse(93, 60, 36, 17)
        fill(torso, body, coat)
        drawMarkings(torso, on: body, patchShape: ellipse(106, 53, 15, 8))
        drawCoatHighlights(torso, on: body, highlight: ellipse(90, 47, 25, 5.5))
        if look?.chestPatch == true { fill(torso, ellipse(67, 65, 6, 8), Color(hex: 0xDBD0C1)) }
        if let harness = look?.harness {
            stroke(torso, path {
                $0.move(to: CGPoint(x: 66, y: 64))
                $0.addQuadCurve(to: CGPoint(x: 96, y: 55), control: CGPoint(x: 80, y: 69))
            }, Color(hex: harness), 4)
        }
        drawNeckwear(placed(b, \.neck), left: CGPoint(x: 57, y: 49), right: CGPoint(x: 78, y: 51), tip: CGPoint(x: 66, y: 67),
                     tagOffset: look == nil ? -1 : 0)
        with(placed(b, \.head), pivot: CGPoint(x: 55, y: 43), rotate: movement.headAngle,
             dy: movement.headLift) { head in
            let headShape = ellipse(55, 43, 16.5, 15.5)
            fill(head, headShape, coat)
            drawCoatHighlights(head, on: headShape, highlight: ellipse(52, 31, 10, 4.8))
            with(head, pivot: CGPoint(x: 52, y: 49), scaleX: muzzleScale) { jaw in
                fill(jaw, ellipse(42, 49, 12, 7), snout)
                drawNose(jaw, cx: 33, cy: 46, rx: 3.7, ry: 2.8)
            }
            fill(head, ellipse(50, 41, 2.9, 2.9), ink)
            with(head, pivot: CGPoint(x: 61, y: 32), rotate: -10 + 24 * wave(0.56)) { ear in
                if look == nil {
                    let shape = ellipse(65, 43, 7, 12)
                    fill(ear, shape, ears)
                    stroke(ear, shape, rimColor, 0.9)
                } else {
                    drawEar(ear, x: 61, y: 32, length: 21)
                }
            }
        }
    }

    // MARK: Extras

    func drawTag(_ c: GraphicsContext, x: Double, y: Double) {
        guard hasTag else { return }
        stroke(c, ellipse(x, y - 0.5, 2, 2), Color(hex: 0x855C27), 1)
        fill(c, ellipse(x, y + 5, 5.1, 5.1), Color(hex: 0xDFAF53))
        stroke(c, ellipse(x, y + 5, 4, 4), Color(hex: 0x946329), 0.8)
        fill(c, ellipse(x - 1, y + 4, 1.2, 1.2), Color(hex: 0xFCE0AB))
    }

    func drawZs(_ c: GraphicsContext) {
        for i in 0..<3 {
            let p = phase(3.2, offset: Double(i) * 3.2 / 3)
            let opacity = p < 0.3 ? p / 0.3 * 0.9 : 0.9 * (1 - (p - 0.3) / 0.7)
            var l = c
            l.opacity *= opacity
            let size = [9.0, 11.0, 13.0][i]
            l.draw(Text(i == 2 ? "Z" : "z").font(.system(size: size, weight: .bold, design: .rounded)).foregroundColor(Color(white: 0.82)),
                   at: CGPoint(x: 42 - 16 * p, y: 42 - 34 * p))
        }
    }

    func drawPuffs(_ c: GraphicsContext) {
        for j in 0..<2 {
            let p = phase(2.8, offset: -Double(j) * 0.35)
            guard p >= 0.4 else { continue }
            let q = (p - 0.4) / 0.6
            var l = c
            l.opacity *= 0.85 * (1 - q)
            let r = 5 * (0.5 + 1.2 * q)
            fill(l, ellipse(10 - 34 * q, 70 - 4 * q, r, r), Color(white: 0.9))
        }
    }

    func drawBall(_ c: GraphicsContext) {
        let p = phase(1.0)
        let height = 48 * sin(.pi * p)
        let onGround = p < 0.06 || p > 0.94
        var shadow = c
        shadow.opacity *= 0.4 - 0.28 * sin(.pi * p)
        let sr = 9 * (1 - 0.55 * sin(.pi * p))
        fill(shadow, ellipse(-22, 95, sr, sr * 0.3), .black)
        let sx = onGround ? 1.2 : 1.0, sy = onGround ? 0.8 : 1.0
        with(c, pivot: CGPoint(x: -22, y: 94), scaleX: sx, scaleY: sy, dy: -height) { l in
            fill(l, ellipse(-22, 87, 7, 7), ballColor)
            stroke(l, path { $0.move(to: CGPoint(x: -27, y: 85)); $0.addQuadCurve(to: CGPoint(x: -17, y: 85), control: CGPoint(x: -22, y: 89)) }, .white, 1.3)
        }
    }

    func drawWoof(_ c: GraphicsContext) {
        let bp = phase(0.9)
        guard bp < 0.45 else { return }
        var l = c
        l.opacity *= 1 - bp / 0.45
        l.draw(Text("woof!").font(.system(size: 12 + 4 * bp, weight: .heavy, design: .rounded)).foregroundColor(Color(white: 0.9)),
               at: CGPoint(x: 18 - 10 * bp, y: 18 - 8 * bp))
    }
}
