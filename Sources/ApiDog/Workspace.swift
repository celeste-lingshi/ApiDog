import CryptoKit
import Foundation
import Security

struct EnvironmentVariable: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var value = ""
    var sessionOnly = false
}

struct RequestEnvironment: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var variables: [EnvironmentVariable] = []

    var values: [String: String] {
        Dictionary(
            variables.filter { !$0.name.isEmpty && (!$0.sessionOnly || !$0.value.isEmpty) }
                .map { ($0.name, $0.value) },
            uniquingKeysWith: { _, latest in latest }
        )
    }
}

struct HistoryEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var date: Date
    var request: RequestDraft
    var environment: String? = nil
    var status: Int?
    var milliseconds: Int
}

struct RequestCategory: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
}

struct SavedRequest: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var categoryID: UUID?
    var draft: RequestDraft

    func duplicate(name: String, categoryID: UUID?) -> Self {
        SavedRequest(name: name, categoryID: categoryID, draft: draft)
    }
}

struct RequestDirectory: Codable, Equatable {
    var categories: [RequestCategory] = []
    var requests: [SavedRequest] = []

    func requests(in categoryID: UUID?) -> [SavedRequest] {
        requests.filter { $0.categoryID == categoryID }
    }

    mutating func store(_ request: SavedRequest) {
        if let index = requests.firstIndex(where: { $0.id == request.id }) {
            requests[index] = request
        } else {
            requests.append(request)
        }
    }

    mutating func move(_ requestID: UUID, to categoryID: UUID?) -> Bool {
        guard categoryID == nil || categories.contains(where: { $0.id == categoryID }),
              let index = requests.firstIndex(where: { $0.id == requestID }),
              requests[index].categoryID != categoryID else { return false }
        requests[index].categoryID = categoryID
        return true
    }
}

struct Workspace: Codable, Equatable {
    var environments: [RequestEnvironment] = []
    var selectedEnvironmentID: UUID?
    var history: [HistoryEntry] = []
    var directory: RequestDirectory?
    fileprivate var encryptedCredentials: Data?

    init() {}

    var credentialsLocked: Bool { encryptedCredentials != nil }

    var requestDirectory: RequestDirectory {
        get { directory ?? RequestDirectory() }
        set { directory = newValue }
    }

    func draft(for entry: HistoryEntry) -> RequestDraft {
        var draft = entry.request
        let values = environments.first(where: { $0.name == entry.environment })?.values ?? [:]
        for name in draft.variableNames where draft.variables[name] == nil {
            draft.variables[name] = values[name]
        }
        return draft
    }

    func matchingHistory(_ query: String) -> [HistoryEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return history }
        return history.filter { entry in
            let status = entry.status.map(String.init) ?? "失败"
            return [entry.request.url, entry.request.method.rawValue, entry.environment ?? "", status]
                .contains { $0.localizedStandardContains(term) }
        }
    }

    mutating func append(_ entry: HistoryEntry) {
        history.insert(entry, at: 0)
        history = Array(history.prefix(100))
    }
}

final class WorkspaceStorage {
    let file: URL
    private let credentialKey: ((Bool) throws -> SymmetricKey)?
    private var cachedKey: SymmetricKey?
    private var keyFile: URL { file.deletingPathExtension().appendingPathExtension("key") }

    static let local = WorkspaceStorage(file: URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/ApiDog/workspace.json"))

    init(file: URL, credentialKey: ((Bool) throws -> SymmetricKey)? = nil) {
        self.file = file
        self.credentialKey = credentialKey
    }

    private func key(create: Bool) throws -> SymmetricKey {
        if let cachedKey { return cachedKey }
        let key = try credentialKey?(create) ?? loadFileKey(create: create)
        cachedKey = key
        return key
    }

    func load() throws -> Workspace {
        var workspace = try readWorkspace()
        guard workspace.credentialsLocked else { return workspace }
        do {
            try restoreCredentials(in: &workspace, using: key(create: false))
        } catch KeyFileError.missing {
            return workspace
        }
        return workspace
    }

    func migrateCredentials(using key: SymmetricKey) throws -> Workspace {
        var workspace = try readWorkspace()
        try restoreCredentials(in: &workspace, using: key)
        try writeFileKey(key)
        cachedKey = key
        return workspace
    }

    private func readWorkspace() throws -> Workspace {
        do {
            let data = try Data(contentsOf: file)
            return try JSONDecoder().decode(Workspace.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Workspace()
        }
    }

    private func restoreCredentials(in workspace: inout Workspace, using key: SymmetricKey) throws {
        guard let encrypted = workspace.encryptedCredentials else { return }
        let sealed = try AES.GCM.SealedBox(combined: encrypted)
        let decoded = try AES.GCM.open(sealed, using: key)
        let credentials = try JSONDecoder().decode([UUID: RequestCredentials].self, from: decoded)
        if var directory = workspace.directory {
            for index in directory.requests.indices {
                if let credential = credentials[directory.requests[index].id] {
                    directory.requests[index].draft.auth = credential.authentication
                    directory.requests[index].draft.variables.merge(credential.variables) { _, saved in saved }
                }
            }
            workspace.directory = directory
        }
        workspace.encryptedCredentials = nil
    }

    private func loadFileKey(create: Bool) throws -> SymmetricKey {
        do {
            let data = try Data(contentsOf: keyFile)
            guard data.count == 32 else { throw KeyFileError.invalid }
            return SymmetricKey(data: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            guard create else { throw KeyFileError.missing }
            let key = SymmetricKey(size: .bits256)
            try writeFileKey(key)
            return key
        }
    }

    private func writeFileKey(_ key: SymmetricKey) throws {
        try createFolder()
        let files = FileManager.default
        let temporary = keyFile.deletingLastPathComponent().appendingPathComponent(".workspace-key-\(UUID())")
        guard files.createFile(atPath: temporary.path, contents: key.withUnsafeBytes { Data($0) },
                               attributes: [.posixPermissions: 0o600]) else { throw KeyFileError.write }
        defer { try? files.removeItem(at: temporary) }
        try files.linkItem(at: temporary, to: keyFile)
    }

    private func createFolder() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    func save(_ workspace: Workspace) throws {
        guard !workspace.credentialsLocked else { throw KeyFileError.missing }
        var persisted = workspace
        for environment in persisted.environments.indices {
            for variable in persisted.environments[environment].variables.indices
                where persisted.environments[environment].variables[variable].sessionOnly {
                persisted.environments[environment].variables[variable].value = ""
            }
        }
        for entry in persisted.history.indices {
            persisted.history[entry].request = persisted.history[entry].request.withoutStoredAuthentication()
        }
        var credentials: [UUID: RequestCredentials] = [:]
        if var directory = persisted.directory {
            for index in directory.requests.indices {
                let request = directory.requests[index]
                let redacted = request.draft.withoutStoredAuthentication()
                if redacted != request.draft {
                    let variables = request.draft.variables.filter { redacted.variables[$0.key] == nil }
                    credentials[request.id] = RequestCredentials(authentication: request.draft.auth, variables: variables)
                    directory.requests[index].draft = redacted
                }
            }
            persisted.directory = directory
        }
        if !credentials.isEmpty {
            let data = try JSONEncoder().encode(credentials)
            let key = try key(create: true)
            persisted.encryptedCredentials = try AES.GCM.seal(data, using: key).combined
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(persisted)
        try createFolder()
        try data.write(to: file, options: .atomic)
    }

    private enum KeyFileError: LocalizedError {
        case missing, invalid, write

        var errorDescription: String? {
            switch self {
            case .missing: return "旧版认证尚未迁移，无法写入工作区。"
            case .invalid: return "工作区的本地密钥文件格式不正确。"
            case .write: return "无法保存工作区的本地密钥文件。"
            }
        }
    }
}

private struct RequestCredentials: Codable {
    var authentication: RequestAuthentication
    var variables: [String: String]
}

enum WorkspaceCredentialKey {
    static func loadLegacy() throws -> SymmetricKey {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.celeste-lingshi.apidog.workspace",
            kSecAttrAccount as String: "工作区加密密钥",
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        guard status == errSecSuccess else { throw KeychainError.access(status) }
        guard let data = result as? Data, data.count == 32 else { throw KeychainError.invalidKey }
        return SymmetricKey(data: data)
    }

    private enum KeychainError: LocalizedError {
        case access(OSStatus), invalidKey

        var errorDescription: String? {
            switch self {
            case .access(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? String(status)
                return "无法访问 ApiDog 的钥匙串密钥。\(detail)"
            case .invalidKey:
                return "ApiDog 的钥匙串密钥格式不正确。"
            }
        }
    }
}
