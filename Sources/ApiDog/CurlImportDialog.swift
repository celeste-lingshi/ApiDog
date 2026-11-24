import SwiftUI

struct CurlImportDialog: View {
    let cancel: () -> Void
    let accept: (RequestDraft) -> Void
    @State private var command = ""
    @State private var issue: String?
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("导入 cURL", systemImage: "terminal")
                .font(.system(size: 17, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("粘贴 cURL 命令或带变量、OpenSSL 签名和 jq 提取的命令。导入后会替换当前请求。")
                .font(.system(size: 12))
                .foregroundStyle(Console.muted)

            TextEditor(text: $command)
                .font(Console.mono)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .accessibilityLabel("cURL 命令")
                .padding(8)
                .frame(height: 190)
                .consoleSurface(Console.input, border: editorFocused ? Console.accent : Console.line, radius: 8)

            if let issue {
                Label(issue, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Console.amber)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("取消", action: cancel)
                    .buttonStyle(ConsoleButton())
                    .keyboardShortcut(.cancelAction)
                Button("拆分并导入") {
                    do {
                        accept(try CurlCommand.parse(command))
                    } catch {
                        issue = error.localizedDescription
                    }
                }
                .buttonStyle(ConsoleButton(prominent: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 610)
        .foregroundStyle(Console.text)
        .onAppear { editorFocused = true }
        .onChange(of: command) { _ in issue = nil }
    }
}
