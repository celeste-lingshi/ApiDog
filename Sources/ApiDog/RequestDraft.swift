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
        case none, bearer, basic, apiKey

        var title: String {
            switch self {
            case .none: return "无认证"
            case .bearer: return "Bearer Token"
            case .basic: return "Basic"
            case .apiKey: return "API Key"
            }
        }
    }

    var mode: Mode = .none
    var name = ""
    var secret: String?
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
        if auth.mode != .none { inputs += [auth.name, auth.secret ?? ""] }
        if method.allowsBody, let body { inputs.append(body) }
        var seen = Set<String>()
        return inputs.flatMap { Self.matches(in: $0).map(\.name) }.filter { seen.insert($0).inserted }
    }

    func makeRequest() throws -> URLRequest {
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
        if let field = try authenticationHeader() {
            guard let value = field.value, Self.validHeader(field.name, value) else {
                throw RequestError.invalidAuthentication
            }
            guard request.value(forHTTPHeaderField: field.name) == nil else {
                throw RequestError.duplicateAuthentication(field.name)
            }
            request.setValue(value, forHTTPHeaderField: field.name)
        }
        if method.allowsBody, let body {
            let text = try expand(body)
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
        for match in Self.matches(in: auth.secret ?? "") {
            request.variables.removeValue(forKey: match.name)
        }
        request.auth.secret = nil
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

    private func authenticationHeader() throws -> RequestField? {
        guard auth.mode != .none else { return nil }
        let name = try expand(auth.name).trimmingCharacters(in: .whitespaces)
        guard let source = auth.secret else { throw RequestError.invalidAuthentication }
        let secret = try expand(source)
        switch auth.mode {
        case .none: return nil
        case .bearer:
            guard !secret.isEmpty else { throw RequestError.invalidAuthentication }
            return RequestField("Authorization", "Bearer " + secret)
        case .basic:
            guard !name.isEmpty, !name.contains(":") else { throw RequestError.invalidAuthentication }
            return RequestField("Authorization", "Basic " + Data((name + ":" + secret).utf8).base64EncodedString())
        case .apiKey:
            guard !name.isEmpty, !secret.isEmpty else { throw RequestError.invalidAuthentication }
            return RequestField(name, secret)
        }
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

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入完整的 HTTP 或 HTTPS 地址。"
        case .invalidHeader(let row): return "请检查第 \(row) 行请求头的名称和值。"
        case .invalidBody: return "请求体不能包含 NUL 字符。"
        case .missingVariable(let name): return "请在变量页填写「\(name)」。"
        case .invalidAuthentication: return "请检查认证的字段和值。"
        case .duplicateAuthentication(let name): return "认证与手动填写的「\(name)」请求头重复。"
        case .nonHTTPResponse: return "服务端没有返回 HTTP 响应。"
        }
    }
}
