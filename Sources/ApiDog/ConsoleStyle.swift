import AppKit
import SwiftUI

enum ConsoleTheme: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum Console {
    static let header = rgb(0x161C26, light: 0xF8FAFC)
    static let canvas = rgb(0x11151D, light: 0xEFF3F7)
    static let sidebar = rgb(0x0C1017, light: 0xE6EDF4)
    static let panel = rgb(0x171D27, light: 0xFFFFFF)
    static let input = rgb(0x10151E, light: 0xF3F6FA)
    static let line = rgb(0x2B3646, light: 0xCBD6E2)
    static let selected = rgb(0x20362F, light: 0xDDF2EB)
    static let text = rgb(0xE9EEF5, light: 0x172433)
    static let muted = rgb(0x9CAABC, light: 0x536477)
    static let accent = rgb(0x77E8C9, light: 0x006B55)
    static let blue = rgb(0x89B6FF, light: 0x245FA9)
    static let amber = rgb(0xF3C677, light: 0x815500)
    static let red = rgb(0xFF929D, light: 0xA52F41)
    static let purple = rgb(0xC5ADFB, light: 0x6341A0)
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

    private static func rgb(_ dark: UInt32, light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
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
