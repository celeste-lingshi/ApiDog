import SwiftUI

struct ClearHistoryDialog: View {
    let cancel: () -> Void
    let confirm: () -> Void
    @FocusState private var cancelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Console.red)
                    .frame(width: 36, height: 36)
                    .consoleSurface(Console.red.opacity(0.10), border: Console.red.opacity(0.28), radius: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("清空全部请求历史？")
                        .font(.system(size: 17, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("历史请求将被删除，已保存的环境变量会保留。")
                        .font(.system(size: 13))
                        .foregroundStyle(Console.muted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ConsoleRule()
            HStack(spacing: 8) {
                Spacer()
                Button("取消", action: cancel)
                    .buttonStyle(ConsoleButton())
                    .focusable()
                    .focused($cancelFocused)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(cancelFocused ? Console.accent : .clear)
                            .allowsHitTesting(false)
                    }
                    .keyboardShortcut(.defaultAction)
                Button("清空历史", action: confirm)
                    .buttonStyle(ConsoleButton(prominent: true, destructive: true))
            }
        }
        .padding(18)
        .frame(width: 390)
        .foregroundStyle(Console.text)
        .onAppear { cancelFocused = true }
    }
}
