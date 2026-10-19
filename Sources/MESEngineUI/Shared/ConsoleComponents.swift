import DesignScaffold
import SwiftUI

// The console's building blocks: a page with a title, panels, info cards and rows, legends and pills. Their layout comes
// from Nativ's System monitor (MIT, see THIRD-PARTY-NOTICES.md); their values come from DesignScaffold's tokens.

/// Series and accent colours for charts and metric tiles. DesignScaffold has no chart palette yet, so these are the
/// system colours (they follow light, dark and Increase Contrast), named by role.
enum ConsolePalette {
    static let cpu = Color.blue
    static let gpu = Color.purple
    static let memory = Color.green
    static let disk = Color.orange
    static let neural = Color.orange
    static let read = Color.blue
    static let write = Color.red
    static let heat = Color.red
    static let power = Color.orange
    static let cooling = Color.teal
    static let swap = Color.purple
    static let idle = Color.secondary.opacity(0.45)
    static let track = Color.secondary.opacity(0.18)
}

/// The text a missing reading shows.
let missingValue = "—"

/// A scrolling page: title and subtitle, then content, centred up to a readable width.
struct ConsolePage<Trailing: View, Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.l) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(Tokens.Font.panelTitle)
                        Text(subtitle).font(Tokens.Font.body).foregroundStyle(Tokens.Color.secondaryLabel)
                    }
                    Spacer()
                    trailing
                }
                content
            }
            .padding(.horizontal, Tokens.Space.xl)
            .padding(.vertical, Tokens.Space.xl)
            .frame(maxWidth: 1500, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

/// The bar under a section's header that picks a page, as Nativ's System view does.
struct ConsoleTabBar<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    let symbol: (Tab) -> String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Tokens.Space.xs) {
                ForEach(tabs) { tab in
                    let selected = tab == selection
                    Button {
                        withAnimation(.snappy(duration: 0.18)) { selection = tab }
                    } label: {
                        Label(title(tab), systemImage: symbol(tab))
                            .font(Tokens.Font.body.weight(.medium))
                            .padding(.horizontal, Tokens.Space.m)
                            .frame(height: 28)
                            .foregroundStyle(selected ? Color.white : Tokens.Color.label)
                            .background(selected ? Tokens.Color.accent : Color.clear,
                                        in: RoundedRectangle(cornerRadius: Tokens.Radius.control + 2, style: .continuous))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, Tokens.Space.xl)
            .padding(.vertical, Tokens.Space.s)
        }
    }
}

/// A full-width card.
struct ConsolePanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Tokens.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
    }
}

/// A headline number in a tinted tile: CPU 11%, 18 cores.
struct MetricBadge: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: Tokens.Space.m) {
            IconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Tokens.Font.caption.weight(.medium)).foregroundStyle(Tokens.Color.secondaryLabel)
                Text(value).font(Tokens.Font.panelTitle.monospacedDigit())
                Text(detail).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel).lineLimit(1)
            }
        }
        .padding(Tokens.Space.m + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }
}

/// An SF Symbol on a soft tint.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 38

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Tokens.Radius.container - 2, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A titled card of rows.
struct InfoCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            Text(title).font(Tokens.Font.headline)
            VStack(spacing: 0) { content }
        }
        .padding(Tokens.Space.l)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .cardSurface()
    }
}

/// A label and its value, with a hairline under it.
struct InfoRow: View {
    let title: String
    let value: String
    var color: Color?

    init(_ title: String, value: String, color: Color? = nil) {
        self.title = title
        self.value = value
        self.color = color
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.l) {
            if let color {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            }
            Text(title).foregroundStyle(Tokens.Color.secondaryLabel)
            Spacer(minLength: Tokens.Space.l)
            Text(value)
                .fontWeight(.medium)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(Tokens.Font.body)
        .padding(.vertical, Tokens.Space.s)
        .overlay(alignment: .bottom) { Separator(.horizontal) }
    }
}

/// A colour swatch, a label and a value, for the key under a bar.
struct LegendItem: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(title).foregroundStyle(Tokens.Color.secondaryLabel)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .font(Tokens.Font.caption)
    }
}

/// A small capsule: an operation, a tier, a licence class.
struct Pill: View {
    let text: String
    var symbol: String?
    var tint: Color = Tokens.Color.secondaryLabel

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(Tokens.Font.caption.weight(.medium))
        .fixedSize()
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Two views side by side when they fit, stacked when they don't.
struct AdaptivePair<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Tokens.Space.m + 2) {
                leading.frame(maxWidth: .infinity)
                trailing.frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: Tokens.Space.m + 2) {
                leading
                trailing
            }
        }
    }
}

/// A stacked bar of fractions, for CPU (system, user) and memory (active, wired, compressed).
struct SegmentedBar: View {
    let segments: [(fraction: Double, color: Color)]

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle().fill(segment.color)
                        .frame(width: geometry.size.width * min(max(segment.fraction, 0), 1))
                }
                Rectangle().fill(ConsolePalette.track)
            }
            .clipShape(.rect(cornerRadius: 4))
        }
        .frame(height: 13)
    }
}

/// An empty state: a symbol, a line and a hint.
struct ConsoleEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Tokens.Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Tokens.Color.tertiaryLabel)
            Text(title).font(Tokens.Font.headline)
            Text(message)
                .font(Tokens.Font.body)
                .foregroundStyle(Tokens.Color.secondaryLabel)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.Space.xl)
    }
}

/// Formatting shared by the console's pages.
enum ConsoleFormat {
    static func percent(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(0))) }

    static func percent(_ value: Double?) -> String { value.map { percent($0) } ?? missingValue }

    static func bytes(_ value: UInt64) -> String { Int64(clamping: value).formatted(.byteCount(style: .file)) }

    static func memory(_ value: UInt64) -> String { Int64(clamping: value).formatted(.byteCount(style: .memory)) }

    static func memory(_ value: UInt64?) -> String { value.map { memory($0) } ?? missingValue }

    static func byteRate(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return missingValue }
        return "\(bytes(UInt64(value.rounded())))/s"
    }

    static func framesPerSecond(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return missingValue }
        return "\(Int(value.rounded()).formatted()) FPS"
    }

    static func celsius(_ value: Double?) -> String {
        guard let value, value.isFinite else { return missingValue }
        return value.formatted(.number.precision(.fractionLength(1))) + "°C"
    }

    static func watts(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return missingValue }
        return value.formatted(.number.precision(.fractionLength(value < 10 ? 2 : 1))) + " W"
    }

    static func rpm(_ value: Int?) -> String { value.map { "\($0.formatted()) RPM" } ?? missingValue }

    static func uptime(_ interval: TimeInterval) -> String {
        Duration.seconds(max(interval, 0)).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated,
                                                            maximumUnitCount: 2))
    }

    static func boolean(_ value: Bool?) -> String { value.map { $0 ? "Yes" : "No" } ?? missingValue }

    /// 4 s, 1 min 12 s, 2 h 5 min.
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(seconds, 0)
        if s < 1 { return s.formatted(.number.precision(.fractionLength(1))) + " s" }
        return Duration.seconds(s.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated,
                                                              maximumUnitCount: 2))
    }
}

/// The header at the top of a console section: its name, a line about it, and its controls.
struct ConsoleSectionHeader<Controls: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var controls: Controls

    var body: some View {
        HStack(spacing: Tokens.Space.m) {
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                Text(title).font(Tokens.Font.panelTitle)
                Text(subtitle).font(Tokens.Font.body).foregroundStyle(Tokens.Color.secondaryLabel)
            }
            Spacer()
            controls
        }
        .padding(.horizontal, Tokens.Space.xl)
        .padding(.top, Tokens.Space.m)
        .padding(.bottom, Tokens.Space.m)
    }
}
