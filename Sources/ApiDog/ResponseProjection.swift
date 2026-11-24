import Foundation

struct ResponseProjection {
    private struct Step {
        var key: String
        var array: Bool
        var optional: Bool
    }

    private let steps: [Step]

    init(_ expression: String) throws {
        if expression == "." {
            steps = []
            return
        }
        let parts = expression.split(separator: ".", omittingEmptySubsequences: false).dropFirst()
        guard expression.hasPrefix("."), !parts.isEmpty else { throw ProjectionError.syntax }
        steps = try parts.map { part in
            let optional = part.hasSuffix("?")
            let field = optional ? part.dropLast() : part[...]
            let array = field.hasSuffix("[]")
            let key = array ? field.dropLast(2) : field[...]
            guard key.range(of: #"\A[a-zA-Z_][a-zA-Z0-9_]*\z"#, options: .regularExpression) != nil else {
                throw ProjectionError.syntax
            }
            return Step(key: String(key), array: array, optional: optional)
        }
    }

    func format(_ body: String) throws -> String {
        guard let value = try? JSONSerialization.jsonObject(with: Data(body.utf8), options: .fragmentsAllowed) else {
            throw ProjectionError.json
        }
        var values: [Any] = [value]
        for step in steps {
            values = try values.flatMap { item -> [Any] in
                let field: Any
                if let object = item as? [String: Any] {
                    field = object[step.key] ?? NSNull()
                } else if item is NSNull {
                    field = NSNull()
                } else if step.optional {
                    return []
                } else {
                    throw ProjectionError.type
                }
                if !step.array { return [field] }
                if let entries = field as? [Any] { return entries }
                if let entries = field as? [String: Any] { return entries.keys.sorted().compactMap { entries[$0] } }
                if step.optional { return [] }
                throw ProjectionError.type
            }
        }
        return try values.map { value in
            if let text = value as? String { return text }
            return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
                          as: UTF8.self)
        }.joined(separator: "\n")
    }
}

enum ProjectionError: LocalizedError {
    case syntax, json, type, truncated

    var errorDescription: String? {
        switch self {
        case .syntax: return "提取表达式支持简单字段路径，例如 .reason[]?.port。"
        case .json: return "只有完整的 JSON 响应可以提取字段。"
        case .truncated: return "响应已截断，请到正文页查看已收到的内容。"
        case .type: return "响应字段类型与提取表达式不匹配。"
        }
    }
}
