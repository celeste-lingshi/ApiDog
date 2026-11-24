import AppKit
import SwiftUI

struct ConsoleTitleBar<Actions: View>: View {
    @ViewBuilder let actions: Actions
    @StateObject private var handle = ConsoleWindowHandle()
    @State private var fullScreen = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                WindowDragArea(handle: handle)
                    .overlay(alignment: .leading) {
                        wordmark.allowsHitTesting(false)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                actions
                ConsoleRule(vertical: true)
                    .frame(height: 20)
                    .padding(.horizontal, 2)
                HStack(spacing: 4) {
                    WindowAction(label: "最小化窗口", icon: "minus") {
                        handle.window?.miniaturize(nil)
                    }
                    WindowAction(label: fullScreen ? "退出全屏" : "进入全屏",
                                 icon: fullScreen ? "arrow.down.right.and.arrow.up.left"
                                                  : "arrow.up.left.and.arrow.down.right") {
                        handle.window?.toggleFullScreen(nil)
                    }
                    WindowAction(label: "关闭窗口", icon: "xmark", destructive: true) {
                        handle.window?.performClose(nil)
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(Console.header)
            ConsoleRule()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { event in
            guard let window = event.object as? NSWindow, window === handle.window else { return }
            fullScreen = true
            handle.hideSystemTitleBar(in: window)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { event in
            guard let window = event.object as? NSWindow, window === handle.window else { return }
            fullScreen = false
            handle.hideSystemTitleBar(in: window)
        }
    }

    private var wordmark: some View {
        HStack(spacing: 8) {
            Group {
                if let icon = Bundle.main.image(forResource: "ApiDog") {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Console.accent)
                        .frame(width: 30, height: 30)
                        .consoleSurface(Console.accent.opacity(0.10), border: Console.accent.opacity(0.24), radius: 8)
                }
            }
            .frame(width: 42, height: 42)
            .accessibilityHidden(true)
            Text("ApiDog")
                .font(.system(size: 17, weight: .semibold))
                .tracking(-0.4)
        }
    }
}

private struct WindowAction: View {
    let label: String
    let icon: String
    var destructive = false
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        let active = hovered || focused
        let tone = destructive ? Console.red : Console.text
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? tone : Console.muted)
                .frame(width: 32, height: 32)
                .consoleSurface(active ? tone.opacity(0.12) : .clear,
                                border: focused ? Console.accent : .clear, radius: 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focused)
        .onHover { hovered = $0 }
        .accessibilityLabel(label)
    }
}

private final class ConsoleWindowHandle: ObservableObject {
    weak var window: NSWindow?

    func hideSystemTitleBar(in window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
    }
}

private struct WindowDragArea: NSViewRepresentable {
    let handle: ConsoleWindowHandle

    func makeNSView(context: Context) -> DragView {
        DragView(handle: handle)
    }

    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        let handle: ConsoleWindowHandle

        init(handle: ConsoleWindowHandle) {
            self.handle = handle
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            handle.window = window
            if let window { handle.hideSystemTitleBar(in: window) }
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}
