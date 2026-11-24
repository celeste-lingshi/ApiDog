import SwiftUI

@main
struct ApiDogApp: App {
    var body: some Scene {
        Window("ApiDog", id: "workspace") {
            WorkspaceView()
        }
        .defaultSize(width: 1120, height: 760)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var workspace = Workspace()
    @Published private(set) var storageIssue: String?

    private let storage: WorkspaceStorage
    private var canWrite = true

    init(storage: WorkspaceStorage = .local) {
        self.storage = storage
        do {
            workspace = try storage.load()
        } catch {
            canWrite = false
            storageIssue = "工作区读取失败，本次改动只保留在窗口内。\n\(error.localizedDescription)"
        }
    }

    func save() {
        guard canWrite else { return }
        do {
            try storage.save(workspace)
            storageIssue = nil
        } catch {
            storageIssue = "工作区写入失败。\(error.localizedDescription)"
        }
    }
}

private let accent = Color(red: 0.05, green: 0.48, blue: 0.40)
private let mono = Font.system(size: 13, design: .monospaced)

struct WorkspaceView: View {
    @StateObject private var model = WorkspaceModel()
    @State private var draft = RequestDraft()
    @State private var requestTab = RequestTab.headers
    @State private var responseTab = ResponseTab.body
    @State private var result: ResponseDetails?
    @State private var error: String?
    @State private var activeHistory: HistoryEntry?
    @State private var isSending = false
    @State private var showEnvironments = false
    @State private var showClearHistory = false
    @FocusState private var urlFocused: Bool

    private enum RequestTab: String, CaseIterable { case headers = "请求头", body = "请求体" }
    private enum ResponseTab: String, CaseIterable { case body = "正文", headers = "响应头" }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 256)
                    .background(accent.opacity(0.055))
                Divider()
                VStack(alignment: .leading, spacing: 20) {
                    requestPanel
                    responsePanel
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let issue = model.storageIssue {
                Divider()
                Label(issue, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .frame(minWidth: 860, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
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
                activeHistory = nil
                result = nil
                error = nil
            }
        } message: {
            Text("保存的环境变量会保留。")
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(accent, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            Text("ApiDog").font(.system(size: 21, weight: .semibold))
            Spacer()
            Picker("环境", selection: Binding(
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
            .frame(width: 175)
            Button("变量") { showEnvironments = true }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("请求历史").font(.headline)
                Spacer()
                Button {
                    showClearHistory = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(model.workspace.history.isEmpty || isSending)
                .accessibilityLabel("清空历史")
                .help("清空历史")
            }
            .padding(.horizontal, 16)
            .padding(.top, 17)

            Button {
                draft = RequestDraft()
                activeHistory = nil
                result = nil
                error = nil
                requestTab = .headers
                responseTab = .body
                urlFocused = true
            } label: {
                Label("新建请求", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            .controlSize(.large)
            .keyboardShortcut("n", modifiers: .command)
            .disabled(isSending)
            .padding(.horizontal, 13)

            if model.workspace.history.isEmpty {
                Text("发送过的请求会出现在这里。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(model.workspace.history) { entry in
                            historyRow(entry)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        Button {
            activeHistory = entry
            draft = entry.request
            result = nil
            error = nil
            requestTab = .headers
            responseTab = .body
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(entry.request.method.rawValue)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(methodColor(entry.request.method))
                        .frame(minWidth: 40, alignment: .leading)
                    Text(entry.request.url)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Text(entry.date.formatted(.dateTime.month().day().hour().minute()))
                    Spacer()
                    Text(entry.status.map(String.init) ?? "失败")
                        .foregroundStyle(statusColor(entry.status))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(9)
            .background(
                activeHistory?.id == entry.id ? accent.opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSending)
        .help(entry.request.url)
    }

    private var requestPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("请求").font(.title3.weight(.semibold))
            HStack(spacing: 10) {
                Picker("请求方法", selection: $draft.method) {
                    ForEach(HTTPMethod.allCases, id: \.self) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                .labelsHidden()
                .frame(width: 95)
                TextField("https://example.com/api 或 {{baseUrl}}/users", text: $draft.url)
                    .accessibilityLabel("请求地址")
                    .font(mono)
                    .focused($urlFocused)
                Button(action: send) {
                    Label("发送", systemImage: "paperplane.fill")
                        .frame(minWidth: 60)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isSending || draft.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.large)

            VStack(spacing: 0) {
                HStack {
                    Picker("请求内容", selection: $requestTab) {
                        ForEach(RequestTab.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 158)
                    Spacer()
                    if requestTab == .body && !draft.method.allowsBody {
                        Text("\(draft.method.rawValue) 请求不会发送请求体")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(9)
                Divider()
                if requestTab == .headers {
                    editor($draft.headers, label: "请求头", placeholder: "Content-Type: application/json")
                } else {
                    editor($draft.body, label: "请求体", placeholder: "{\"name\":\"ApiDog\"}")
                        .disabled(!draft.method.allowsBody)
                }
            }
            .frame(height: 170)
            .background(.background, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(.quaternary)
                    .allowsHitTesting(false)
            }
        }
        .disabled(isSending)
    }

    private func editor(_ text: Binding<String>, label: String, placeholder: String) -> some View {
        TextEditor(text: text)
            .font(mono)
            .scrollContentBackground(.hidden)
            .accessibilityLabel(label)
            .padding(5)
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(mono)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 10)
                        .padding(.top, 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    private var responsePanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Text("响应").font(.title3.weight(.semibold))
                if let entry = activeHistory {
                    Text(entry.status.map { "HTTP \($0)" } ?? "请求失败")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(statusColor(entry.status))
                    Text("\(entry.milliseconds) 毫秒")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(entry.environment)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let result {
                    Text(result.truncated ? "仅显示前 256 KiB" : "\(result.byteCount.formatted()) 字节")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                HStack {
                    Picker("响应内容", selection: $responseTab) {
                        ForEach(ResponseTab.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 158)
                    .disabled(result == nil)
                    Spacer()
                }
                .padding(9)
                Divider()
                if isSending {
                    VStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("正在等待响应").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let result {
                    let content = responseTab == .body ? result.body : result.headers
                    if content.isEmpty {
                        responseMessage(responseTab == .body ? "响应没有正文。" : "响应没有可显示的响应头。")
                    } else {
                        ScrollView {
                            Text(content)
                                .font(mono)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                    }
                } else if let error {
                    responseMessage(error, symbol: "exclamationmark.circle")
                } else if activeHistory != nil {
                    responseMessage("这条历史保留了响应摘要。再次发送可查看正文和响应头。")
                } else {
                    responseMessage("发送请求后，响应会显示在这里。")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(.quaternary)
                    .allowsHitTesting(false)
            }
        }
    }

    private func responseMessage(_ message: String, symbol: String = "tray") -> some View {
        Label(message, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func send() {
        let template = draft
        let environment = model.workspace.selectedEnvironment
        isSending = true
        error = nil
        result = nil
        activeHistory = nil
        responseTab = .body
        let start = Date()
        let clock = ContinuousClock()
        let started = clock.now

        Task {
            do {
                let request = try template.makeRequest(variables: environment?.values ?? [:])
                result = try await HTTPClient.send(request)
            } catch {
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
            isSending = false
        }
    }

    private func methodColor(_ method: HTTPMethod) -> Color {
        switch method {
        case .get, .head: return accent
        case .post: return .blue
        case .put, .patch: return .orange
        case .delete: return .red
        case .options: return .purple
        }
    }

    private func statusColor(_ status: Int?) -> Color {
        guard let status else { return .red }
        switch status {
        case 200..<300: return accent
        case 300..<400: return .orange
        case 400..<600: return .red
        default: return .secondary
        }
    }
}
