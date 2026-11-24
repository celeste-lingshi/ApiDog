import Foundation

struct RequestField: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var value: String? = ""

    init(_ name: String = "", _ value: String? = "") {
        self.name = name
        self.value = value
    }

    static func header(_ text: String) -> Self? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        return Self(String(text[..<colon]).trimmingCharacters(in: .whitespaces),
                    String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
    }
}

struct RequestAuthentication: Codable, Equatable {
    enum Mode: String, CaseIterable, Codable {
        case none, bearer, basic, apiKey, hmac, script

        var title: String {
            switch self {
            case .none: return "无认证"
            case .bearer: return "Bearer Token"
            case .basic: return "Basic"
            case .apiKey: return "API Key"
            case .hmac: return "HMAC-SHA256 签名"
            case .script: return "自定义 JavaScript"
            }
        }
    }

    enum Location: String, Codable, CaseIterable {
        case query, header, body

        var title: String {
            switch self {
            case .query: return "URL 查询"
            case .header: return "请求头"
            case .body: return "JSON 请求体"
            }
        }
    }

    var mode: Mode = .none
    var name = ""
    var secret: String?
    var placement: Location?
    var signingURI: String?
    var script: String?
    var scriptInputs: [RequestField]?

    var location: Location { placement ?? (mode == .hmac ? .query : .header) }
    var generated: Bool { mode == .hmac || mode == .script }

}

struct RequestDraft: Codable, Equatable {
    var method: HTTPMethod = .get
    var url = ""
    var headers: [RequestField] = []
    var query: [RequestField] = []
    var variables: [String: String] = [:]
    var auth = RequestAuthentication()
    var body: String?
    var followsRedirects = false

    private static let variableName = "[A-Za-z_][A-Za-z0-9_.-]*"
    private static let placeholder = try! NSRegularExpression(
        pattern: #"\{\{\s*("# + variableName + #")\s*\}\}|\{("# + variableName + #")\}"#
    )
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private enum CodingKeys: String, CodingKey { case method, url, headers, query, variables, auth, body, followsRedirects }

    init(method: HTTPMethod = .get, url: String = "", headers: [RequestField] = [], query: [RequestField] = [],
         variables: [String: String] = [:], auth: RequestAuthentication = .init(), body: String? = nil,
         followsRedirects: Bool = false) {
        self.method = method
        self.url = url
        self.headers = headers
        self.query = query
        self.variables = variables
        self.auth = auth
        self.body = body
        self.followsRedirects = followsRedirects
    }

    init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        method = try data.decode(HTTPMethod.self, forKey: .method)
        url = try data.decode(String.self, forKey: .url)
        if let fields = try? data.decode([RequestField].self, forKey: .headers) {
            headers = fields
            body = try data.decodeIfPresent(String.self, forKey: .body)
        } else {
            let legacy = try data.decode(String.self, forKey: .headers)
            headers = legacy.split(whereSeparator: \.isNewline).map { line in
                RequestField.header(String(line)) ?? RequestField(String(line))
            }
            let text = try data.decodeIfPresent(String.self, forKey: .body)
            body = text == "" ? nil : text
        }
        query = try data.decodeIfPresent([RequestField].self, forKey: .query) ?? []
        variables = try data.decodeIfPresent([String: String].self, forKey: .variables) ?? [:]
        auth = try data.decodeIfPresent(RequestAuthentication.self, forKey: .auth) ?? .init()
        followsRedirects = try data.decodeIfPresent(Bool.self, forKey: .followsRedirects) ?? false
    }

    var variableNames: [String] {
        var inputs = [url] + (query + headers).flatMap { [$0.name, $0.value ?? ""] }
        if auth.mode != .none { inputs += [auth.name, auth.secret ?? "", auth.signingURI ?? ""] }
        if auth.mode == .script { inputs += (auth.scriptInputs ?? []).compactMap(\.value) }
        if method.allowsBody, let body { inputs.append(body) }
        var seen = Set<String>()
        return inputs.flatMap { Self.matches(in: $0).map(\.name) }.filter { seen.insert($0).inserted }
    }

    func prepareRequest() async throws -> URLRequest {
        try Task.checkCancellation()
        if auth.mode == .script {
            return try await Task.detached { try makeRequest() }.value
        }
        return try makeRequest()
    }

    func makeRequest(at date: Date = .now) throws -> URLRequest {
        let address = try expand(url, encodeSegments: true).trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else {
            throw RequestError.invalidURL
        }
        let items = try query.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }.map { field in
            let name = Self.percentEncode(try expand(field.name))
            guard let value = field.value else { return name }
            return name + "=" + Self.percentEncode(try expand(value))
        }
        if !items.isEmpty {
            let existing = [components.percentEncodedQuery].compactMap { $0 }.filter { !$0.isEmpty }
            components.percentEncodedQuery = (existing + items).joined(separator: "&")
        }
        components.fragment = nil
        guard let destination = components.url else { throw RequestError.invalidURL }

        var request = URLRequest(url: destination, timeoutInterval: 30)
        request.httpMethod = method.rawValue
        for (index, field) in headers.enumerated() {
            let name = try expand(field.name).trimmingCharacters(in: .whitespaces)
            let value = try expand(field.value ?? "").trimmingCharacters(in: .whitespaces)
            if name.isEmpty && value.isEmpty { continue }
            guard Self.validHeader(name, value) else { throw RequestError.invalidHeader(index + 1) }
            request.addValue(value, forHTTPHeaderField: name)
        }
        var expandedBody = method.allowsBody ? try body.map { try expand($0) } : nil
        if auth.mode != .none {
            let generated = try authenticationFields(components: components, request: request, body: expandedBody,
                                                     timestamp: String(Int(date.timeIntervalSince1970)))
            for (name, value) in generated.headers.sorted(by: { $0.key < $1.key }) {
                guard Self.validHeader(name, value) else { throw RequestError.invalidAuthentication }
                guard request.value(forHTTPHeaderField: name) == nil else {
                    throw RequestError.duplicateAuthentication(name)
                }
                request.setValue(value, forHTTPHeaderField: name)
            }

            if !generated.query.isEmpty {
                let existing = Set((components.queryItems ?? []).map(\.name))
                var items: [String] = []
                for (name, value) in generated.query.sorted(by: { $0.key < $1.key }) {
                    guard !name.isEmpty else { throw RequestError.invalidAuthOutput }
                    guard !existing.contains(name) else { throw RequestError.duplicateAuthentication(name) }
                    items.append(Self.percentEncode(name) + "=" + Self.percentEncode(value))
                }
                let prior = [components.percentEncodedQuery].compactMap { $0 }.filter { !$0.isEmpty }
                components.percentEncodedQuery = (prior + items).joined(separator: "&")
                guard let signedURL = components.url else { throw RequestError.invalidURL }
                request.url = signedURL
            }

            if !generated.body.isEmpty {
                guard method.allowsBody else { throw RequestError.invalidAuthBody }
                var object: [String: Any] = [:]
                if let expandedBody, !expandedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard let original = (try? JSONSerialization.jsonObject(with: Data(expandedBody.utf8))) as? [String: Any] else {
                        throw RequestError.invalidAuthBody
                    }
                    object = original
                }
                for (name, value) in generated.body {
                    guard !name.isEmpty else { throw RequestError.invalidAuthOutput }
                    guard object[name] == nil else { throw RequestError.duplicateAuthentication(name) }
                    object[name] = value
                }
                let merged = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                expandedBody = String(decoding: merged, as: UTF8.self)
            }
        }

        if let text = expandedBody {
            guard !text.contains("\0") else { throw RequestError.invalidBody }
            let content = Data(text.utf8)
            request.httpBody = content
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                let json = (try? JSONSerialization.jsonObject(with: content, options: .fragmentsAllowed)) != nil
                request.setValue(json ? "application/json" : "text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
        }
        return request
    }

    func withoutStoredAuthentication() -> Self {
        var request = self
        var protected = [auth.secret ?? ""] + (auth.scriptInputs ?? []).compactMap(\.value)
        if auth.mode == .hmac {
            protected.append(auth.name)
            request.auth.name = ""
        }
        for value in protected {
            for match in Self.matches(in: value) {
                request.variables.removeValue(forKey: match.name)
            }
        }
        request.auth.secret = nil
        request.auth.scriptInputs = auth.scriptInputs?.map { field in
            var field = field
            field.value = nil
            return field
        }
        return request
    }

    static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func validHeader(_ name: String, _ value: String) -> Bool {
        let headerName = #"\A[!#$%&'*+.^_\x60|~0-9A-Za-z-]+\z"#
        return name.range(of: headerName, options: .regularExpression) != nil
            && value.unicodeScalars.allSatisfy { $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }
    }

    private func authenticationFields(components: URLComponents, request: URLRequest, body: String?,
                                      timestamp: String) throws -> GeneratedAuthFields {
        var fields = GeneratedAuthFields()
        let path = components.percentEncodedPath
        let uri = path.isEmpty ? "/" : path

        if auth.mode == .script {
            var inputs: [String: String] = [:]
            for field in auth.scriptInputs ?? [] {
                let name = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty, (field.value ?? "").isEmpty { continue }
                guard !name.isEmpty, inputs[name] == nil else { throw RequestError.invalidAuthInput }
                guard let value = field.value, !value.isEmpty else { throw RequestError.missingAuthInput(name) }
                inputs[name] = try expand(value)
            }
            let context = AuthScript.Context(
                method: method.rawValue, url: request.url?.absoluteString ?? "", uri: uri,
                query: (components.queryItems ?? []).map { .init(name: $0.name, value: $0.value) },
                headers: request.allHTTPHeaderFields ?? [:], body: body ?? ""
            )
            return try AuthScript(source: auth.script ?? AuthScript.example, inputs: inputs,
                                  request: context, timestamp: timestamp).run()
        }

        let name = try expand(auth.name).trimmingCharacters(in: .whitespaces)
        guard let source = auth.secret else { throw RequestError.invalidAuthentication }
        let secret = try expand(source)
        switch auth.mode {
        case .none, .script: break
        case .bearer:
            guard !secret.isEmpty else { throw RequestError.invalidAuthentication }
            fields.headers["Authorization"] = "Bearer " + secret
        case .basic:
            guard !name.isEmpty, !name.contains(":") else { throw RequestError.invalidAuthentication }
            fields.headers["Authorization"] = "Basic " + Data((name + ":" + secret).utf8).base64EncodedString()
        case .apiKey:
            guard !name.isEmpty, !secret.isEmpty else { throw RequestError.invalidAuthentication }
            fields.place(secret, as: name, at: auth.location)
        case .hmac:
            guard !name.isEmpty, !secret.isEmpty else { throw RequestError.invalidAuthentication }
            let override = (auth.signingURI ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let signedURI = override.isEmpty ? uri : try expand(override)
            let message = [name, secret, signedURI, timestamp].joined(separator: "_")
            fields.query["timestamp"] = timestamp
            fields.place(name, as: "apikey", at: auth.location)
            fields.place(AuthCrypto.hmacBase64URL(secret, message), as: "sign", at: auth.location)
        }
        return fields
    }

    private static func matches(in text: String) -> [(range: NSRange, name: String, single: Bool)] {
        let original = text as NSString
        return placeholder.matches(in: text, range: NSRange(location: 0, length: original.length)).map { match in
            let single = match.range(at: 1).location == NSNotFound
            return (match.range, original.substring(with: match.range(at: single ? 2 : 1)), single)
        }
    }

    private func expand(_ text: String, encodeSegments: Bool = false) throws -> String {
        let expanded = NSMutableString(string: text)
        for match in Self.matches(in: text).reversed() {
            guard let value = variables[match.name], !value.isEmpty else { throw RequestError.missingVariable(match.name) }
            expanded.replaceCharacters(in: match.range, with: encodeSegments && match.single ? Self.percentEncode(value) : value)
        }
        return expanded as String
    }
}

enum RequestError: LocalizedError {
    case invalidURL, invalidHeader(Int), invalidBody, missingVariable(String), invalidAuthentication, duplicateAuthentication(String), nonHTTPResponse

    case invalidAuthInput, missingAuthInput(String), invalidAuthOutput, invalidAuthBody
    case authWorkerUnavailable, authScriptSize, authScriptInterrupted, authScript(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入完整的 HTTP 或 HTTPS 地址。"
        case .invalidHeader(let row): return "请检查第 \(row) 行请求头的名称和值。"
        case .invalidBody: return "请求体不能包含 NUL 字符。"
        case .missingVariable(let name): return "请在变量页填写「\(name)」。"
        case .invalidAuthentication: return "请检查认证的字段和值。"
        case .duplicateAuthentication(let name): return "生成的认证字段「\(name)」与当前请求重复。"
        case .invalidAuthInput: return "请为每项脚本输入填写唯一的名称。"
        case .missingAuthInput(let name): return "请填写脚本输入「\(name)」。"
        case .invalidAuthOutput: return "脚本需要返回对象，headers 和 query 的值须为字符串，body 须为 JSON 对象。"
        case .invalidAuthBody: return "请使用允许正文的请求方法，并提供一个 JSON 对象正文。"
        case .authWorkerUnavailable: return "无法启动或读取认证脚本进程。"
        case .authScriptSize: return "脚本输入或输出超过大小限制。"
        case .authScriptInterrupted: return "认证脚本运行超时或异常中止。"
        case .authScript(let reason): return "认证脚本：\(reason)"
        case .nonHTTPResponse: return "服务端没有返回 HTTP 响应。"
        }
    }
}
