import Foundation

enum HTTPMethod: String, Codable, CaseIterable {
    case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE"
    case head = "HEAD", options = "OPTIONS"

    var allowsBody: Bool { self != .get && self != .head }
}

struct RequestDraft: Codable, Equatable {
    var method: HTTPMethod = .get
    var url = ""
    var headers = ""
    var body = ""

    private static let variableName = "[A-Za-z_][A-Za-z0-9_.-]*"
    private static let placeholder = try! NSRegularExpression(
        pattern: #"\{\{\s*("# + variableName + #")\s*\}\}"#
    )

    static func isVariableName(_ value: String) -> Bool {
        value.range(of: "\\A" + variableName + "\\z", options: .regularExpression) != nil
    }

    func makeRequest(variables: [String: String]) throws -> URLRequest {
        let address = try expand(url, variables: variables).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let destination = components.url else {
            throw RequestError.invalidURL
        }

        var request = URLRequest(url: destination, timeoutInterval: 30)
        request.httpMethod = method.rawValue
        let headerName = #"\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z"#
        for (index, line) in headers.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard parts.count == 2, name.range(of: headerName, options: .regularExpression) != nil else {
                throw RequestError.invalidHeader(index + 1)
            }
            let value = try expand(parts[1].trimmingCharacters(in: .whitespaces), variables: variables)
            guard value.unicodeScalars.allSatisfy({ $0 == "\t" || !CharacterSet.controlCharacters.contains($0) }) else {
                throw RequestError.invalidHeader(index + 1)
            }
            request.addValue(value, forHTTPHeaderField: name)
        }
        if method.allowsBody && !body.isEmpty {
            request.httpBody = Data(try expand(body, variables: variables).utf8)
        }
        return request
    }

    private func expand(_ text: String, variables: [String: String]) throws -> String {
        let original = text as NSString
        let expanded = NSMutableString(string: text)
        for match in Self.placeholder.matches(in: text, range: NSRange(location: 0, length: original.length)).reversed() {
            let name = original.substring(with: match.range(at: 1))
            guard let value = variables[name] else { throw RequestError.missingVariable(name) }
            expanded.replaceCharacters(in: match.range, with: value)
        }
        return expanded as String
    }
}

enum RequestError: LocalizedError {
    case invalidURL, invalidHeader(Int), missingVariable(String), nonHTTPResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入完整的 HTTP 或 HTTPS 地址。"
        case .invalidHeader(let line): return "第 \(line) 行请求头格式不正确，请使用「名称: 值」。"
        case .missingVariable(let name): return "当前环境没有可用的变量「\(name)」。"
        case .nonHTTPResponse: return "服务端没有返回 HTTP 响应。"
        }
    }
}

struct ResponseDetails {
    var status: Int
    var headers: String
    var body: String
    var byteCount: Int
    var truncated: Bool
}

final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum HTTPClient {
    static let responseLimit = 256 * 1024

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    static func send(_ request: URLRequest, using session: URLSession = HTTPClient.session) async throws -> ResponseDetails {
        let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirect())
        guard let http = response as? HTTPURLResponse else { throw RequestError.nonHTTPResponse }

        var data = Data()
        var truncated = false
        for try await byte in bytes {
            if data.count == responseLimit {
                truncated = true
                bytes.task.cancel()
                break
            }
            data.append(byte)
        }

        let headers = http.allHeaderFields.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
        return ResponseDetails(
            status: http.statusCode,
            headers: headers,
            body: displayBody(data, mimeType: http.mimeType, truncated: truncated),
            byteCount: data.count,
            truncated: truncated
        )
    }

    static func displayBody(_ data: Data, mimeType: String?, truncated: Bool) -> String {
        guard !data.isEmpty else { return "" }
        let type = (mimeType ?? "").lowercased()
        if !truncated, let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let formatted = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .fragmentsAllowed, .withoutEscapingSlashes]) {
            return String(decoding: formatted, as: UTF8.self)
        }
        let isText = type.hasPrefix("text/") || type.contains("json") || type.contains("xml")
        if isText { return String(decoding: data, as: UTF8.self) }
        if type.isEmpty, let text = String(data: data, encoding: .utf8) { return text }
        return "二进制响应（\(type.isEmpty ? "未知类型" : type)）"
    }
}
