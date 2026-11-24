import SwiftUI

enum Console {
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
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Console.sidebar : Console.text)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .consoleSurface(prominent ? Console.accent : Console.panel,
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
