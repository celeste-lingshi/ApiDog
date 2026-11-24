import SwiftUI

struct RequestFieldsEditor: View {
    @Binding var fields: [RequestField]
    var header: Bool
    var generated: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !header {
                Text("这些参数会追加到 URL 的 ? 后面。")
                    .font(.system(size: 12))
                    .foregroundStyle(Console.muted)
            }
            HStack {
                Text("名称").frame(width: 116, alignment: .leading)
                Text("值")
                Spacer()
                Button {
                    fields.append(RequestField())
                } label: {
                    Label(header ? "请求头" : "参数", systemImage: "plus")
                }
                .buttonStyle(ConsoleButton())
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Console.muted)

            if !generated.isEmpty {
                Text("认证自动添加  \(generated.joined(separator: "、"))")
                    .font(.system(size: 11))
                    .foregroundStyle(Console.muted)
            }

            if fields.isEmpty {
                Text(header ? "通过「＋ 请求头」添加 Content-Type 等字段。" : "可用「＋ 参数」添加一行。")
                    .font(.system(size: 12))
                    .foregroundStyle(Console.muted)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach($fields) { $field in
                                HStack(spacing: 6) {
                                    TextField(header ? "Content-Type" : "limit", text: $field.name)
                                        .requestInput()
                                        .frame(width: 116)
                                        .accessibilityLabel("名称")
                                    TextField(header ? "application/json" : "20", text: Binding(
                                        get: { field.value ?? "" },
                                        set: { field.value = $0 }
                                    ))
                                    .requestInput()
                                    .accessibilityLabel("值")
                                    Button {
                                        let id = field.id
                                        fields.removeAll { $0.id == id }
                                    } label: {
                                        Image(systemName: "xmark")
                                            .frame(width: 24, height: 28)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Console.muted)
                                    .accessibilityLabel("移除此行")
                                }
                                .id(field.id)
                            }
                        }
                    }
                    .onChange(of: fields.last?.id) { id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }
}

struct RequestVariablesEditor: View {
    let names: [String]
    @Binding var values: [String: String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                if names.isEmpty {
                    Text("在 URL 中输入 {hostname}，这里会出现对应的输入框。")
                        .font(.system(size: 12))
                        .foregroundStyle(Console.muted)
                }
                ForEach(names, id: \.self) { name in
                    HStack(spacing: 8) {
                        Text(name)
                            .font(Console.mono)
                            .foregroundStyle(Console.accent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 116, alignment: .leading)
                            .help(name)
                        TextField("输入变量值", text: Binding(
                            get: { values[name, default: ""] },
                            set: { values[name] = $0 }
                        ))
                        .requestInput()
                        .accessibilityLabel(name)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }
}

extension View {
    func requestInput() -> some View {
        textFieldStyle(.plain)
            .font(Console.mono)
            .foregroundStyle(Console.text)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .consoleSurface(Console.input, radius: 6)
    }
}
