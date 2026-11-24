import SwiftUI

struct AuthScriptEditor: View {
    @Binding var auth: RequestAuthentication

    private var source: Binding<String> {
        Binding(get: { auth.script ?? AuthScript.example }, set: { auth.script = $0 })
    }

    private var inputs: Binding<[RequestField]> {
        Binding(get: { auth.scriptInputs ?? [] }, set: { auth.scriptInputs = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("脚本输入")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    auth.scriptInputs = inputs.wrappedValue + [RequestField()]
                } label: {
                    Label("添加输入", systemImage: "plus")
                }
                .buttonStyle(ConsoleButton())
            }
            ForEach(inputs) { $field in
                HStack(spacing: 6) {
                    TextField("名称", text: $field.name)
                        .requestInput()
                        .frame(width: 108)
                        .accessibilityLabel("输入名称")
                    SecureField("值", text: Binding(
                        get: { field.value ?? "" },
                        set: { field.value = $0 }
                    ))
                    .requestInput()
                    .accessibilityLabel("输入值")
                    Button {
                        let id = field.id
                        auth.scriptInputs?.removeAll { $0.id == id }
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 24, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Console.muted)
                    .accessibilityLabel("移除输入")
                }
            }
            Text("JavaScript")
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 2)
            TextEditor(text: source)
                .font(Console.mono)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("认证生成脚本")
                .padding(5)
                .frame(height: 138)
                .consoleSurface(Console.input, radius: 6)
            Text("读取 inputs、request 和 timestamp，返回 headers、query 或 body。")
                .font(.system(size: 11))
                .foregroundStyle(Console.muted)
        }
    }
}
