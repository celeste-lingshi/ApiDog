import Foundation

@main
struct Checks {
    static func main() async throws {
        try checkRequest()
        try checkWorkspace()
        try await checkResponse()
        try await checkCancellation()
        print("通过：请求模板、历史保存与搜索、临时变量、响应展示与大小限制、请求取消")
    }

    static func checkRequest() throws {
        let draft = RequestDraft(
            method: .post, url: "{{ baseUrl }}/users?limit={{count}}",
            headers: "Authorization: Bearer {{token}}\nContent-Type: application/json\nX-Tag: one:two",
            body: #"{"user":"{{user}}"}"#
        )
        let request = try draft.makeRequest(variables: [
            "baseUrl": "https://example.com", "count": "2", "token": "{{literal}}", "user": "小明",
        ])
        precondition(request.url?.absoluteString == "https://example.com/users?limit=2")
        precondition(request.httpMethod == "POST")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer {{literal}}")
        precondition(request.value(forHTTPHeaderField: "X-Tag") == "one:two")
        precondition(request.httpBody == Data(#"{"user":"小明"}"#.utf8))

        for invalid in [
            RequestDraft(url: "file:///tmp/example"),
            RequestDraft(url: "{{missing}}"),
            RequestDraft(url: "https://example.com", headers: "X-Tag: {{value}}"),
        ] {
            do {
                _ = try invalid.makeRequest(variables: ["value": "one\r\nX-Other: two"])
                preconditionFailure("接受了无效的请求")
            } catch is RequestError {}
        }
        precondition(RequestDraft.isVariableName("token.qa-2"))
        precondition(!RequestDraft.isVariableName("token\n"))
        let get = try RequestDraft(url: "http://localhost:8080", body: "{{unused}}").makeRequest(variables: [:])
        precondition(get.httpBody == nil)
    }

    static func checkWorkspace() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = WorkspaceStorage(file: folder.appendingPathComponent("workspace.json"))
        var workspace = try storage.load()
        workspace.environments[0].variables = [
            EnvironmentVariable(name: "baseUrl", value: "https://example.com"),
            EnvironmentVariable(name: "token", value: "example-session-secret", sessionOnly: true),
        ]
        workspace.selectedEnvironmentID = workspace.environments[0].id

        for index in 0...100 {
            workspace.append(HistoryEntry(
                date: Date(timeIntervalSince1970: TimeInterval(index)),
                request: RequestDraft(url: "{{baseUrl}}/\(index)", headers: "Authorization: Bearer {{token}}"),
                environment: "默认", status: 200, milliseconds: index
            ))
        }
        try storage.save(workspace)

        let reloaded = try storage.load()
        let contents = try String(contentsOf: storage.file, encoding: .utf8)
        precondition(reloaded.selectedEnvironment?.values == ["baseUrl": "https://example.com"])
        precondition(workspace.selectedEnvironment?.values["token"] == "example-session-secret")
        precondition(reloaded.history.count == 100)
        precondition(reloaded.history.first?.request.url == "{{baseUrl}}/100")
        precondition(reloaded.history.last?.request.url == "{{baseUrl}}/1")
        precondition(reloaded.history.first?.request.headers == "Authorization: Bearer {{token}}")
        precondition(reloaded.matchingHistory(" 200 ").count == 100)
        precondition(reloaded.matchingHistory("get").count == 100)
        precondition(reloaded.matchingHistory("默认").count == 100)
        precondition(reloaded.matchingHistory("/100").first?.request.url == "{{baseUrl}}/100")
        precondition(reloaded.matchingHistory("404").isEmpty)
        precondition(!contents.contains("example-session-secret"))
    }

    static func checkCancellation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (started, signal) = AsyncStream<Void>.makeStream()
        FixtureProtocol.onWait = {
            signal.yield(())
            signal.finish()
        }
        defer { FixtureProtocol.onWait = nil }

        let request = try RequestDraft(url: "https://example.com/wait").makeRequest(variables: [:])
        let pending = Task { try await HTTPClient.send(request, using: session) }
        for await _ in started {
            pending.cancel()
            break
        }
        do {
            _ = try await pending.value
            preconditionFailure("取消后仍收到响应")
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        }
    }

    static func checkResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let json = try RequestDraft(url: "https://example.com/json").makeRequest(variables: [:])
        let result = try await HTTPClient.send(json, using: session)
        precondition(result.status == 418)
        precondition(result.headers.lowercased().contains("content-type: application/json"))
        precondition(result.body.contains("\n") && result.body.contains("ok"))
        precondition(!result.truncated)

        let large = try RequestDraft(url: "https://example.com/large").makeRequest(variables: [:])
        let clipped = try await HTTPClient.send(large, using: session)
        precondition(clipped.truncated && clipped.byteCount == HTTPClient.responseLimit)
        precondition(clipped.body.utf8.count == HTTPClient.responseLimit)

        let binary = HTTPClient.displayBody(Data([0, 255]), mimeType: "application/octet-stream", truncated: false)
        precondition(binary == "二进制响应（application/octet-stream）")
    }
}

final class FixtureProtocol: URLProtocol {
    static var onWait: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.path == "/wait" {
            Self.onWait?()
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: 418, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": url.path == "/large" ? "text/plain" : "application/json"]
              ) else {
            preconditionFailure("无法构造测试响应")
        }
        let body = url.path == "/large"
            ? Data(repeating: 97, count: HTTPClient.responseLimit + 1)
            : Data(#"{"ok":true}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
