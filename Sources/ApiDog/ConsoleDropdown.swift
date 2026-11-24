import SwiftUI

enum WorkspaceDropdown: Hashable {
    case method, authentication, authLocation, history, directory, theme

    var width: CGFloat {
        switch self {
        case .method: return 144
        case .authentication, .authLocation: return 188
        case .history, .directory, .theme: return 166
        }
    }
}

struct DropdownAnchors: PreferenceKey {
    static var defaultValue: [WorkspaceDropdown: Anchor<CGRect>] { [:] }

    static func reduce(
        value: inout [WorkspaceDropdown: Anchor<CGRect>],
        nextValue: () -> [WorkspaceDropdown: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct DropdownOption {
    var title: String
    var icon: String?
    var tone: Color = Console.text
    var monospaced = false
    var selected = false
    var choose: (() -> Void)?
}

struct ConsoleDropdown: View {
    private static let rowHeight: CGFloat = 32
    private static let spacing: CGFloat = 2
    private static let inset: CGFloat = 5
    let options: [DropdownOption]
    let width: CGFloat
    let dismiss: () -> Void
    @FocusState private var focused: Int?
    @State private var hovered: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: Self.spacing) {
                    ForEach(options.indices, id: \.self) { index in
                        row(index)
                    }
                }
                .padding(Self.inset)
            }
            .scrollIndicators(options.count > 7 ? .automatic : .hidden)
            .onChange(of: focused) { index in
                if let index { proxy.scrollTo(index) }
            }
        }
        .frame(width: width, height: frameHeight)
        .consoleSurface(border: Console.line, radius: 9)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .shadow(color: .black.opacity(0.48), radius: 16, y: 7)
        .onAppear { focused = options.firstIndex(where: \.selected) ?? options.indices.first }
        .onExitCommand(perform: dismiss)
        .onMoveCommand { direction in
            guard let focused, direction == .up || direction == .down else { return }
            let next = focused + (direction == .up ? -1 : 1)
            if options.indices.contains(next) { self.focused = next }
        }
    }

    private var frameHeight: CGFloat {
        let rows = min(options.count, 7)
        return CGFloat(rows) * Self.rowHeight + CGFloat(max(0, rows - 1)) * Self.spacing + Self.inset * 2
    }

    private func row(_ index: Int) -> some View {
        let option = options[index]
        let highlighted = hovered == index || focused == index
        return Group {
            if let choose = option.choose {
                Button {
                    dismiss()
                    choose()
                } label: {
                    rowLabel(option, highlighted: highlighted)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(focused == index ? .defaultAction : nil)
            } else {
                rowLabel(option, highlighted: false)
            }
        }
        .focusable()
        .focused($focused, equals: index)
        .onHover { hovering in
            guard option.choose != nil else { return }
            if hovering {
                hovered = index
            } else if hovered == index {
                hovered = nil
            }
        }
        .accessibilityAddTraits(option.selected ? .isSelected : [])
    }

    private func rowLabel(_ option: DropdownOption, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            if option.monospaced {
                Circle().fill(option.tone).frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            if let icon = option.icon {
                Image(systemName: icon).frame(width: 14)
                    .accessibilityHidden(true)
            }
            Text(option.title)
                .font(.system(size: 12, weight: .semibold, design: option.monospaced ? .monospaced : .default))
                .lineLimit(1)
            Spacer(minLength: 4)
            if option.selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Console.accent)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(option.tone)
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .consoleSurface(
            option.selected ? Console.selected : (highlighted ? Console.line : .clear),
            border: highlighted ? Console.muted.opacity(0.40) : .clear,
            radius: 5
        )
        .contentShape(Rectangle())
    }
}
