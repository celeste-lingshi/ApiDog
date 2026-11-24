import SwiftUI

struct EnvironmentEditor: View {
    @State private var environments: [RequestEnvironment]
    @State private var selectedID: UUID?
    @FocusState private var nameFocused: Bool
    let cancel: () -> Void
    let save: ([RequestEnvironment]) -> Void

    init(
        environments: [RequestEnvironment],
        selected: UUID?,
        cancel: @escaping () -> Void,
        save: @escaping ([RequestEnvironment]) -> Void
    ) {
        _environments = State(initialValue: environments)
        _selectedID = State(initialValue: selected ?? environments.first?.id)
        self.cancel = cancel
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Console.accent)
                    .frame(width: 34, height: 34)
                    .consoleSurface(Console.accent.opacity(0.10), border: Console.accent.opacity(0.24), radius: 8)
                    .accessibilityHidden(true)
                Text("环境变量")
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(16)

            ConsoleRule()
            HStack(spacing: 0) {
                environmentList
                    .frame(width: 154)
                ConsoleRule(vertical: true)
                if let index = environments.firstIndex(where: { $0.id == selectedID }) {
                    environmentForm(index)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(height: 302)

            ConsoleRule()
            HStack(spacing: 8) {
                if !environments.allSatisfy(\.isValid) {
                    Text("请补齐环境名称，并检查变量名是否有效、是否重复。")
                        .font(.system(size: 12))
                        .foregroundStyle(Console.amber)
                }
                Spacer()
                Button("取消", action: cancel)
                    .buttonStyle(ConsoleButton())
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    save(environments)
                }
                .buttonStyle(ConsoleButton(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!environments.allSatisfy(\.isValid))
            }
            .padding(14)
        }
        .frame(width: 680)
        .foregroundStyle(Console.text)
        .background(Console.panel)
        .tint(Console.accent)
        .onAppear { nameFocused = true }
    }

    private var environmentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(environments) { environment in
                        let selected = environment.id == selectedID
                        Button {
                            selectedID = environment.id
                        } label: {
                            Label(environment.name.isEmpty ? "未命名环境" : environment.name,
                                  systemImage: "circle.grid.2x2")
                                .lineLimit(1)
                                .foregroundStyle(selected ? Console.accent : Console.text)
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                                .background(selected ? Console.selected : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }

            Button {
                let environment = RequestEnvironment(name: "新环境")
                environments.append(environment)
                selectedID = environment.id
                nameFocused = true
            } label: {
                Label("添加环境", systemImage: "plus")
            }
            .buttonStyle(ConsoleButton())
        }
        .padding(10)
        .frame(maxHeight: .infinity)
        .background(Console.sidebar)
    }

    private func environmentForm(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("名称").font(.system(size: 12, weight: .medium))
                input(TextField("环境名称", text: $environments[index].name)
                    .accessibilityLabel("环境名称")
                    .focused($nameFocused))
                Button {
                    environments.removeAll { $0.id == selectedID }
                    selectedID = environments.first?.id
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(ConsoleButton())
                .disabled(environments.count < 2)
                .accessibilityLabel("移除当前环境")
                .help("移除当前环境")
            }

            HStack(spacing: 7) {
                Text("变量名").frame(width: 125, alignment: .leading)
                Text("值").frame(maxWidth: .infinity, alignment: .leading)
                Text("仅本次运行").frame(width: 76)
                Color.clear.frame(width: 18, height: 1).accessibilityHidden(true)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Console.muted)
            .padding(.top, 4)

            if environments[index].variables.isEmpty {
                Text("为这个环境添加变量，例如 baseUrl。")
                    .font(.system(size: 12))
                    .foregroundStyle(Console.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .consoleSurface(Console.input)
            } else {
                ScrollView {
                    VStack(spacing: 7) {
                        ForEach($environments[index].variables) { $variable in
                            HStack(spacing: 7) {
                                input(TextField("baseUrl", text: $variable.name)
                                    .accessibilityLabel("变量名"))
                                    .frame(width: 125)
                                if variable.sessionOnly {
                                    input(SecureField("临时值", text: $variable.value)
                                        .accessibilityLabel("临时变量值"))
                                } else {
                                    input(TextField("变量值", text: $variable.value))
                                }
                                Toggle("仅本次运行", isOn: $variable.sessionOnly)
                                    .toggleStyle(ConsoleCheckbox())
                                    .labelsHidden()
                                    .accessibilityLabel("仅本次运行")
                                    .frame(width: 76)
                                    .help("值在退出后清空，变量名会保留。")
                                Button {
                                    let id = variable.id
                                    environments[index].variables.removeAll { $0.id == id }
                                } label: {
                                    Image(systemName: "xmark").frame(width: 18, height: 24)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("移除变量")
                            }
                        }
                    }
                }
                .id(selectedID)
                .frame(maxHeight: .infinity)
            }

            HStack(spacing: 12) {
                Button {
                    environments[index].variables.append(EnvironmentVariable())
                } label: {
                    Label("添加变量", systemImage: "plus")
                }
                .buttonStyle(ConsoleButton())
                Text("在请求里输入 {{变量名}} 引用。")
                    .font(.system(size: 11))
                    .foregroundStyle(Console.muted)
                    .help("变量名以英文字母或下划线开头，可包含数字、点和连字符。")
            }
        }
        .padding(14)
    }

    private func input(_ field: some View) -> some View {
        field
            .font(Console.mono)
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .consoleSurface(Console.input, radius: 6)
    }
}
