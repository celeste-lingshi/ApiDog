import Foundation

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
}

struct Workspace: Codable, Equatable {
    var environments: [RequestEnvironment] = []
    var selectedEnvironmentID: UUID?
    var history: [HistoryEntry] = []
    var directory: RequestDirectory?

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

struct WorkspaceStorage {
    var file: URL

    static let local = WorkspaceStorage(file: URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/ApiDog/workspace.json"))

    func load() throws -> Workspace {
        do {
            let data = try Data(contentsOf: file)
            return try JSONDecoder().decode(Workspace.self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Workspace()
        }
    }

    func save(_ workspace: Workspace) throws {
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
        if var directory = persisted.directory {
            for index in directory.requests.indices {
                directory.requests[index].draft = directory.requests[index].draft.withoutStoredAuthentication()
            }
            persisted.directory = directory
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(persisted)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: file, options: .atomic)
    }
}
