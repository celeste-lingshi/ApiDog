import Foundation

enum HTTPMethod: String, Codable, CaseIterable {
    case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE"
    case head = "HEAD", options = "OPTIONS"

    var allowsBody: Bool { self != .get && self != .head }
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

    static func send(_ request: URLRequest, followsRedirects: Bool = false, using session: URLSession = HTTPClient.session) async throws -> ResponseDetails {
        let (bytes, response) = try await session.bytes(for: request, delegate: followsRedirects ? nil : NoRedirect())
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
