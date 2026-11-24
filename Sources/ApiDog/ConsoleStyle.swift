import SwiftUI

enum Console {
    static let header = rgb(0x161C26)
    static let canvas = rgb(0x11151D)
    static let sidebar = rgb(0x0C1017)
    static let panel = rgb(0x171D27)
    static let input = rgb(0x10151E)
    static let line = rgb(0x2B3646)
    static let selected = rgb(0x20362F)
    static let text = rgb(0xE9EEF5)
    static let muted = rgb(0x9CAABC)
    static let accent = rgb(0x77E8C9)
    static let blue = rgb(0x89B6FF)
    static let amber = rgb(0xF3C677)
    static let red = rgb(0xFF929D)
    static let purple = rgb(0xC5ADFB)
    static let mono = Font.system(size: 12, design: .monospaced)

    static func method(_ method: HTTPMethod) -> Color {
        switch method {
        case .get, .head: return accent
        case .post: return blue
        case .put, .patch: return amber
        case .delete: return red
        case .options: return purple
        }
    }

    static func status(_ code: Int?) -> Color {
        guard let code else { return red }
        switch code {
        case 200..<300: return accent
        case 300..<400: return amber
        case 400..<600: return red
        default: return muted
        }
    }

    private static func rgb(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 255) / 255,
            green: Double((value >> 8) & 255) / 255,
            blue: Double(value & 255) / 255
        )
    }
}

extension View {
    func consoleSurface(_ fill: Color = Console.panel, border: Color = Console.line, radius: CGFloat = 10) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        return background(fill, in: shape)
            .overlay { shape.strokeBorder(border).allowsHitTesting(false) }
    }
}

struct ConsoleButton: ButtonStyle {
    var prominent = false
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let tone = destructive ? Console.red : Console.accent
        return configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Console.sidebar : Console.text)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .consoleSurface(prominent ? tone : Console.panel,
                            border: prominent ? .clear : Console.line, radius: 7)
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(isEnabled ? (configuration.isPressed ? 0.74 : 1) : 0.42)
    }
}

struct ConsoleTabs<Tab: Hashable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String

    var body: some View {
        HStack(spacing: 16) {
            ForEach(tabs, id: \.self) { tab in
                let selected = tab == selection
                Button {
                    selection = tab
                } label: {
                    Text(title(tab))
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Console.accent : Console.muted)
                        .frame(height: 36)
                        .overlay(alignment: .bottom) {
                            if selected { Rectangle().fill(Console.accent).frame(height: 2) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

struct ConsoleRule: View {
    var vertical = false

    var body: some View {
        Rectangle().fill(Console.line)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .accessibilityHidden(true)
    }
}

struct ConsoleCheckbox: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isOn ? Console.accent : Console.input)
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(configuration.isOn ? Console.accent : Console.muted, lineWidth: 1)
                if configuration.isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Console.sidebar)
                }
            }
            .frame(width: 16, height: 16)
            .frame(width: 36, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.automatic)
        }
    }
}

struct ConsoleProgress: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            Circle().strokeBorder(Console.line, lineWidth: 2)
                .overlay {
                    Circle().trim(from: 0.02, to: 0.30)
                        .stroke(Console.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .padding(1)
                        .rotationEffect(.degrees(reduceMotion ? 0 : phase * 360))
                }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

struct ConsoleModal<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .accessibilityHidden(true)
            content
                .consoleSurface(Console.panel, radius: 13)
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .shadow(color: .black.opacity(0.55), radius: 24, y: 12)
                .accessibilityAddTraits(.isModal)
        }
    }
}
