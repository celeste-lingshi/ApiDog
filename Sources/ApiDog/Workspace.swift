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

    var isValid: Bool {
        let names = variables.map(\.name)
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && names.allSatisfy(RequestDraft.isVariableName)
            && Set(names).count == names.count
    }
}

struct HistoryEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var date: Date
    var request: RequestDraft
    var environment: String
    var status: Int?
    var milliseconds: Int
}

struct Workspace: Codable, Equatable {
    var environments = [RequestEnvironment(name: "默认")]
    var selectedEnvironmentID: UUID?
    var history: [HistoryEntry] = []

    var selectedEnvironment: RequestEnvironment? {
        environments.first { $0.id == selectedEnvironmentID } ?? environments.first
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
