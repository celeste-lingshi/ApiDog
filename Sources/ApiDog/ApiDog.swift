import AppKit
import SwiftUI

@main
enum ApiDogMain {
    @MainActor static func main() {
        if !AuthScript.runWorkerIfRequested() { ApiDogApp.main() }
    }
}

struct ApiDogApp: App {
    @NSApplicationDelegateAdaptor(ApiDogAppDelegate.self) private var delegate

    var body: some Scene {
        Window("ApiDog", id: "workspace") {
            WorkspaceView()
        }
        .defaultSize(width: 1200, height: 740)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

private final class ApiDogAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = Bundle.main.image(forResource: "ApiDog") {
            NSApplication.shared.applicationIconImage = icon
        }
    }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var workspace = Workspace()
    @Published private(set) var storageIssue: String?
    @Published private(set) var isMigratingCredentials = false

    private let storage: WorkspaceStorage
    private var canWrite = true

    init(storage: WorkspaceStorage = .local) {
        self.storage = storage
        do {
            workspace = try storage.load()
            if workspace.credentialsLocked {
                storageIssue = "旧版认证尚未迁移。现在可以浏览，迁移后可以编辑和发送请求。"
            }
        } catch {
            canWrite = false
            storageIssue = "工作区读取失败，本次改动只保留在窗口内。\n\(error.localizedDescription)"
        }
    }

    func save() {
        guard canWrite, !workspace.credentialsLocked else { return }
        do {
            try storage.save(workspace)
            storageIssue = nil
        } catch {
            storageIssue = "工作区写入失败。\(error.localizedDescription)"
        }
    }

    func migrateCredentials() async {
        guard workspace.credentialsLocked, !isMigratingCredentials else { return }
        isMigratingCredentials = true
        defer { isMigratingCredentials = false }
        do {
            let key = try await Task.detached { try WorkspaceCredentialKey.loadLegacy() }.value
            workspace = try storage.migrateCredentials(using: key)
            storageIssue = nil
        } catch {
            storageIssue = "迁移认证失败。\(error.localizedDescription)"
        }
    }
}
