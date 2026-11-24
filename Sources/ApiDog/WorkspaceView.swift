import AppKit
import SwiftUI

struct WorkspaceView: View {
    @StateObject private var model = WorkspaceModel()
    @State private var draft = RequestDraft()
    @State private var requestTab = RequestTab.variables
    @State private var responseTab = ResponseTab.curl
    @State private var copiedCurl: String?
    @State private var generatedPreview: AuthPreview?
    @State private var copyingGeneratedCurl = false
    @State private var result: ResponseDetails?
    @State private var resultProjection: String?
    @State private var error: String?
    @State private var activeHistory: HistoryEntry?
    @State private var requestTask: Task<Void, Never>?
    @State private var requestCancelled = false
    @State private var copiedTab: ResponseTab?
    @State private var historyQuery = ""
    @State private var sidebarTab = SidebarTab.directory
    @State private var activeSavedID: UUID?
    @State private var collapsedCategories: Set<UUID> = []
    @State private var modal: Modal?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropdown: WorkspaceDropdown?
    @FocusState private var urlFocused: Bool

    private struct AuthPreview {
        var draft: RequestDraft
        var command: Result<String, Error>
    }

    private enum Modal: Equatable { case importCurl, clearHistory, newCategory, newRequest, saveRequest, removeRequest }
    private enum SidebarTab: String, CaseIterable { case directory = "请求目录", history = "请求历史" }

    private var directory: RequestDirectory { model.workspace.requestDirectory }
    private var activeSavedRequest: SavedRequest? {
        directory.requests.first { $0.id == activeSavedID }
    }
    private enum RequestTab: String, CaseIterable {
        case variables = "变量", query = "查询", headers = "请求头", authentication = "认证"
        case body = "请求体", connection = "连接"
    }
    private enum ResponseTab: String, CaseIterable { case curl = "cURL", body = "正文", headers = "响应头", extracted = "提取" }

    private var availableResponseTabs: [ResponseTab] {
        ResponseTab.allCases.filter { $0 != .extracted || resultProjection != nil }
    }

    private var isSending: Bool { requestTask != nil }
    private var hasAddress: Bool { !draft.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 244)
                ConsoleRule(vertical: true)
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
        .disabled(modal != nil)
        .accessibilityHidden(dropdown != nil || modal != nil)
        .overlayPreferenceValue(DropdownAnchors.self) { anchors in
            GeometryReader { geometry in
                if let dropdown, let anchor = anchors[dropdown] {
                    let trigger = geometry[anchor]
                    let left = [.history, .directory].contains(dropdown) ? trigger.maxX - dropdown.width : trigger.minX
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
        .task(id: draft) {
            let snapshot = draft
            generatedPreview = nil
            guard snapshot.auth.generated else { return }
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
                let command = await preview(snapshot)
                try Task.checkCancellation()
                generatedPreview = AuthPreview(draft: snapshot, command: command)
            } catch {}
        }
        .overlay {
            if let modal {
                ConsoleModal {
                    switch modal {
                    case .importCurl:
                        CurlImportDialog(cancel: closeModal) { imported in
                            activeSavedID = nil
                            draft = imported
                            resetResponse()
                            requestTab = startingTab(for: imported)
                            self.modal = nil
                        }
                    case .clearHistory:
                        ConsoleConfirmationDialog(title: "清空全部请求历史？",
                                                  message: "历史请求将被删除，请求目录里的项目会保留。",
                                                  confirmTitle: "清空历史", cancel: closeModal) {
                            model.workspace.history.removeAll()
                            model.save()
                            if result == nil { activeHistory = nil }
                            closeModal()
                        }
                    case .newCategory:
                        RequestMetadataDialog(title: "新建分类", existingCategoryNames: directory.categories.map(\.name),
                                              cancel: closeModal) { name, _ in
                            model.workspace.requestDirectory.categories.append(RequestCategory(name: name))
                            model.save()
                            closeModal()
                        }
                    case .newRequest, .saveRequest:
                        requestMetadataDialog(creating: modal == .newRequest)
                    case .removeRequest:
                        if let request = activeSavedRequest {
                            ConsoleConfirmationDialog(title: "删除「\(request.name)」？",
                                               message: "这条请求将从目录移除，发送历史会保留。",
                                               confirmTitle: "删除请求", cancel: closeModal) {
                                model.workspace.requestDirectory.requests.removeAll { $0.id == request.id }
                                activeSavedID = nil
                                model.save()
                                closeModal()
                            }
                        }
                    }
                }
                .onExitCommand(perform: closeModal)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: modal)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var titleBar: some View {
        ConsoleTitleBar {
            Button {
                openModal(.importCurl)
            } label: {
                Label("导入 cURL", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(ConsoleButton())
            .disabled(isSending)
        }
    }

    private func startingTab(for draft: RequestDraft) -> RequestTab {
        if !draft.variableNames.isEmpty { return .variables }
        if draft.auth.mode != .none { return .authentication }
        if !draft.headers.isEmpty { return .headers }
        if !draft.query.isEmpty { return .query }
        return draft.body == nil ? .variables : .body
    }

    private func openModal(_ target: Modal) {
        dropdown = nil
        urlFocused = false
        modal = target
    }

    private func closeModal() {
        modal = nil
    }

    private func requestMetadataDialog(creating: Bool) -> some View {
        let existing = creating ? nil : activeSavedRequest
        let suggested = URLComponents(string: draft.url)?.path.split(separator: "/").last.map(String.init) ?? ""
        return RequestMetadataDialog(title: creating ? "新建请求" : "保存请求",
                                     name: creating ? "" : (existing?.name ?? suggested),
                                     categories: directory.categories, categoryID: existing?.categoryID,
                                     cancel: closeModal) { name, categoryID in
            let request = SavedRequest(id: existing?.id ?? UUID(), name: name, categoryID: categoryID,
                                       draft: creating ? RequestDraft() : draft)
            model.workspace.requestDirectory.store(request)
            model.save()
            if let categoryID { collapsedCategories.remove(categoryID) }
            sidebarTab = .directory
            if creating {
                openSavedRequest(request)
            } else {
                activeSavedID = request.id
            }
            closeModal()
        }
    }

    private func openSavedRequest(_ request: SavedRequest) {
        urlFocused = false
        activeSavedID = request.id
        draft = request.draft
        requestTab = startingTab(for: draft)
        resetResponse()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ConsoleTabs(tabs: SidebarTab.allCases, selection: $sidebarTab) { $0.rawValue }
                Spacer(minLength: 0)
                if sidebarTab == .directory {
                    sidebarAction(.directory, label: "添加到请求目录", symbol: "plus")
                        .disabled(isSending)
                } else {
                    sidebarAction(.history, label: "历史操作", symbol: "ellipsis")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 9)
            .padding(.bottom, 4)

            ConsoleRule()
                .padding(.bottom, 8)
            if sidebarTab == .directory {
                RequestDirectoryView(directory: directory, selectedID: activeSavedID, collapsed: $collapsedCategories,
                                     select: openSavedRequest)
                    .disabled(isSending)
            } else {
                historyContents
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Console.sidebar)
    }

    private func sidebarAction(_ id: WorkspaceDropdown, label: String, symbol: String) -> some View {
        dropdownTrigger(id, label: label) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Console.muted)
                .frame(width: 32, height: 29)
                .consoleSurface(dropdown == id ? Console.line : Console.input, border: Console.line, radius: 6)
        }
        .help(label)
    }

    private var historyContents: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                                urlFocused = false
                                activeSavedID = nil
                                resetResponse()
                                activeHistory = entry
                                draft = model.workspace.draft(for: entry)
                                requestTab = startingTab(for: draft)
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
        }
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
            if let saved = activeSavedRequest {
                HStack(spacing: 7) {
                    if let category = directory.categories.first(where: { $0.id == saved.categoryID }) {
                        Label(category.name, systemImage: "folder")
                            .foregroundStyle(Console.muted)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(Console.muted)
                            .accessibilityHidden(true)
                    }
                    Text(saved.name).fontWeight(.semibold)
                    if draft != saved.draft {
                        Text("有修改")
                            .font(.system(size: 11))
                            .foregroundStyle(Console.amber)
                    }
                }
                .font(.system(size: 13))
                .lineLimit(1)
            }

            addressBar

            GeometryReader { geometry in
                let wide = geometry.size.width >= 770
                let layout = wide
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 14))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                layout {
                    requestPanel
                        .frame(width: wide ? geometry.size.width * 0.46 : nil,
                               height: wide ? nil : 218)
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
            content().contentShape(Rectangle())
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
        case .authentication:
            return RequestAuthentication.Mode.allCases.map { mode in
                DropdownOption(title: mode.title, icon: "key", selected: mode == draft.auth.mode) {
                    if mode != draft.auth.mode {
                        draft.auth = RequestAuthentication(mode: mode, name: mode == .apiKey ? "X-API-Key" : "",
                            scriptInputs: mode == .script ? [RequestField("token", nil)] : nil)
                    }
                }
            }
        case .authLocation:
            return RequestAuthentication.Location.allCases.map { location in
                DropdownOption(title: location.title, selected: location == draft.auth.location) {
                    draft.auth.placement = location
                }
            }
        case .history:
            if model.workspace.history.isEmpty {
                return [DropdownOption(title: "暂无请求历史", icon: "clock", tone: Console.muted)]
            }
            if isSending {
                return [DropdownOption(title: "发送中，稍后清空", icon: "clock", tone: Console.muted)]
            }
            return [DropdownOption(title: "清空历史", icon: "trash", tone: Console.red) {
                openModal(.clearHistory)
            }]
        case .directory:
            var options = [
                DropdownOption(title: "新建分类", icon: "folder.badge.plus") { openModal(.newCategory) },
                DropdownOption(title: "新建请求", icon: "doc.badge.plus") { openModal(.newRequest) }
            ]
            if activeSavedRequest != nil {
                options.append(DropdownOption(title: "删除当前请求", icon: "trash", tone: Console.red) {
                    openModal(.removeRequest)
                })
            }
            return options
        }
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

            TextField(text: $draft.url, prompt: Text("http://111/{hostname}/ping")) {
                Text("请求地址")
            }
            .font(.system(size: 13, design: .monospaced))
            .textFieldStyle(.plain)
            .foregroundStyle(Console.text)
            .focused($urlFocused)
            .onChange(of: draft.url) { _ in
                if urlFocused && !draft.variableNames.isEmpty { requestTab = .variables }
            }
            .disabled(isSending)
            .onSubmit { if hasAddress && !isSending { sendOrCancel() } }

            Button {
                openModal(.saveRequest)
            } label: {
                Label("保存", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(ConsoleButton())
            .keyboardShortcut("s", modifiers: .command)
            .disabled(isSending || (!hasAddress && activeSavedID == nil))

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
            HStack(spacing: 6) {
                panelTitle("请求参数", symbol: "slider.horizontal.3")
                Spacer(minLength: 0)
                Toggle("跟随跳转", isOn: $draft.followsRedirects)
                    .toggleStyle(ConsoleCheckbox())
                    .accessibilityLabel("跟随跳转")
                Text("跟随跳转")
                    .font(.system(size: 11))
                    .foregroundStyle(Console.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(height: 46)

            ConsoleTabs(tabs: RequestTab.allCases, selection: $requestTab) { $0.rawValue }
                .padding(.horizontal, 12)

            ConsoleRule()
            switch requestTab {
            case .variables:
                RequestVariablesEditor(names: draft.variableNames, values: $draft.variables)
            case .query:
                RequestFieldsEditor(fields: $draft.query, header: false)
            case .headers:
                RequestFieldsEditor(fields: $draft.headers, header: true)
            case .authentication:
                authenticationEditor
            case .connection:
                connectionEditor
            case .body:
                if draft.method.allowsBody {
                    editor(Binding(
                        get: { draft.body ?? "" },
                        set: { draft.body = $0.isEmpty ? nil : $0 }
                    ), label: "请求体", placeholder: #"{"name":"ApiDog"}"#)
                } else {
                    Text("\(draft.method.rawValue) 请求不会发送请求体。")
                        .font(.callout)
                        .foregroundStyle(Console.muted)
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .consoleSurface()
        .disabled(isSending)
    }

    private var connectionEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                authRow("指定解析") {
                    TextField("域名:端口:IP", text: routeValue(\.resolve)).requestInput()
                }
                authRow("不走代理") {
                    TextField("主机名，多个用逗号分隔", text: routeValue(\.noProxy)).requestInput()
                }
                authRow("响应提取") {
                    TextField(".reason[]?.port", text: Binding(
                        get: { draft.projection ?? "" },
                        set: {
                            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                            draft.projection = value.isEmpty ? nil : value
                        }
                    )).requestInput()
                }
                Text("响应提取使用简单字段路径。原始内容仍在「正文」。")
                    .font(.system(size: 11))
                    .foregroundStyle(Console.muted)
            }
            .padding(12)
        }
    }

    private func routeValue(_ path: WritableKeyPath<RequestRoute, String?>) -> Binding<String> {
        Binding(
            get: { draft.route?[keyPath: path] ?? "" },
            set: {
                let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                var route = draft.route ?? RequestRoute()
                route[keyPath: path] = value.isEmpty ? nil : value
                draft.route = route.isConfigured ? route : nil
            }
        )
    }

    private var authenticationEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                dropdownTrigger(.authentication, label: "认证方式") {
                    HStack(spacing: 8) {
                        Image(systemName: "key").foregroundStyle(Console.accent)
                        Text(draft.auth.mode.title)
                        Spacer(minLength: 0)
                        dropdownChevron(.authentication)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 9)
                    .frame(height: 32)
                    .consoleSurface(Console.input, border: dropdown == .authentication ? Console.accent : Console.line, radius: 6)
                }
                .accessibilityValue(draft.auth.mode.title)
                switch draft.auth.mode {
                case .none:
                    Text("选择认证方式后，按字段填写。")
                        .font(.system(size: 12))
                        .foregroundStyle(Console.muted)
                case .bearer:
                    authRow("Token") { SecureField("填 Token", text: authenticationSecret).requestInput() }
                case .basic:
                    authRow("用户名") { TextField("填用户名", text: $draft.auth.name).requestInput() }
                    authRow("密码") { SecureField("填密码", text: authenticationSecret).requestInput() }
                case .apiKey:
                    authRow("字段名") { TextField("X-API-Key", text: $draft.auth.name).requestInput() }
                    authRow("值") { SecureField("填 API Key", text: authenticationSecret).requestInput() }
                    authRow("位置") { authLocation }
                case .hmac:
                    authRow("API Key") {
                        TextField(draft.auth.signingKeyInput ?? "填 apikey", text: $draft.auth.name).requestInput()
                    }
                    authRow("Secure Key") {
                        SecureField(draft.auth.signingSecretInput ?? "填 securekey", text: authenticationSecret).requestInput()
                    }
                    authRow("Key 字段") {
                        TextField("apikey", text: Binding(
                            get: { draft.auth.signingKeyField ?? "" },
                            set: { draft.auth.signingKeyField = $0 }
                        )).requestInput()
                    }
                    authRow("签名 URI") {
                        TextField("默认使用请求路径", text: Binding(
                            get: { draft.auth.signingURI ?? "" },
                            set: { draft.auth.signingURI = $0 }
                        )).requestInput()
                    }
                    authRow("位置") { authLocation }
                    Text("Key 和 sign 使用所选位置。timestamp 自动填入 URL 查询。")
                        .font(.system(size: 11))
                        .foregroundStyle(Console.muted)
                case .script:
                    AuthScriptEditor(auth: $draft.auth)
                }
            }
            .padding(12)
        }
    }

    private var authLocation: some View {
        dropdownTrigger(.authLocation, label: "认证字段位置") {
            HStack {
                Text(draft.auth.location.title)
                Spacer(minLength: 0)
                dropdownChevron(.authLocation)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(height: 30)
            .consoleSurface(Console.input, border: dropdown == .authLocation ? Console.accent : Console.line, radius: 6)
        }
        .accessibilityValue(draft.auth.location.title)
    }

    private var authenticationSecret: Binding<String> {
        Binding(get: { draft.auth.secret ?? "" }, set: { draft.auth.secret = $0 })
    }

    private func authRow<Input: View>(_ label: String, @ViewBuilder input: () -> Input) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Console.muted)
                .frame(width: 76, alignment: .leading)
            input().accessibilityLabel(label)
        }
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
        let prepared: Result<String, Error>?
        if draft.auth.generated {
            prepared = generatedPreview?.draft == draft ? generatedPreview?.command : nil
        } else {
            prepared = Result {
                formattedCommand(try draft.makeRequest(), for: draft)
            }
        }
        let command = try? prepared?.get()
        let payload = result.map(responsePayload)
        let visibleText = try? payload?.get()
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                panelTitle(responseTab == .curl ? "cURL 预览" : "响应",
                           symbol: responseTab == .curl ? "terminal" : "arrow.down.left")
                Spacer(minLength: 4)
                if responseTab != .curl, let entry = activeHistory {
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
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)

            HStack(spacing: 10) {
                ConsoleTabs(tabs: availableResponseTabs, selection: $responseTab) { $0.rawValue }
                Spacer(minLength: 0)
                if responseTab == .curl, let command {
                    Button {
                        copyCurl(command)
                    } label: {
                        Label(copiedCurl == command ? "已复制" : "复制命令",
                              systemImage: copiedCurl == command ? "checkmark" : "doc.on.doc")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Console.accent)
                    .disabled(copyingGeneratedCurl)
                } else if responseTab != .curl, let result {
                    Text(result.truncated ? "前 256 KiB" : "\(result.byteCount.formatted()) B")
                        .font(Console.mono)
                        .foregroundStyle(Console.muted)
                    Button {
                        if let visibleText, copy(visibleText) { copiedTab = responseTab }
                    } label: {
                        Label(copiedTab == responseTab ? "已复制" : "复制",
                              systemImage: copiedTab == responseTab ? "checkmark" : "doc.on.doc")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Console.accent)
                    .disabled(visibleText?.isEmpty != false)
                }
            }
            .padding(.horizontal, 12)
            .onChange(of: responseTab) { _ in copiedTab = nil }

            ConsoleRule()
            if responseTab == .curl {
                if let command {
                    ScrollView {
                        Text(verbatim: command)
                            .font(Console.mono)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    if draft.auth.mode != .none {
                        Label(draft.auth.generated ? "含认证信息，复制和发送会重新生成" : "预览包含认证信息",
                              systemImage: "lock")
                            .font(.system(size: 11))
                            .foregroundStyle(Console.muted)
                            .padding([.horizontal, .bottom], 12)
                    }
                } else {
                    if !hasAddress {
                        responseMessage("等待补全请求", detail: "填写地址后实时生成命令。", symbol: "terminal")
                    } else if case .failure(let error)? = prepared {
                        responseMessage("等待补全请求", detail: error.localizedDescription, symbol: "terminal")
                    } else {
                        responseMessage("正在生成认证", symbol: "key")
                    }
                }
            } else {
                responseContent(payload: payload)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .consoleSurface()
    }

    private func responsePayload(_ response: ResponseDetails) -> Result<String, Error> {
        Result {
            switch responseTab {
            case .body, .curl: return response.body
            case .headers: return response.headers
            case .extracted:
                if response.truncated { throw ProjectionError.truncated }
                guard let resultProjection else { return "" }
                return try ResponseProjection(resultProjection).format(response.body)
            }
        }
    }

    @ViewBuilder
    private func responseContent(payload: Result<String, Error>?) -> some View {
        if isSending {
            VStack(spacing: 12) {
                ConsoleProgress()
                Text("正在等待响应").foregroundStyle(Console.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let payload {
            switch payload {
            case .failure(let error):
                responseMessage("无法提取结果", detail: error.localizedDescription, symbol: "exclamationmark.circle")
            case .success(let text):
                if text.isEmpty {
                    let message = responseTab == .extracted ? "没有匹配的字段" : (responseTab == .headers ? "没有响应头" : "没有响应正文")
                    responseMessage(message, symbol: "tray")
                } else {
                    ScrollView {
                        Text(verbatim: text)
                            .font(Console.mono)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
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
        resultProjection = nil
        activeHistory = nil
        result = nil
        error = nil
        requestCancelled = false
        copiedTab = nil
        copiedCurl = nil
        responseTab = .curl
    }

    @discardableResult
    private func copy(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    private func formattedCommand(_ request: URLRequest, for snapshot: RequestDraft) -> String {
        CurlCommand.render(request, followsRedirects: snapshot.followsRedirects,
                           route: snapshot.route, projection: snapshot.projection)
    }

    private func preview(_ snapshot: RequestDraft) async -> Result<String, Error> {
        do {
            let request = try await snapshot.prepareRequest()
            return .success(formattedCommand(request, for: snapshot))
        } catch {
            return .failure(error)
        }
    }

    private func copyCurl(_ command: String) {
        if !draft.auth.generated {
            if copy(command) { copiedCurl = command }
            return
        }
        let snapshot = draft
        copyingGeneratedCurl = true
        Task {
            defer { copyingGeneratedCurl = false }
            let result = await preview(snapshot)
            guard draft == snapshot else { return }
            generatedPreview = AuthPreview(draft: snapshot, command: result)
            if case .success(let fresh) = result, copy(fresh) { copiedCurl = fresh }
        }
    }

    private func sendOrCancel() {
        if let requestTask {
            requestTask.cancel()
            return
        }
        guard hasAddress else { return }
        dropdown = nil

        let template = draft
        resetResponse()
        resultProjection = template.projection
        responseTab = resultProjection == nil ? .body : .extracted
        let start = Date()
        let clock = ContinuousClock()
        let started = clock.now

        requestTask = Task {
            defer { requestTask = nil }
            do {
                let request = try await template.prepareRequest()
                try Task.checkCancellation()
                if template.auth.generated {
                    generatedPreview = AuthPreview(draft: template, command: .success(
                        formattedCommand(request, for: template)
                    ))
                }
                let response = try await HTTPClient.send(request, followsRedirects: template.followsRedirects, route: template.route)
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
                date: start, request: template,
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
                if let environment = entry.environment { Text(environment).lineLimit(1) }
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
