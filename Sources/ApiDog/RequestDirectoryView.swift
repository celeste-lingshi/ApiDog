import SwiftUI

private struct RequestFolderFrames: PreferenceKey {
    static let defaultValue: [UUID?: CGRect] = [:]

    static func reduce(value: inout [UUID?: CGRect], nextValue: () -> [UUID?: CGRect]) {
        value.merge(nextValue()) { _, next in next }
    }
}

struct RequestDirectoryView: View {
    let directory: RequestDirectory
    let selectedID: UUID?
    @Binding var collapsed: Set<UUID>
    let select: (SavedRequest) -> Void
    let duplicate: (SavedRequest) -> Void
    let remove: (SavedRequest) -> Void
    let move: (UUID, UUID?) -> Bool
    @State private var folderFrames: [UUID?: CGRect] = [:]
    @GestureState private var drag: Drag?

    private struct Drag {
        let requestID: UUID
        let location: CGPoint
    }

    private static let coordinateSpace = "request-directory"

    var body: some View {
        if directory.categories.isEmpty && directory.requests.isEmpty {
            Text("可新建分类，或把当前请求保存到目录。")
                .font(.system(size: 12))
                .foregroundStyle(Console.muted)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        } else {
            GeometryReader { viewport in
                let bounds = CGRect(origin: .zero, size: viewport.size)
                let hoveredFolder = drag.flatMap { target(at: $0.location, within: bounds) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(directory.categories) { category in
                            let closed = collapsed.contains(category.id)
                            folder(name: category.name, id: category.id, closed: closed,
                                   targeted: hoveredFolder.map { $0.key == category.id } ?? false) {
                                if closed {
                                    collapsed.remove(category.id)
                                } else {
                                    collapsed.insert(category.id)
                                }
                            }

                            if !closed {
                                ForEach(directory.requests(in: category.id)) { request in
                                    row(request, within: bounds)
                                        .padding(.leading, 14)
                                }
                            }
                        }

                        folder(name: "未分类", id: nil, targeted: hoveredFolder.map { $0.key == nil } ?? false)
                        ForEach(directory.requests(in: nil)) { request in
                            row(request, within: bounds)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
                .coordinateSpace(name: Self.coordinateSpace)
                .onPreferenceChange(RequestFolderFrames.self) { folderFrames = $0 }
            }
        }
    }

    private func target(at location: CGPoint, within bounds: CGRect) -> (key: UUID?, value: CGRect)? {
        guard bounds.contains(location) else { return nil }
        return folderFrames.first { $0.value.contains(location) }
    }

    private func folder(name: String, id: UUID?, closed: Bool = false, targeted: Bool,
                        toggle: (() -> Void)? = nil) -> some View {
        RequestFolderRow(name: name, closed: closed, isDropTarget: targeted, toggle: toggle)
            .background {
                GeometryReader { row in
                    Color.clear.preference(key: RequestFolderFrames.self,
                                           value: [id: row.frame(in: .named(Self.coordinateSpace))])
                }
            }
    }

    private func row(_ request: SavedRequest, within bounds: CGRect) -> some View {
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
            .opacity(drag?.requestID == request.id ? 0.55 : 1)
            .simultaneousGesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.coordinateSpace))
                    .updating($drag) { value, state, _ in
                        state = Drag(requestID: request.id, location: value.location)
                    }
                    .onEnded { value in
                        if let destination = target(at: value.location, within: bounds) {
                            _ = move(request.id, destination.key)
                        }
                    }
            )

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

            Button {
                remove(request)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(Console.red)
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("删除请求")
            .accessibilityLabel("删除请求「\(request.name)」")
        }
        .consoleSurface(selected ? Console.selected : .clear,
                        border: selected ? Console.accent.opacity(0.26) : .clear, radius: 6)
    }
}

private struct RequestFolderRow: View {
    let name: String
    let closed: Bool
    let isDropTarget: Bool
    var toggle: (() -> Void)?

    var body: some View {
        Group {
            if let toggle {
                Button(action: toggle) { label }
                    .buttonStyle(.plain)
                    .accessibilityValue(closed ? "已折叠" : "已展开")
            } else {
                label
            }
        }
    }

    private var label: some View {
        HStack(spacing: 7) {
            if toggle != nil {
                Image(systemName: closed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 10)
                    .accessibilityHidden(true)
                Image(systemName: closed ? "folder" : "folder.fill")
                    .foregroundStyle(Console.accent)
                    .accessibilityHidden(true)
            }
            Text(name)
                .foregroundStyle(toggle == nil ? Console.muted : Console.text)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 8)
        .frame(height: 32)
        .consoleSurface(isDropTarget ? Console.selected : .clear,
                        border: isDropTarget ? Console.accent : .clear, radius: 6)
        .contentShape(Rectangle())
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
