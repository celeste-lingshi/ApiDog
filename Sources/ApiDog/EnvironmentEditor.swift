import SwiftUI

struct EnvironmentEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var environments: [RequestEnvironment]
    @State private var selectedID: UUID?
    let save: ([RequestEnvironment]) -> Void

    init(
        environments: [RequestEnvironment],
        selected: UUID?,
        save: @escaping ([RequestEnvironment]) -> Void
    ) {
        _environments = State(initialValue: environments)
        _selectedID = State(initialValue: selected ?? environments.first?.id)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("环境变量").font(.title3.weight(.semibold))

            HStack {
                Picker("编辑环境", selection: $selectedID) {
                    ForEach(environments) { environment in
                        Text(environment.name.isEmpty ? "未命名环境" : environment.name)
                            .tag(Optional(environment.id))
                    }
                }
                Button {
                    let environment = RequestEnvironment(name: "新环境")
                    environments.append(environment)
                    selectedID = environment.id
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加环境")
                .help("添加环境")
                Button {
                    environments.removeAll { $0.id == selectedID }
                    selectedID = environments.first?.id
                } label: {
                    Image(systemName: "minus")
                }
                .accessibilityLabel("移除当前环境")
                .help("移除当前环境")
                .disabled(environments.count < 2)
            }

            if let index = environments.firstIndex(where: { $0.id == selectedID }) {
                TextField("环境名称", text: $environments[index].name)
                    .accessibilityLabel("环境名称")

                Divider()

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($environments[index].variables) { $variable in
                            HStack {
                                TextField("名称，例如 baseUrl", text: $variable.name)
                                    .accessibilityLabel("变量名")
                                    .frame(width: 155)
                                if variable.sessionOnly {
                                    SecureField("临时值", text: $variable.value)
                                        .accessibilityLabel("临时变量值")
                                } else {
                                    TextField("值", text: $variable.value)
                                        .accessibilityLabel("变量值")
                                }
                                Toggle("仅本次运行", isOn: $variable.sessionOnly)
                                    .help("值在退出后清空，变量名称会保留。")
                                Button {
                                    let id = variable.id
                                    environments[index].variables.removeAll { $0.id == id }
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("移除变量")
                            }
                        }
                    }
                    .padding(2)
                }
                .frame(height: 170)
                .id(selectedID)

                Button {
                    environments[index].variables.append(EnvironmentVariable())
                } label: {
                    Label("添加变量", systemImage: "plus")
                }
            }

            Text("在请求中输入 {{变量名}}。名称可用英文字母、数字、下划线、点和连字符，开头须为字母或下划线。")
                .font(.callout)
                .foregroundStyle(.secondary)

            if !environments.allSatisfy(\.isValid) {
                Text("环境名称不能为空，同一环境内的变量名称必须有效且不能重复。")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    save(environments)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!environments.allSatisfy(\.isValid))
            }
        }
        .padding(22)
        .frame(width: 620)
    }
}
