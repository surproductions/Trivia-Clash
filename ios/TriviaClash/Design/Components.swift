import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.volt
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.display(.headline))
            .textCase(.uppercase)
            .foregroundStyle(Theme.onVolt)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(tint))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.label(.headline))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(Theme.surfaceRaised))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

// MARK: - Surfaces

struct Panel<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(Theme.surface))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.label(.caption))
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(Theme.inkMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The wordmark: two heavy words split by a slanted volt bar.
struct Wordmark: View {
    var size: Font.TextStyle = .largeTitle
    var body: some View {
        HStack(spacing: 10) {
            Text("TRIVIA").foregroundStyle(Theme.ink)
            Rectangle()
                .fill(Theme.volt)
                .frame(width: 6)
                .rotationEffect(.degrees(14))
                .padding(.vertical, 2)
            Text("CLASHER").foregroundStyle(Theme.voltInk)
        }
        .font(.display(size))
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trivia Clasher")
    }
}

// MARK: - Players

struct AvatarBadge: View {
    let avatar: Int
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle().fill(Theme.avatarColor(avatar))
            Image(systemName: Theme.avatarGlyph(avatar))
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(Theme.onVolt)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct TeamTag: View {
    let index: Int
    var body: some View {
        Text(TeamStyle.name(index))
            .font(.label(.caption2))
            .textCase(.uppercase)
            .foregroundStyle(Theme.onVolt)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.teamColor(index)))
    }
}

struct Chip: View {
    let text: String
    var symbol: String?
    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol) }
            Text(text).lineLimit(1)
        }
        .font(.label(.caption))
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.surfaceRaised))
    }
}

// MARK: - Countdown

/// Ring + number. The number is whole seconds remaining (rounded up), which is
/// what the player can act on; the ring sweeps smoothly.
struct CountdownRing: View {
    let remainingMs: Int64
    var totalMs: Int64 = 10_000
    var size: CGFloat = 84

    private var fraction: Double { min(1, max(0, Double(remainingMs) / Double(totalMs))) }
    private var seconds: Int { Int((remainingMs + 999) / 1000) }
    private var tint: Color { seconds <= 3 ? Theme.wrong : (seconds <= 5 ? Theme.warning : Theme.voltInk) }

    var body: some View {
        ZStack {
            Circle().stroke(Theme.surfaceRaised, lineWidth: 8)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(seconds)")
                .font(.numeric(.title))
                .foregroundStyle(seconds <= 3 ? Theme.wrong : Theme.ink)
                .contentTransition(.numericText())
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time remaining")
        .accessibilityValue("\(seconds) seconds")
    }
}

// MARK: - Answers

enum AnswerState: Equatable {
    case idle, chosen, dimmed, correct, wrong, revealedOther
}

struct AnswerButton: View {
    let index: Int
    let text: String
    let state: AnswerState
    var count: Int?
    let action: () -> Void

    private static let letters = ["A", "B", "C", "D"]

    private var fill: Color {
        switch state {
        case .idle, .dimmed, .revealedOther: return Theme.surface
        case .chosen: return Theme.volt
        case .correct: return Theme.correct
        case .wrong: return Theme.wrong
        }
    }

    private var textColor: Color {
        switch state {
        case .chosen, .correct, .wrong: return Theme.onVolt
        default: return Theme.ink
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(Self.letters[index])
                    .font(.system(.headline, design: .monospaced).weight(.heavy))
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(state == .idle || state == .dimmed || state == .revealedOther ? Theme.surfaceRaised : Color.white.opacity(0.35)))
                Text(text)
                    .font(.label(.body))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)")
                        .font(.numeric(.subheadline))
                        .accessibilityLabel("\(count) players chose this")
                }
                if state == .correct { Image(systemName: "checkmark.circle.fill").font(.title3) }
                if state == .wrong { Image(systemName: "xmark.circle.fill").font(.title3) }
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(fill))
            .opacity(state == .dimmed ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Answer \(Self.letters[index]): \(text)")
        .accessibilityValue(accessibilityState)
    }

    private var accessibilityState: String {
        switch state {
        case .chosen: return "Your answer"
        case .correct: return "Correct answer"
        case .wrong: return "Your answer, incorrect"
        default: return ""
        }
    }
}

// MARK: - Connection

struct ConnectionBanner: View {
    let state: ConnectionState

    var body: some View {
        switch state {
        case .connected:
            EmptyView()
        case .connecting:
            banner("Connecting…", symbol: "antenna.radiowaves.left.and.right", color: Theme.warning)
        case .reconnecting:
            banner("Reconnecting — the clock keeps running", symbol: "wifi.exclamationmark", color: Theme.warning)
        case .lost(let reason):
            banner(reason, symbol: "wifi.slash", color: Theme.wrong)
        }
    }

    private func banner(_ text: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(text).lineLimit(2)
        }
        .font(.label(.footnote))
        .foregroundStyle(Theme.onVolt)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(color))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - QR code

struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                .accessibilityLabel("QR code to join this room")
        }
    }

    static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Celebration

/// A short burst of geometric confetti. Disabled when Reduce Motion is on.
struct ConfettiBurst: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    private struct Piece {
        let x: Double, speed: Double, drift: Double, spin: Double, size: Double, color: Color, square: Bool
    }

    // Kept in @State so the pieces don't re-randomise when the parent re-renders.
    @State private var pieces: [Piece] = ConfettiBurst.makePieces()

    private static func makePieces() -> [Piece] {
        let colors = Theme.teamColors + [Theme.volt, Theme.correct]
        return (0..<70).map { i in
            Piece(x: Double.random(in: 0...1), speed: Double.random(in: 180...420), drift: Double.random(in: -60...60),
                  spin: Double.random(in: -6...6), size: Double.random(in: 6...12),
                  color: colors[i % colors.count], square: i % 3 == 0)
        }
    }

    var body: some View {
        if reduceMotion {
            EmptyView()
        } else {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSince(start)
                Canvas { context, size in
                    guard t < 3.2 else { return }
                    for p in pieces {
                        let y = -20 + p.speed * t + 90 * t * t
                        let x = p.x * size.width + p.drift * t
                        var ctx = context
                        ctx.translateBy(x: x, y: y)
                        ctx.rotate(by: .radians(p.spin * t))
                        let rect = CGRect(x: -p.size / 2, y: -p.size / 4, width: p.size, height: p.size / 2)
                        ctx.opacity = max(0, 1 - t / 3.2)
                        ctx.fill(p.square ? Path(rect) : Path(ellipseIn: rect), with: .color(p.color))
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Formatting

enum Format {
    static func points(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    static func seconds(_ ms: Int?) -> String {
        guard let ms else { return "—" }
        return String(format: "%.1fs", Double(ms) / 1000)
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 10, n % 100) {
        case (_, 11...13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }
}
