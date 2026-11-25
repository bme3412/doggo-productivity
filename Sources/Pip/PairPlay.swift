import SwiftUI

enum PairPlayKind: String, CaseIterable, Identifiable {
    case play
    case cuddle
    case dance
    case zoomies

    var id: String { rawValue }

    var title: String {
        switch self {
        case .play: return "Play together"
        case .cuddle: return "Cuddle"
        case .dance: return "Dance on 2 legs"
        case .zoomies: return "Zoomies!"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .play: return 9.5
        case .cuddle: return 13.0
        case .dance: return 10.5
        case .zoomies: return 8.5
        }
    }

    var requiresPair: Bool {
        self != .zoomies
    }
}

struct PairPlayEvent: Equatable {
    let id = UUID()
    let kind: PairPlayKind
    let startedAt: Date
    let leaderIsLeft: Bool
    let seed: Double

    var endsAt: Date { startedAt.addingTimeInterval(kind.duration) }
}

struct PairDogPose {
    let mood: Mood
    let elapsed: TimeInterval
    let facingRight: Bool
    let dx: CGFloat
    let dy: CGFloat
    let zIndex: Double
    let leanTowardPartner: Double
}

enum PairPlayChoreography {
    static func pose(
        for event: PairPlayEvent,
        side: DogMotion.PairSide,
        at now: Date,
        baseZIndex: Double
    ) -> PairDogPose {
        let elapsed = max(0, now.timeIntervalSince(event.startedAt))
        let total = event.kind.duration
        switch event.kind {
        case .cuddle:
            return cuddle(elapsed: elapsed, total: total, side: side, baseZIndex: baseZIndex)
        case .dance:
            return dance(elapsed: elapsed, total: total, side: side, leaderIsLeft: event.leaderIsLeft, baseZIndex: baseZIndex)
        case .play:
            return play(elapsed: elapsed, total: total, side: side, leaderIsLeft: event.leaderIsLeft, baseZIndex: baseZIndex)
        case .zoomies:
            return zoomies(elapsed: elapsed, total: total, side: side, leaderIsLeft: event.leaderIsLeft, seed: event.seed, baseZIndex: baseZIndex)
        }
    }

    // MARK: - Cuddle

    private static func cuddle(elapsed: TimeInterval, total: TimeInterval,
                               side: DogMotion.PairSide, baseZIndex: Double) -> PairDogPose {
        let isLeft = side == .left
        let approach = smoothstep(0.0, 1.8, elapsed)
        let retreat = smoothstep(total - 1.8, total, elapsed)
        let closeness = approach * (1 - retreat)

        let targetX: CGFloat = isLeft ? 18 : -16
        let targetY: CGFloat = isLeft ? 0 : 5
        let dx = targetX * closeness
        let dy = targetY * closeness

        let mood: Mood
        let moodElapsed: TimeInterval
        if elapsed < 1.5 {
            mood = .walking
            moodElapsed = elapsed
        } else if elapsed < total - 1.8 {
            mood = .cuddle
            moodElapsed = elapsed - 1.5
        } else {
            mood = .wag
            moodElapsed = elapsed - (total - 1.8)
        }

        // Gentle synchronized nestle sway while cuddling
        let sway: CGFloat = (elapsed >= 1.8 && elapsed <= total - 1.8)
            ? CGFloat(sin((elapsed - 1.8) * 1.4)) * (isLeft ? 1.5 : -1.5)
            : 0

        return PairDogPose(
            mood: mood,
            elapsed: moodElapsed,
            facingRight: isLeft,
            dx: dx + sway,
            dy: dy,
            zIndex: isLeft ? 2 : 1,
            leanTowardPartner: closeness
        )
    }

    // MARK: - Dance on 2 legs

    private static func dance(elapsed: TimeInterval, total: TimeInterval,
                              side: DogMotion.PairSide, leaderIsLeft: Bool, baseZIndex: Double) -> PairDogPose {
        let isLeft = side == .left
        let approach = smoothstep(0.0, 1.35, elapsed)
        let retreat = smoothstep(total - 1.4, total, elapsed)
        let together = approach * (1 - retreat)

        // Position them so their raised front paws meet right in the middle
        let targetX: CGFloat = isLeft ? 25 : -28
        let targetY: CGFloat = isLeft ? 0 : 6

        let dancing = elapsed >= 1.25 && elapsed < total - 1.45
        let danceTime = max(0, elapsed - 1.25)

        // Partner salsa/waltz sway and joyful little two-step hops
        let swayPhase = danceTime * 2.8 + (leaderIsLeft ? 0 : .pi)
        let partnerSway: CGFloat = dancing ? CGFloat(sin(swayPhase)) * 7.5 : 0
        let stepHop: CGFloat = dancing ? -CGFloat(abs(sin(danceTime * 5.6 + (isLeft ? 0 : 0.45)))) * 5.5 : 0

        let mood: Mood
        let moodElapsed: TimeInterval
        if elapsed < 1.15 {
            mood = .walking
            moodElapsed = elapsed
        } else if elapsed < total - 1.45 {
            mood = .dance
            moodElapsed = danceTime
        } else if elapsed < total - 0.6 {
            mood = .celebrate
            moodElapsed = elapsed - (total - 1.45)
        } else {
            mood = .wag
            moodElapsed = elapsed - (total - 0.6)
        }

        return PairDogPose(
            mood: mood,
            elapsed: moodElapsed,
            facingRight: isLeft,
            dx: targetX * together + partnerSway,
            dy: targetY * together + stepHop,
            zIndex: isLeft ? 2 : 1,
            leanTowardPartner: dancing ? 1 : 0
        )
    }

    // MARK: - Play together (play-bows, pounces, nose boops)

    private static func play(elapsed: TimeInterval, total: TimeInterval,
                             side: DogMotion.PairSide, leaderIsLeft: Bool, baseZIndex: Double) -> PairDogPose {
        let isLeft = side == .left
        let isLeader = (isLeft == leaderIsLeft)
        let dir: CGFloat = isLeft ? 1 : -1

        // 0.0-2.0: leader play-bows, partner perks up
        // 2.0-4.2: leader pounces in, partner play-bows & springs back
        // 4.2-6.5: partner pounces in, leader hops excitedly, nose boop in center
        // 6.5-8.2: playful double bounce together
        // 8.2-9.5: happy return to rest
        let returnBlend = smoothstep(total - 1.3, total, elapsed)

        let rawX: CGFloat
        let rawY: CGFloat
        let mood: Mood
        let moodElapsed: TimeInterval

        if elapsed < 2.0 {
            if isLeader {
                let p = smoothstep(0.0, 0.7, elapsed)
                rawX = dir * (12 * p)
                rawY = -CGFloat(abs(sin(elapsed * 5.0))) * 3 * p
                mood = .playBow
                moodElapsed = elapsed
            } else {
                rawX = 0
                rawY = 0
                mood = elapsed < 0.7 ? .alert : .excited
                moodElapsed = elapsed
            }
        } else if elapsed < 4.2 {
            let t = elapsed - 2.0
            if isLeader {
                let lunge = sin(min(.pi, t / 1.8 * .pi))
                rawX = dir * (12 + 18 * CGFloat(lunge))
                rawY = -CGFloat(lunge) * 11
                mood = .excited
                moodElapsed = t
            } else {
                let dodge = sin(min(.pi, t / 2.0 * .pi))
                rawX = dir * (-6 * CGFloat(dodge))
                rawY = isLeft ? 0 : 4 * CGFloat(dodge)
                mood = .playBow
                moodElapsed = t
            }
        } else if elapsed < 6.5 {
            let t = elapsed - 4.2
            if isLeader {
                let hop = sin(min(.pi, t / 1.8 * .pi))
                rawX = dir * (16 - 4 * CGFloat(hop))
                rawY = -CGFloat(abs(sin(t * 6.0))) * 8
                mood = t < 1.1 ? .playBow : .excited
                moodElapsed = t
            } else {
                let pounce = sin(min(.pi, t / 1.9 * .pi))
                rawX = dir * (24 * CGFloat(pounce))
                rawY = -CGFloat(pounce) * 10 + (isLeft ? 0 : 4)
                mood = .excited
                moodElapsed = t
            }
        } else if elapsed < total - 1.3 {
            let t = elapsed - 6.5
            // Nose boop & happy dual hops right in the middle
            rawX = dir * (18 + CGFloat(sin(t * 7.0)) * 5)
            rawY = -CGFloat(abs(sin(t * 6.5 + (isLeft ? 0 : 0.7)))) * 9 + (isLeft ? 0 : 3)
            mood = t < 0.9 ? .playBow : .celebrate
            moodElapsed = t
        } else {
            let t = elapsed - (total - 1.3)
            rawX = dir * 18
            rawY = 0
            mood = .wag
            moodElapsed = t
        }

        return PairDogPose(
            mood: mood,
            elapsed: moodElapsed,
            facingRight: isLeft,
            dx: rawX * (1 - returnBlend),
            dy: rawY * (1 - returnBlend),
            zIndex: isLeader ? 2 : 1,
            leanTowardPartner: 1 - returnBlend
        )
    }

    // MARK: - Zoomies!

    private static func zoomies(elapsed: TimeInterval, total: TimeInterval,
                                side: DogMotion.PairSide, leaderIsLeft: Bool,
                                seed: Double, baseZIndex: Double) -> PairDogPose {
        // Normalize zoomies onto a shared horizontal runway x ∈ [0, 1] across the group canvas:
        // Left dog (slot 0, scale 1.0): x=0 -> dx=-58, x=1 -> dx=+104
        // Right dog (slot 118, scale 0.92): x=0 -> dx=-164, x=1 -> dx=+8
        // Single dog (width 210): x=0 -> dx=-56, x=1 -> dx=+8
        let (minDX, maxDX, homeNorm): (CGFloat, CGFloat, Double) = {
            switch side {
            case .left: return (-58, 104, 0.36)
            case .right: return (-164, 8, 0.95)
            case .single: return (-56, 8, 0.87)
            }
        }()

        let isLeader = (side == .single) || (side == .left && leaderIsLeft) || (side == .right && !leaderIsLeft)
        let chaseLag = isLeader ? 0.0 : 0.38
        let t = max(0, elapsed - chaseLag)

        // Multi-lap chaotic runway keyframes (time, normalizedX, arcJump)
        let keys: [(Double, Double)]
        if side == .single {
            keys = [
                (0.0, homeNorm),
                (0.9, 0.04),
                (1.9, 0.96),
                (2.8, 0.08),
                (3.8, 0.94),
                (4.7, 0.12),
                (5.7, 0.95),
                (6.8, 0.25),
                (7.6, homeNorm),
                (total, homeNorm)
            ]
        } else if isLeader {
            let startHigh = leaderIsLeft ? 0.98 : 0.04
            let otherEnd = leaderIsLeft ? 0.04 : 0.98
            keys = [
                (0.0, homeNorm),
                (1.15, startHigh),
                (2.35, otherEnd),
                (3.45, startHigh),
                (4.45, otherEnd),
                (5.55, startHigh),
                (6.65, otherEnd),
                (7.65, homeNorm),
                (total, homeNorm)
            ]
        } else {
            // Chaser sprints right behind, then crosses in the opposite direction on lap 3!
            let firstTarget = leaderIsLeft ? 0.94 : 0.06
            let secondTarget = leaderIsLeft ? 0.06 : 0.94
            keys = [
                (0.0, homeNorm),
                (1.20, firstTarget),
                (2.35, secondTarget),
                (3.40, firstTarget),
                (4.35, firstTarget * 0.2 + secondTarget * 0.8),
                (5.40, secondTarget),
                (6.50, firstTarget),
                (7.45, homeNorm),
                (total, homeNorm)
            ]
        }

        let pos = samplePath(t, keys: keys)
        let ahead = samplePath(t + 0.06, keys: keys)
        let velocity = ahead - pos

        let dx = minDX + (maxDX - minDX) * CGFloat(pos)
        let running = elapsed >= chaseLag && elapsed < total - 0.95
        let facingRight: Bool
        if abs(velocity) > 0.002 {
            facingRight = velocity > 0
        } else {
            facingRight = side == .left
        }

        // Bouncy gallop arcs + higher leaps near turnarounds
        let speed = min(1.0, abs(velocity) * 14.0)
        let bounceFreq = 11.5 + seed * 1.5
        let hop: CGFloat = running ? -CGFloat(abs(sin(t * bounceFreq))) * (6.0 + 7.0 * CGFloat(speed)) : 0
        let groundAdjust: CGFloat = side == .right ? 4 * (running ? 1 : 0) : 0

        // Swap z-order based on direction so dogs weave cleanly in front of and behind each other!
        let dynamicZ: Double = running ? (facingRight ? 2 : 1) : baseZIndex

        let mood: Mood
        let moodElapsed: TimeInterval
        if elapsed < chaseLag {
            mood = .alert
            moodElapsed = elapsed
        } else if running {
            mood = .zoomies
            moodElapsed = t
        } else {
            mood = .excited
            moodElapsed = elapsed - (total - 0.95)
        }

        return PairDogPose(
            mood: mood,
            elapsed: moodElapsed,
            facingRight: facingRight,
            dx: dx,
            dy: hop + groundAdjust,
            zIndex: dynamicZ,
            leanTowardPartner: 0
        )
    }

    // MARK: - Math helpers

    private static func smoothstep(_ edge0: TimeInterval, _ edge1: TimeInterval, _ x: TimeInterval) -> CGFloat {
        guard edge1 > edge0 else { return x >= edge1 ? 1 : 0 }
        let u = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return CGFloat(u * u * (3 - 2 * u))
    }

    private static func samplePath(_ t: Double, keys: [(Double, Double)]) -> Double {
        guard let first = keys.first else { return 0.5 }
        if t <= first.0 { return first.1 }
        for i in 1..<keys.count {
            let (t0, v0) = keys[i - 1]
            let (t1, v1) = keys[i]
            if t <= t1 {
                let u = t1 == t0 ? 1 : (t - t0) / (t1 - t0)
                let eased = u * u * (3 - 2 * u)
                return v0 + (v1 - v0) * eased
            }
        }
        return keys.last?.1 ?? 0.5
    }
}

/// Shared visual accents rendered over the pair during cuddling, dancing, and play.
struct PairPlayEffectsOverlay: View {
    let event: PairPlayEvent
    let now: Date
    let size: CGSize

    var body: some View {
        Canvas { ctx, canvasSize in
            let elapsed = max(0, now.timeIntervalSince(event.startedAt))
            let total = event.kind.duration
            let midX = canvasSize.width * 0.58

            switch event.kind {
            case .cuddle:
                guard elapsed > 1.8 && elapsed < total - 1.6 else { return }
                let local = elapsed - 1.8
                for i in 0..<3 {
                    let period = 2.8
                    let p = (local + Double(i) * 0.95).truncatingRemainder(dividingBy: period) / period
                    let alpha = p < 0.2 ? p / 0.2 : (1 - p) / 0.8
                    let x = midX + CGFloat(sin(p * .pi * 2 + Double(i) * 1.4)) * 12 + CGFloat(i - 1) * 11
                    let y = 46 - CGFloat(p) * 36
                    var layer = ctx
                    layer.opacity = alpha * 0.88
                    drawHeart(in: layer, center: CGPoint(x: x, y: y), size: 5.5 + CGFloat(i % 2) * 1.8,
                              color: i == 1 ? Color(hex: 0xE87A88) : Color(hex: 0xF29B9B))
                }

            case .dance:
                guard elapsed > 1.4 && elapsed < total - 1.4 else { return }
                let local = elapsed - 1.4
                let symbols = ["♪", "✦", "♫"]
                for i in 0..<3 {
                    let period = 2.1
                    let p = (local + Double(i) * 0.7).truncatingRemainder(dividingBy: period) / period
                    let alpha = p < 0.2 ? p / 0.2 : (1 - p) / 0.8
                    let x = midX + CGFloat(i - 1) * 20 + CGFloat(sin(p * .pi * 2)) * 6
                    let y = 34 - CGFloat(p) * 26
                    var layer = ctx
                    layer.opacity = alpha * 0.9
                    let color = i == 1 ? Theme.amber : Theme.trail
                    layer.draw(
                        Text(symbols[i])
                            .font(.system(size: i == 1 ? 11 : 12, weight: .bold, design: .rounded))
                            .foregroundColor(color),
                        at: CGPoint(x: x, y: y)
                    )
                }

            case .play:
                // Little joyful burst during mid-sequence pounces & nose boop
                guard elapsed > 2.4 && elapsed < total - 1.6 else { return }
                let local = elapsed - 2.4
                for i in 0..<2 {
                    let period = 1.6
                    let p = (local + Double(i) * 0.8).truncatingRemainder(dividingBy: period) / period
                    guard p < 0.55 else { continue }
                    let q = p / 0.55
                    let x = midX + CGFloat(i == 0 ? -10 : 12)
                    let y = 32 - CGFloat(q) * 18
                    var layer = ctx
                    layer.opacity = (1 - q) * 0.85
                    layer.draw(
                        Text("✦")
                            .font(.system(size: 9 + 4 * q, weight: .bold))
                            .foregroundColor(Theme.amber),
                        at: CGPoint(x: x, y: y)
                    )
                }

            case .zoomies:
                break
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func drawHeart(in ctx: GraphicsContext, center: CGPoint, size: CGFloat, color: Color) {
        var path = Path()
        let w = size
        let h = size
        path.move(to: CGPoint(x: center.x, y: center.y + h * 0.5))
        path.addCurve(
            to: CGPoint(x: center.x - w, y: center.y - h * 0.15),
            control1: CGPoint(x: center.x - w * 0.55, y: center.y + h * 0.35),
            control2: CGPoint(x: center.x - w, y: center.y + h * 0.15)
        )
        path.addArc(
            center: CGPoint(x: center.x - w * 0.5, y: center.y - h * 0.2),
            radius: w * 0.5,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addArc(
            center: CGPoint(x: center.x + w * 0.5, y: center.y - h * 0.2),
            radius: w * 0.5,
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addCurve(
            to: CGPoint(x: center.x, y: center.y + h * 0.5),
            control1: CGPoint(x: center.x + w, y: center.y + h * 0.15),
            control2: CGPoint(x: center.x + w * 0.55, y: center.y + h * 0.35)
        )
        path.closeSubpath()
        ctx.fill(path, with: .color(color))
    }
}
