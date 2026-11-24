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
