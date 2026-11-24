import SwiftUI

struct RequestDirectoryView: View {
    let directory: RequestDirectory
    let selectedID: UUID?
    @Binding var collapsed: Set<UUID>
    let select: (SavedRequest) -> Void
    let duplicate: (SavedRequest) -> Void

    var body: some View {
        if directory.categories.isEmpty && directory.requests.isEmpty {
            Text("可新建分类，或把当前请求保存到目录。")
                .font(.system(size: 12))
                .foregroundStyle(Console.muted)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(directory.categories) { category in
                        let closed = collapsed.contains(category.id)
                        Button {
                            if closed {
                                collapsed.remove(category.id)
                            } else {
                                collapsed.insert(category.id)
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: closed ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                                    .frame(width: 10)
                                    .accessibilityHidden(true)
                                Image(systemName: closed ? "folder" : "folder.fill")
                                    .foregroundStyle(Console.accent)
                                    .accessibilityHidden(true)
                                Text(category.name)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 8)
                            .frame(height: 32)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(closed ? "已折叠" : "已展开")

                        if !closed {
                            ForEach(directory.requests(in: category.id)) { request in
                                row(request)
                                    .padding(.leading, 14)
                            }
                        }
                    }

                    let root = directory.requests(in: nil)
                    if !root.isEmpty {
                        Text("未分类")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Console.muted)
                            .padding(.horizontal, 8)
                            .padding(.top, 6)
                        ForEach(root) { request in
                            row(request)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
    }

    private func row(_ request: SavedRequest) -> some View {
        let selected = request.id == selectedID
        return HStack(spacing: 2) {
            Button {
                select(request)
            } label: {
                HStack(spacing: 7) {
                    Text(request.draft.method.rawValue)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Console.method(request.draft.method))
                        .frame(width: 41, alignment: .leading)
                    Text(request.name)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 8)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(request.draft.url.isEmpty ? request.name : request.draft.url)
            .accessibilityAddTraits(selected ? .isSelected : [])

            Button {
                duplicate(request)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Console.accent : Console.muted)
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("复制请求")
            .accessibilityLabel("复制请求「\(request.name)」")
        }
        .consoleSurface(selected ? Console.selected : .clear,
                        border: selected ? Console.accent.opacity(0.26) : .clear, radius: 6)
    }
}

struct RequestMetadataDialog: View {
    let title: String
    let categories: [RequestCategory]?
    let existingCategoryNames: [String]
    let cancel: () -> Void
    let confirm: (String, UUID?) -> Void
    @State private var name: String
    @State private var categoryID: UUID?
    @FocusState private var nameFocused: Bool

    init(title: String, name: String = "", categories: [RequestCategory]? = nil, categoryID: UUID? = nil,
         existingCategoryNames: [String] = [], cancel: @escaping () -> Void, confirm: @escaping (String, UUID?) -> Void) {
        self.title = title
        self.categories = categories
        self.existingCategoryNames = existingCategoryNames
        self.cancel = cancel
        self.confirm = confirm
        _name = State(initialValue: name)
        _categoryID = State(initialValue: categoryID)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var duplicate: Bool {
        existingCategoryNames.contains { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            TextField(categories == nil ? "分类名称" : "请求名称", text: $name)
                .requestInput()
                .focused($nameFocused)
                .help("名称")
            if let categories {
                Text("分类")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Console.muted)
                ScrollView {
                    VStack(spacing: 3) {
                        categoryRow("未分类", id: nil)
                        ForEach(categories) { category in
                            categoryRow(category.name, id: category.id)
                        }
                    }
                    .padding(4)
                }
                .frame(height: CGFloat(min(categories.count + 1, 5)) * 31 + 8)
                .consoleSurface(Console.input, radius: 7)
            }
            if duplicate {
                Text("已有同名分类。")
                    .font(.system(size: 12))
                    .foregroundStyle(Console.amber)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("取消", action: cancel)
                    .buttonStyle(ConsoleButton())
                    .keyboardShortcut(.cancelAction)
                Button("保存") { confirm(trimmed, categoryID) }
                    .buttonStyle(ConsoleButton(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || duplicate)
            }
        }
        .padding(18)
        .frame(width: 405)
        .foregroundStyle(Console.text)
        .onAppear { nameFocused = true }
    }

    private func categoryRow(_ name: String, id: UUID?) -> some View {
        let selected = categoryID == id
        return Button {
            categoryID = id
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .accessibilityHidden(true)
                Text(name).lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").accessibilityHidden(true)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(selected ? Console.accent : Console.text)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .consoleSurface(selected ? Console.selected : .clear, border: .clear, radius: 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
