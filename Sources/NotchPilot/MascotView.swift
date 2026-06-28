import SwiftUI
import Foundation

// MARK: - Mood model

/// The mascot's mood, driven by NotchPilot's usage/auth/network state.
public enum MascotState: Equatable, Sendable {
    case dormant
    case playing(intensity: Double)   // 0...1, scales bounce speed/amplitude
    case frantic
    case wakeup
    case needsAuth
    case offline
}

// MARK: - Coral / amber / red severity palette

public extension Color {
    /// Claude coral, the brand body color. #CC785C
    static let mascotCoral       = Color(.sRGB, red: 0.800, green: 0.471, blue: 0.361, opacity: 1)
    /// Brighter coral used for the gradient core / highlights. #D97757
    static let mascotCoralBright = Color(.sRGB, red: 0.851, green: 0.467, blue: 0.341, opacity: 1)
    /// Soft peach glow tone. #ED9E7F
    static let mascotCoralGlow   = Color(.sRGB, red: 0.929, green: 0.620, blue: 0.498, opacity: 1)

    /// Severity ramp: calm -> warn -> danger.
    static let severityCalm   = Color.mascotCoral
    static let severityWarn   = Color(.sRGB, red: 0.910, green: 0.639, blue: 0.243, opacity: 1) // amber #E8A33E
    static let severityDanger = Color(.sRGB, red: 0.851, green: 0.290, blue: 0.247, opacity: 1) // red   #D94A3F

    /// Warm near-black for eyes. #281A14
    static let mascotEye   = Color(.sRGB, red: 0.157, green: 0.102, blue: 0.078, opacity: 1)
    /// Sweat-drop blue. #6BAAE2
    static let mascotSweat = Color(.sRGB, red: 0.420, green: 0.667, blue: 0.886, opacity: 1)
}

// MARK: - Tiny pure helpers (nonisolated, allocation-free, deterministic)

/// Sine oscillator with a given period in seconds, range -1...1.
private func osc(_ t: Double, _ period: Double) -> Double {
    sin(t * 2 * .pi / period)
}

/// A quick blink: eyes snap shut for a beat every `period` seconds. Returns openness 0...1.
private func blink(_ t: Double) -> CGFloat {
    let period = 3.8
    let phase = t.truncatingRemainder(dividingBy: period)
    if phase < 0.14 { return CGFloat(1 - sin(phase / 0.14 * .pi)) }
    return 1
}

/// Piecewise-linear keyframe sampler. `times` must be ascending and the same length as `values`.
private func keyframe(_ p: Double, _ times: [Double], _ values: [Double]) -> Double {
    guard let first = times.first, values.count == times.count, !times.isEmpty else { return 0 }
    if p <= first { return values[0] }
    for i in 1..<times.count where p <= times[i] {
        let span = times[i] - times[i - 1]
        let local = span > 0 ? (p - times[i - 1]) / span : 0
        return values[i - 1] + (values[i] - values[i - 1]) * local
    }
    return values[values.count - 1]
}

/// Linear RGB blend between two color tuples.
private func blendColor(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> Color {
    let f = min(max(t, 0), 1)
    return Color(.sRGB,
                 red:   a.0 + (b.0 - a.0) * f,
                 green: a.1 + (b.1 - a.1) * f,
                 blue:  a.2 + (b.2 - a.2) * f,
                 opacity: 1)
}

private let coralRGB = (0.800, 0.471, 0.361)
private let amberRGB = (0.910, 0.639, 0.243)
private let redRGB   = (0.851, 0.290, 0.247)

/// The mood-tinted body color: coral by default, drifting toward amber while playing hard,
/// and toward red while frantic.
private func bodyColor(for state: MascotState) -> Color {
    switch state {
    case .frantic:           return blendColor(coralRGB, redRGB, 0.55)
    case .playing(let i):    return blendColor(coralRGB, amberRGB, min(max(i, 0), 1))
    default:                 return Color.mascotCoral
    }
}

// MARK: - Per-frame animation snapshot

private struct MascotAnim {
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var rotation: Double = 0      // radians
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    var opacity: Double = 1
    var eyeOpen: CGFloat = 1      // 0 closed ... 1 open (vertical squash of the eye)
    var eyeTilt: Double = 0       // worried inward tilt, radians
    var browWorry: CGFloat = 0    // 0...1, draws angled brows when > 0
}

// MARK: - Mood clock

/// Holds the wall-clock instant the current mood began, so one-shot moods (wakeup) can
/// measure elapsed time. NOTE: we use `@StateObject` + this tiny class instead of `@State`
/// on purpose. Under the Command-Line-Tools-only toolchain the `SwiftUIMacros` plugin that
/// implements the `@State` macro is NOT installed, so `@State` fails to compile. `@StateObject`
/// is a plain property wrapper (no macro) and is the leak-free way to keep per-identity state.
private final class MoodClock: ObservableObject {
    let birth = Date()
}

// MARK: - Public view

/// A self-contained, code-drawn Claude "sparkle" mascot that renders one of six moods.
///
/// Animation tech: `TimelineView(.animation(minimumInterval:paused:))` + a single `Canvas`.
/// One clock drives every mood procedurally, so there is nothing to retain or invalidate
/// (no `CADisplayLink`, no per-state animators to leak). The schedule's `paused` flag fully
/// stops the clock for static moods (offline); `minimumInterval` throttles low-energy moods
/// (dormant / needsAuth) to ~12-14fps so a resting mascot costs almost no CPU.
public struct MascotView: View {
    private let state: MascotState

    public init(state: MascotState) {
        self.state = state
    }

    public var body: some View {
        // `.id(moodKey)` gives each mood a fresh identity, which resets the engine's
        // `MoodClock` (so `wakeup` always restarts its one-shot). The key deliberately
        // ignores the `playing` intensity value, so live intensity updates flow into the
        // existing engine without restarting its clock.
        MascotEngine(state: state)
            .id(moodKey)
    }

    private var moodKey: Int {
        switch state {
        case .dormant:   return 0
        case .playing:   return 1
        case .frantic:   return 2
        case .wakeup:    return 3
        case .needsAuth: return 4
        case .offline:   return 5
        }
    }
}

// MARK: - Engine (timeline + canvas + drawing)

private struct MascotEngine: View {
    let state: MascotState
    @StateObject private var clock = MoodClock()

    var body: some View {
        TimelineView(.animation(minimumInterval: tickInterval, paused: isPaused)) { timeline in
            let now = timeline.date
            let t = now.timeIntervalSinceReferenceDate
            let wakeElapsed = now.timeIntervalSince(clock.birth)
            Canvas { context, size in
                self.render(into: &context, size: size, t: t, wakeElapsed: wakeElapsed)
            }
        }
    }

    // Throttle the clock per mood. High-energy moods run at display rate;
    // resting moods sip frames; offline is fully paused (see isPaused).
    private var tickInterval: Double {
        switch state {
        case .dormant:   return 1.0 / 14
        case .needsAuth: return 1.0 / 12
        case .playing, .frantic, .wakeup: return 1.0 / 60
        case .offline:   return 1.0 / 30   // irrelevant; clock is paused
        }
    }

    private var isPaused: Bool {
        if case .offline = state { return true }
        return false
    }

    private var sleepy: Bool {
        if case .needsAuth = state { return true }
        return false
    }

    private var intensity: Double {
        if case .playing(let i) = state { return min(max(i, 0), 1) }
        return 0
    }

    // MARK: Animation math

    private func anim(t: Double, wakeElapsed: Double) -> MascotAnim {
        var a = MascotAnim()
        switch state {
        case .dormant:
            let b = osc(t, 4.0)                       // slow breathe
            a.scaleX = 1 - CGFloat(b) * 0.018
            a.scaleY = 1 + CGFloat(b) * 0.03
            a.rotation = osc(t, 6.5) * 0.05           // gentle sway
            a.eyeOpen = blink(t)

        case .playing:
            let i = intensity
            let freq = 1.6 + 2.6 * i
            let amp  = 6.0 + 18.0 * i
            let bounce = abs(sin(t * .pi * freq))     // 0...1 hop
            a.offsetY = -CGFloat(bounce) * CGFloat(amp)
            let squash = (1 - bounce) * (0.06 + 0.14 * i)
            a.scaleX = 1 + CGFloat(squash)
            a.scaleY = 1 - CGFloat(squash)
            a.rotation = sin(t * .pi * freq * 0.5) * 0.05 * i
            a.eyeOpen = blink(t)

        case .frantic:
            // Two incommensurate sines per axis read as nervous jitter.
            a.offsetX = CGFloat(2.6 * sin(t * 2 * .pi * 11) + 1.8 * sin(t * 2 * .pi * 19 + 1))
            a.offsetY = CGFloat(2.2 * sin(t * 2 * .pi * 13 + 0.5) + 1.4 * sin(t * 2 * .pi * 23))
            a.rotation = sin(t * 2 * .pi * 9) * 0.05
            let p = abs(sin(t * .pi * 7))
            a.scaleX = 1 + CGFloat(p) * 0.03
            a.scaleY = 1 - CGFloat(p) * 0.03
            a.eyeOpen = 1
            a.eyeTilt = 0.5                            // worried inward tilt
            a.browWorry = 1

        case .wakeup:
            let dur = 0.85
            let p = min(max(wakeElapsed / dur, 0), 1)
            // anticipate -> stretch tall -> overshoot -> settle
            a.scaleX = CGFloat(keyframe(p, [0, 0.15, 0.35, 0.60, 1.0], [0.55, 1.18, 0.72, 1.06, 1.0]))
            a.scaleY = CGFloat(keyframe(p, [0, 0.15, 0.35, 0.60, 1.0], [0.55, 0.78, 1.42, 0.92, 1.0]))
            a.offsetY = -CGFloat(sin(p * .pi)) * 12
            a.eyeOpen = CGFloat(min(max((p - 0.10) / 0.30, 0), 1))
            if p >= 1 {                                // settle into a calm breathe
                let b = osc(t, 4.0)
                a.scaleX = 1 - CGFloat(b) * 0.018
                a.scaleY = 1 + CGFloat(b) * 0.03
                a.eyeOpen = blink(t)
            }

        case .needsAuth:
            a.offsetY = CGFloat(osc(t, 3.6)) * 2.0     // slow sleepy bob
            a.rotation = 0.10                          // head tilt
            a.scaleY = 1 + CGFloat(osc(t, 3.6)) * 0.02
            a.eyeOpen = 0                              // eyes drawn as sleepy arcs (see sleepy)

        case .offline:
            a.opacity = 0.45                           // dimmed
            a.eyeOpen = 0.5
        }
        return a
    }

    // MARK: Drawing

    private func render(into context: inout GraphicsContext, size: CGSize, t: Double, wakeElapsed: Double) {
        let a = anim(t: t, wakeElapsed: wakeElapsed)

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let bodyR = min(size.width, size.height) * 0.30
        let tint = bodyColor(for: state)

        // Global pose: dim, translate (bounce/jitter), rotate, then squash/stretch.
        context.opacity = a.opacity
        context.translateBy(x: center.x + a.offsetX, y: center.y + a.offsetY)
        context.rotate(by: .radians(a.rotation))
        context.scaleBy(x: a.scaleX, y: a.scaleY)
        context.translateBy(x: -center.x, y: -center.y)

        // Soft coral halo behind the body.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: bodyR * 0.28))
            layer.opacity = 0.55
            let glow = Path(ellipseIn: CGRect(x: center.x - bodyR * 0.95,
                                              y: center.y - bodyR * 0.95,
                                              width: bodyR * 1.9, height: bodyR * 1.9))
            layer.fill(glow, with: .color(tint.opacity(0.55)))
        }

        // Body shading: bright core fading to the mood tint.
        let shading: GraphicsContext.Shading = .radialGradient(
            Gradient(colors: [Color.mascotCoralGlow, tint]),
            center: center, startRadius: 0, endRadius: bodyR * 1.05)

        // Eight rays, alternating long / short, forming the soft sparkle burst.
        let rayWidth = bodyR * 0.36
        let rayInner = bodyR * 0.04
        let longLen  = bodyR * 1.05
        let shortLen = bodyR * 0.66
        for i in 0..<8 {
            let angle = Double(i) / 8.0 * 2 * .pi
            let len = (i % 2 == 0) ? longLen : shortLen
            let rect = CGRect(x: -rayWidth / 2, y: -len, width: rayWidth, height: len - rayInner)
            let petal = Path(roundedRect: rect, cornerRadius: rayWidth / 2)
            let tf = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: CGFloat(angle))
            context.fill(petal.applying(tf), with: shading)
        }

        // Center disc unifies the rays into one body.
        let discR = bodyR * 0.52
        let disc = Path(ellipseIn: CGRect(x: center.x - discR, y: center.y - discR,
                                          width: discR * 2, height: discR * 2))
        context.fill(disc, with: shading)

        // Face.
        drawFace(into: &context, center: center, bodyR: bodyR, a: a)

        // Mood-specific props.
        switch state {
        case .frantic:   drawSweat(into: &context, center: center, bodyR: bodyR, t: t)
        case .needsAuth: drawZzz(into: &context, center: center, bodyR: bodyR, t: t)
        case .offline:   drawNoSignal(into: &context, center: center, bodyR: bodyR)
        default: break
        }
    }

    private func drawFace(into context: inout GraphicsContext, center: CGPoint, bodyR: CGFloat, a: MascotAnim) {
        let eyeY  = center.y - bodyR * 0.16
        let eyeDX = bodyR * 0.30
        let eyeRX = bodyR * 0.105
        let eyeRY = bodyR * 0.155

        if sleepy {
            // Sleepy: downward arcs instead of open eyes.
            for sx in [-1.0, 1.0] {
                let ex = center.x + CGFloat(sx) * eyeDX
                var arc = Path()
                arc.move(to: CGPoint(x: ex - eyeRX, y: eyeY))
                arc.addQuadCurve(to: CGPoint(x: ex + eyeRX, y: eyeY),
                                 control: CGPoint(x: ex, y: eyeY + eyeRX * 0.95))
                context.stroke(arc, with: .color(.mascotEye),
                               style: StrokeStyle(lineWidth: max(1.5, bodyR * 0.05), lineCap: .round))
            }
            return
        }

        for sx in [-1.0, 1.0] {
            let ex = center.x + CGFloat(sx) * eyeDX
            let ry = max(eyeRY * a.eyeOpen, bodyR * 0.012)   // keep a sliver when blinking
            var eye = Path(ellipseIn: CGRect(x: ex - eyeRX, y: eyeY - ry, width: eyeRX * 2, height: ry * 2))
            if a.eyeTilt != 0 {
                let tf = CGAffineTransform(translationX: ex, y: eyeY)
                    .rotated(by: CGFloat(sx * a.eyeTilt))
                    .translatedBy(x: -ex, y: -eyeY)
                eye = eye.applying(tf)
            }
            context.fill(eye, with: .color(.mascotEye))
            // Catch-light.
            let hl = CGRect(x: ex - eyeRX * 0.45, y: eyeY - ry * 0.5, width: eyeRX * 0.5, height: ry * 0.5)
            context.fill(Path(ellipseIn: hl), with: .color(.white.opacity(0.85)))
        }

        // Worried brows (frantic).
        if a.browWorry > 0 {
            for sx in [-1.0, 1.0] {
                let ex = center.x + CGFloat(sx) * eyeDX
                let by = eyeY - eyeRY * 1.6
                var brow = Path()
                let inner = CGPoint(x: ex + CGFloat(sx) * eyeRX * 0.4, y: by - eyeRX * 0.55) // raised inner
                let outer = CGPoint(x: ex - CGFloat(sx) * eyeRX * 0.9, y: by + eyeRX * 0.25)
                brow.move(to: inner)
                brow.addLine(to: outer)
                context.stroke(brow, with: .color(.mascotEye),
                               style: StrokeStyle(lineWidth: max(1.5, bodyR * 0.045), lineCap: .round))
            }
        }
    }

    private func drawSweat(into context: inout GraphicsContext, center: CGPoint, bodyR: CGFloat, t: Double) {
        let drift = (t.truncatingRemainder(dividingBy: 1.2)) / 1.2   // 0...1 loop
        let dr = bodyR * 0.10
        let sx = center.x + bodyR * 0.58
        let sy = center.y - bodyR * 0.30 + CGFloat(drift) * bodyR * 0.55
        let fade = 1 - drift

        var drop = Path()
        drop.addEllipse(in: CGRect(x: sx - dr, y: sy - dr, width: dr * 2, height: dr * 2))
        drop.move(to: CGPoint(x: sx - dr * 0.7, y: sy - dr * 0.3))
        drop.addLine(to: CGPoint(x: sx, y: sy - dr * 2.0))
        drop.addLine(to: CGPoint(x: sx + dr * 0.7, y: sy - dr * 0.3))
        drop.closeSubpath()
        context.fill(drop, with: .color(.mascotSweat.opacity(fade)))
        context.fill(Path(ellipseIn: CGRect(x: sx - dr * 0.55, y: sy - dr * 0.55, width: dr * 0.5, height: dr * 0.5)),
                     with: .color(.white.opacity(0.7 * fade)))
    }

    private func drawZzz(into context: inout GraphicsContext, center: CGPoint, bodyR: CGFloat, t: Double) {
        let base = (t.truncatingRemainder(dividingBy: 3.0)) / 3.0
        for k in 0..<3 {
            let kp = (Double(k) / 3.0 + base).truncatingRemainder(dividingBy: 1.0)
            let zx = center.x + bodyR * 0.45 + CGFloat(kp) * bodyR * 0.5
            let zy = center.y - bodyR * 0.5 - CGFloat(kp) * bodyR * 0.9
            let zSize = bodyR * (0.16 + 0.18 * CGFloat(kp))
            let alpha = 1 - kp
            let z = Text("z")
                .font(.system(size: zSize, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.mascotCoral.opacity(alpha))
            context.draw(z, at: CGPoint(x: zx, y: zy))
        }
    }

    private func drawNoSignal(into context: inout GraphicsContext, center: CGPoint, bodyR: CGFloat) {
        let nx = center.x + bodyR * 0.42
        let ny = center.y + bodyR * 0.55
        let bw = bodyR * 0.08
        for k in 0..<3 {
            let bh = bodyR * 0.10 * (CGFloat(k) + 1)
            let bx = nx + CGFloat(k) * (bw + bodyR * 0.04)
            let rect = CGRect(x: bx, y: ny - bh, width: bw, height: bh)
            context.fill(Path(roundedRect: rect, cornerRadius: bw * 0.3),
                         with: .color(.mascotEye.opacity(0.6)))
        }
        var slash = Path()
        slash.move(to: CGPoint(x: nx - bodyR * 0.06, y: ny - bodyR * 0.42))
        slash.addLine(to: CGPoint(x: nx + bodyR * 0.42, y: ny + bodyR * 0.06))
        context.stroke(slash, with: .color(.severityDanger),
                       style: StrokeStyle(lineWidth: max(2, bodyR * 0.05), lineCap: .round))
    }
}
