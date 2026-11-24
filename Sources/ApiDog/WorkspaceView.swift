import AppKit
import SwiftUI

struct WorkspaceView: View {
    @StateObject private var model = WorkspaceModel()
    @State private var draft = RequestDraft()
    @State private var requestTab = RequestTab.headers
    @State private var responseTab = ResponseTab.body
    @State private var result: ResponseDetails?
    @State private var error: String?
    @State private var activeHistory: HistoryEntry?
    @State private var requestTask: Task<Void, Never>?
    @State private var requestCancelled = false
    @State private var copiedTab: ResponseTab?
    @State private var historyQuery = ""
    @State private var showEnvironments = false
    @State private var showClearHistory = false
    @State private var dropdown: WorkspaceDropdown?
    @FocusState private var urlFocused: Bool

    private enum RequestTab: String, CaseIterable { case headers = "请求头", body = "请求体" }
    private enum ResponseTab: String, CaseIterable { case body = "正文", headers = "响应头" }

    private var isSending: Bool { requestTask != nil }
    private var hasAddress: Bool { !draft.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 244)
                Rectangle().fill(Console.line).frame(width: 1)
                mainPane
            }

            if let issue = model.storageIssue {
                Label(issue, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(Console.amber)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Console.panel)
            }
        }
        .frame(minWidth: 820, minHeight: 610)
        .foregroundStyle(Console.text)
        .background(Console.canvas)
        .tint(Console.accent)
        .accessibilityHidden(dropdown != nil)
        .overlayPreferenceValue(DropdownAnchors.self) { anchors in
            GeometryReader { geometry in
                if let dropdown, let anchor = anchors[dropdown] {
                    let trigger = geometry[anchor]
                    let left = dropdown == .method ? trigger.minX : trigger.maxX - dropdown.width
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { self.dropdown = nil }
                        .accessibilityHidden(true)
                    ConsoleDropdown(options: dropdownOptions(dropdown), width: dropdown.width) {
                        self.dropdown = nil
                    }
                    .id(dropdown)
                    .offset(x: max(8, left), y: trigger.maxY + 6)
                }
            }
        }
        .onAppear { urlFocused = true }
        .sheet(isPresented: $showEnvironments) {
            EnvironmentEditor(
                environments: model.workspace.environments,
                selected: model.workspace.selectedEnvironment?.id
            ) { environments in
                model.workspace.environments = environments
                model.workspace.selectedEnvironmentID = model.workspace.selectedEnvironment?.id
                model.save()
            }
        }
        .alert("清空全部请求历史？", isPresented: $showClearHistory) {
            Button("取消", role: .cancel) {}
            Button("清空历史", role: .destructive) {
                model.workspace.history.removeAll()
                model.save()
                resetResponse()
            }
        } message: {
            Text("保存的环境变量会保留。")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Console.sidebar)
                    .frame(width: 32, height: 32)
                    .background(Console.accent, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                Text("ApiDog")
                    .font(.system(size: 21, weight: .semibold))
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 22)

            Button {
                draft = RequestDraft()
                requestTab = .headers
                resetResponse()
                urlFocused = true
            } label: {
                HStack {
                    Label("新建请求", systemImage: "plus")
                    Spacer()
                    Text("⌘N").foregroundStyle(Console.muted).accessibilityHidden(true)
                }
            }
            .buttonStyle(ConsoleButton())
            .keyboardShortcut("n", modifiers: .command)
            .disabled(isSending)
            .padding(.horizontal, 14)

            HStack {
                Text("请求历史")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Console.muted)
                Spacer()
                dropdownTrigger(.history, label: "历史操作") {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Console.muted)
                        .frame(width: 26, height: 24)
                        .consoleSurface(dropdown == .history ? Console.line : .clear,
                                        border: Console.line, radius: 6)
                }
                .disabled(model.workspace.history.isEmpty || isSending)
            }
            .padding(.horizontal, 16)
            .padding(.top, 19)
            .padding(.bottom, 6)

            historySearch
                .padding(.horizontal, 14)
                .padding(.bottom, 9)

            let entries = model.workspace.matchingHistory(historyQuery)
            if entries.isEmpty {
                Text(model.workspace.history.isEmpty ? "发送过的请求会出现在这里。" : "找不到匹配的请求。")
                    .font(.system(size: 12))
                    .foregroundStyle(Console.muted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(entries) { entry in
                            HistoryRow(entry: entry, selected: entry.id == activeHistory?.id) {
                                resetResponse()
                                activeHistory = entry
                                draft = entry.request
                                requestTab = .headers
                            } copyAddress: {
                                copy(entry.request.url)
                            }
                            .disabled(isSending)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Console.sidebar)
    }

    private var historySearch: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").accessibilityHidden(true)
            TextField("搜索请求", text: $historyQuery)
                .textFieldStyle(.plain)
                .foregroundStyle(Console.text)
                .accessibilityLabel("搜索请求历史")
            if !historyQuery.isEmpty {
                Button {
                    historyQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Console.muted)
        .padding(.horizontal, 9)
        .frame(height: 30)
        .consoleSurface(Console.input, radius: 7)
    }

    private var mainPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("接口调试")
                    .font(.system(size: 22, weight: .semibold))
                Spacer()
                environmentMenu
                Button {
                    showEnvironments = true
                } label: {
                    Label("变量", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(ConsoleButton())
            }

            addressBar

            GeometryReader { geometry in
                let wide = geometry.size.width >= 770
                let layout = wide
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 14))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                layout {
                    requestPanel
                        .frame(width: wide ? geometry.size.width * 0.40 : nil,
                               height: wide ? nil : 166)
                    responsePanel
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dropdownTrigger<Label: View>(
        _ id: WorkspaceDropdown, label: String, @ViewBuilder content: () -> Label
    ) -> some View {
        Button {
            urlFocused = false
            dropdown = dropdown == id ? nil : id
        } label: {
            content()
        }
        .buttonStyle(.plain)
        .anchorPreference(key: DropdownAnchors.self, value: .bounds) { [id: $0] }
        .accessibilityLabel(label)
    }

    private func dropdownOptions(_ id: WorkspaceDropdown) -> [DropdownOption] {
        switch id {
        case .method:
            return HTTPMethod.allCases.map { method in
                DropdownOption(title: method.rawValue, tone: Console.method(method),
                               monospaced: true, selected: method == draft.method) {
                    draft.method = method
                }
            }
        case .environment:
            return model.workspace.environments.map { environment in
                DropdownOption(title: environment.name, icon: "circle.grid.2x2",
                               selected: environment.id == model.workspace.selectedEnvironment?.id) {
                    model.workspace.selectedEnvironmentID = environment.id
                    model.save()
                }
            }
        case .history:
            return [DropdownOption(title: "清空历史", icon: "trash", tone: Console.red) {
                showClearHistory = true
            }]
        }
    }

    private var environmentMenu: some View {
        let name = model.workspace.selectedEnvironment?.name ?? "默认"
        return dropdownTrigger(.environment, label: "当前环境") {
            HStack(spacing: 7) {
                Image(systemName: "circle.grid.2x2")
                    .foregroundStyle(Console.accent)
                Text(name)
                    .lineLimit(1)
                    .frame(maxWidth: 130)
                dropdownChevron(.environment)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 9)
            .frame(height: 32)
            .consoleSurface(Console.panel, border: dropdown == .environment ? Console.accent : Console.line, radius: 7)
        }
        .accessibilityValue(name)
        .help("切换请求使用的环境")
    }

    private func dropdownChevron(_ id: WorkspaceDropdown) -> some View {
        Image(systemName: dropdown == id ? "chevron.up" : "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .accessibilityHidden(true)
    }

    private var addressBar: some View {
        HStack(spacing: 9) {
            let color = Console.method(draft.method)
            dropdownTrigger(.method, label: "请求方法") {
                HStack {
                    Text(draft.method.rawValue)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                    Spacer(minLength: 4)
                    dropdownChevron(.method)
                }
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .frame(width: 88, height: 35)
                .consoleSurface(color.opacity(0.10),
                                border: color.opacity(dropdown == .method ? 0.8 : 0.22), radius: 6)
                .contentShape(Rectangle())
            }
            .disabled(isSending)
            .accessibilityValue(draft.method.rawValue)

            TextField(text: $draft.url, prompt: Text("https://example.com/api 或 {{baseUrl}}/users")) {
                Text("请求地址")
            }
            .font(.system(size: 13, design: .monospaced))
            .textFieldStyle(.plain)
            .foregroundStyle(Console.text)
            .focused($urlFocused)
            .disabled(isSending)
            .onSubmit { if hasAddress && !isSending { sendOrCancel() } }

            Button(action: sendOrCancel) {
                HStack(spacing: 7) {
                    Image(systemName: isSending ? "stop.fill" : "arrow.right")
                    Text(isSending ? "取消" : "发送")
                    if !isSending {
                        Text("⌘↩").opacity(0.72).accessibilityHidden(true)
                    }
                }
                .frame(minWidth: 78)
            }
            .buttonStyle(ConsoleButton(prominent: !isSending))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!hasAddress && !isSending)
        }
        .padding(7)
        .consoleSurface(Console.input, border: urlFocused ? Console.accent : Console.line, radius: 9)
    }

    private var requestPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelTitle("请求参数", symbol: "slider.horizontal.3")
                .padding(.horizontal, 12)
                .frame(height: 46)

            ConsoleTabs(tabs: RequestTab.allCases, selection: $requestTab) { $0.rawValue }
                .padding(.horizontal, 12)

            Divider()
            if requestTab == .headers {
                editor($draft.headers, label: "请求头", placeholder: "Content-Type: application/json")
            } else if draft.method.allowsBody {
                editor($draft.body, label: "请求体", placeholder: #"{"name":"ApiDog"}"#)
            } else {
                Text("\(draft.method.rawValue) 请求不会发送请求体。")
                    .font(.callout)
                    .foregroundStyle(Console.muted)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .consoleSurface()
        .disabled(isSending)
    }

    private func editor(_ text: Binding<String>, label: String, placeholder: String) -> some View {
        TextEditor(text: text)
            .font(Console.mono)
            .foregroundStyle(Console.text)
            .scrollContentBackground(.hidden)
            .accessibilityLabel(label)
            .padding(8)
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(Console.mono)
                        .foregroundStyle(Console.muted)
                        .padding(.leading, 13)
                        .padding(.top, 9)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    private var responsePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                panelTitle("响应", symbol: "arrow.down.left")
                Spacer(minLength: 4)
                if let entry = activeHistory {
                    let statusColor = Console.status(entry.status)
                    Text(entry.status.map { "HTTP \($0)" } ?? "请求失败")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(statusColor.opacity(0.12), in: Capsule())
                    Text("\(entry.milliseconds) ms")
                        .font(Console.mono)
                        .foregroundStyle(Console.muted)
                        .help("请求耗时 \(entry.milliseconds) 毫秒，环境 \(entry.environment)")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)

            HStack(spacing: 10) {
                ConsoleTabs(tabs: ResponseTab.allCases, selection: $responseTab) { $0.rawValue }
                    .disabled(result == nil)
                Spacer(minLength: 0)
                if let result {
                    Text(result.truncated ? "前 256 KiB" : "\(result.byteCount.formatted()) B")
                        .font(Console.mono)
                        .foregroundStyle(Console.muted)
                        .help(result.truncated ? "响应正文已截断，仅显示前 256 KiB" : "响应正文大小")
                    Button {
                        if copy(responseTab == .body ? result.body : result.headers) {
                            copiedTab = responseTab
                        }
                    } label: {
                        Label(copiedTab == responseTab ? "已复制" : "复制",
                              systemImage: copiedTab == responseTab ? "checkmark" : "doc.on.doc")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Console.accent)
                    .disabled(responseTab == .body ? result.body.isEmpty : result.headers.isEmpty)
                }
            }
            .padding(.horizontal, 12)
            .onChange(of: responseTab) { _ in copiedTab = nil }

            Divider()
            responseContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .consoleSurface()
    }

    @ViewBuilder
    private var responseContent: some View {
        if isSending {
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("正在等待响应").foregroundStyle(Console.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result {
            let content = responseTab == .body ? result.body : result.headers
            if content.isEmpty {
                responseMessage(responseTab == .body ? "没有响应正文" : "没有响应头", symbol: "tray")
            } else {
                ScrollView {
                    Text(content)
                        .font(Console.mono)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }
        } else if let error {
            responseMessage("请求失败", detail: error, symbol: "exclamationmark", tone: Console.red)
        } else if requestCancelled {
            responseMessage("已取消请求", symbol: "stop")
        } else if activeHistory != nil {
            responseMessage("历史响应摘要", detail: "重新发送可查看正文和响应头。", symbol: "clock.arrow.circlepath")
        } else {
            responseMessage("等待响应", detail: "输入地址后按 ⌘↩ 发送。", symbol: "arrow.up.right.and.arrow.down.left")
        }
    }

    private func panelTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 13, weight: .semibold))
            .labelStyle(.titleAndIcon)
    }

    private func responseMessage(_ title: String, detail: String? = nil, symbol: String, tone: Color = Console.muted) -> some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(tone)
                    .frame(width: 42, height: 42)
                    .consoleSurface(Console.input, radius: 10)
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 14, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Console.muted)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
            }
            Text(detail.map { "\(title) · \($0)" } ?? title)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resetResponse() {
        activeHistory = nil
        result = nil
        error = nil
        requestCancelled = false
        copiedTab = nil
        responseTab = .body
    }

    @discardableResult
    private func copy(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    private func sendOrCancel() {
        if let requestTask {
            requestTask.cancel()
            return
        }
        guard hasAddress else { return }
        dropdown = nil

        let template = draft
        let environment = model.workspace.selectedEnvironment
        resetResponse()
        let start = Date()
        let clock = ContinuousClock()
        let started = clock.now

        requestTask = Task {
            defer { requestTask = nil }
            do {
                let request = try template.makeRequest(variables: environment?.values ?? [:])
                let response = try await HTTPClient.send(request)
                try Task.checkCancellation()
                result = response
            } catch {
                if Task.isCancelled {
                    requestCancelled = true
                    return
                }
                self.error = error.localizedDescription
            }
            let elapsed = started.duration(to: clock.now).components
            let milliseconds = Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
            let entry = HistoryEntry(
                date: start, request: template, environment: environment?.name ?? "默认",
                status: result?.status, milliseconds: milliseconds
            )
            model.workspace.append(entry)
            model.save()
            activeHistory = entry
        }
    }
}

private struct HistoryRow: View {
    var entry: HistoryEntry
    var selected: Bool
    var open: () -> Void
    var copyAddress: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: open) {
                details
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(entry.request.url)

            Button(action: copyAddress) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(hovered || selected ? Console.accent : Console.muted)
                    .frame(width: 26, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("复制请求地址")
            .accessibilityLabel("复制请求地址")
        }
        .consoleSurface(selected ? Console.selected : (hovered ? Console.panel : .clear),
                        border: selected ? Console.accent.opacity(0.26) : .clear, radius: 7)
        .onHover { hovered = $0 }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(entry.request.method.rawValue)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Console.method(entry.request.method))
                Spacer()
                Text(entry.status.map(String.init) ?? "失败")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Console.status(entry.status))
            }
            Text(entry.request.url)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 5) {
                Text(entry.environment).lineLimit(1)
                Spacer()
                Text(entry.date.formatted(.dateTime.month().day().hour().minute()))
                    .lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(Console.muted)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
