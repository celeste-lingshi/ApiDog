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
                Menu {
                    Button("清空历史", role: .destructive) { showClearHistory = true }
                        .disabled(model.workspace.history.isEmpty || isSending)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("历史操作")
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
                            }
                            .disabled(isSending)
                            .contextMenu {
                                Button("复制请求地址") { copy(entry.request.url) }
                            }
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

    private var environmentMenu: some View {
        Menu {
            Picker("当前环境", selection: Binding(
                get: { model.workspace.selectedEnvironment?.id },
                set: {
                    model.workspace.selectedEnvironmentID = $0
                    model.save()
                }
            )) {
                ForEach(model.workspace.environments) { environment in
                    Text(environment.name).tag(Optional(environment.id))
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "circle.grid.2x2")
                    .foregroundStyle(Console.accent)
                Text(model.workspace.selectedEnvironment?.name ?? "默认")
                    .lineLimit(1)
                    .frame(maxWidth: 130)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Console.muted)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 9)
            .frame(height: 32)
            .consoleSurface(Console.panel, radius: 7)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("当前环境")
        .accessibilityValue(model.workspace.selectedEnvironment?.name ?? "默认")
        .help("切换请求使用的环境")
    }

    private var addressBar: some View {
        HStack(spacing: 9) {
            Menu {
                Picker("请求方法", selection: $draft.method) {
                    ForEach(HTTPMethod.allCases, id: \.self) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
            } label: {
                HStack {
                    Text(draft.method.rawValue)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Console.method(draft.method))
                .padding(.horizontal, 10)
                .frame(width: 88, height: 35)
                .background(Console.method(draft.method).opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isSending)
            .accessibilityLabel("请求方法")
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
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
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
            .consoleSurface(selected ? Console.selected : (hovered ? Console.panel : .clear),
                            border: selected ? Console.accent.opacity(0.26) : .clear, radius: 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(entry.request.url)
    }
}
