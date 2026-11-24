import Foundation

@main
struct Checks {
    static func main() async throws {
        if AuthScript.runWorkerIfRequested() { return }
        try checkRequest()
        try checkWorkspace()
        try checkCurl()
        try checkGeneratedAuthentication()
        try await checkResponse()
        try await checkCancellation()
        print("通过：请求内变量和认证、旧历史读取、凭证落盘、签名、脚本认证、cURL 导入导出、响应处理、请求取消")
    }

    static func checkRequest() throws {
        var draft = RequestDraft(
            method: .post,
            url: "{{baseUrl}}/{hostname}/ping?existing=1",
            headers: [RequestField("X-Tag", "one:two"), RequestField("X-Node", "{hostname}")],
            query: [RequestField("search", "a+b /"), RequestField("verbose", nil)],
            variables: ["baseUrl": "https://example.com", "hostname": "node/a b", "user": "小明"],
            auth: RequestAuthentication(mode: .bearer, secret: "abc"),
            body: #"{"user":"{{user}}"}"#
        )
        precondition(draft.variableNames == ["baseUrl", "hostname", "user"])
        let request = try draft.makeRequest()
        precondition(request.url?.absoluteString == "https://example.com/node%2Fa%20b/ping?existing=1&search=a%2Bb%20%2F&verbose")
        precondition(request.httpMethod == "POST")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        precondition(request.value(forHTTPHeaderField: "X-Tag") == "one:two")
        precondition(request.value(forHTTPHeaderField: "X-Node") == "node/a b")
        precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        precondition(request.httpBody == Data(#"{"user":"小明"}"#.utf8))

        draft.headers.append(RequestField("authorization", "duplicate"))
        do {
            _ = try draft.makeRequest()
            preconditionFailure("接受了重复的认证头")
        } catch RequestError.duplicateAuthentication {}
        for invalid in [
            RequestDraft(url: "file:///tmp/example"),
            RequestDraft(url: "https://example.com/{missing}"),
            RequestDraft(url: "https://example.com", headers: [RequestField("X-Tag", "one\r\nX-Other: two")]),
            RequestDraft(url: "https://example.com", auth: RequestAuthentication(mode: .basic, name: "user")),
        ] {
            do {
                _ = try invalid.makeRequest()
                preconditionFailure("接受了无效的请求")
            } catch is RequestError {}
        }
        let get = try RequestDraft(url: "http://localhost:8080", body: "{{unused}}").makeRequest()
        precondition(get.httpBody == nil)
    }

    static func checkWorkspace() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let storage = WorkspaceStorage(file: folder.appendingPathComponent("workspace.json"))
        let old = """
        {"environments":[{"id":"FFCE3B3C-1FA5-451F-BD3A-368744372903","name":"测试","variables":[
        {"id":"AB313D23-30CE-4F36-9DAF-92EE59EEC283","name":"base","value":"https://example.com","sessionOnly":false}
        ]}],"history":[{"id":"49521399-CCF6-4349-AA1D-8020437C0208","date":0,
        "request":{"method":"GET","url":"{{base}}/ping","headers":"X-Legacy: one:two","body":""},
        "environment":"测试","status":200,"milliseconds":20}]}
        """
        try Data(old.utf8).write(to: storage.file)
        var workspace = try storage.load()
        let legacy = workspace.draft(for: workspace.history[0])
        let oldRequest = try legacy.makeRequest()
        precondition(oldRequest.url?.absoluteString == "https://example.com/ping")
        precondition(oldRequest.value(forHTTPHeaderField: "X-Legacy") == "one:two")
        precondition(legacy.body == nil)

        for index in 0...100 {
            workspace.append(HistoryEntry(
                date: Date(timeIntervalSince1970: TimeInterval(index)),
                request: RequestDraft(
                    url: "https://example.com/{hostname}/\(index)",
                    variables: ["hostname": "node-a", "token": "sample-credential"],
                    auth: RequestAuthentication(mode: .bearer, secret: "{token}")
                ),
                status: 200, milliseconds: index
            ))
        }
        try storage.save(workspace)
        let reloaded = try storage.load()
        let contents = try String(contentsOf: storage.file, encoding: .utf8)
        precondition(workspace.history[0].request.auth.secret == "{token}")
        precondition(reloaded.history.count == 100)
        precondition(reloaded.history[0].request.variables == ["hostname": "node-a"])
        precondition(reloaded.history[0].request.auth.mode == .bearer && reloaded.history[0].request.auth.secret == nil)
        precondition(reloaded.history.last?.request.url.hasSuffix("/1") == true)
        precondition(reloaded.matchingHistory(" 200 ").count == 100)
        precondition(reloaded.matchingHistory("get").count == 100)
        precondition(reloaded.matchingHistory("404").isEmpty)
        precondition(!contents.contains("sample-credential"))
    }

    static func checkCurl() throws {
        let copied = #"""
        curl --location 'https://example.com/ping?q=one%2Btwo&flag&n=1&n=2' \
          -H 'Content-Type: application/json' \
          -H 'Authorization: Bearer abc' \
          -H 'X-Note: It'\''s there' \
          --data-raw '{"ok":true,"text":"$literal"}'
        """#
        let parsed = try CurlCommand.parse(copied)
        let request = try parsed.makeRequest()
        precondition(parsed.method == .post && parsed.followsRedirects)
        precondition(parsed.auth.mode == .bearer && parsed.auth.secret == "abc")
        precondition(parsed.query.map(\.name) == ["q", "flag", "n", "n"])
        precondition(parsed.query[1].value == nil)
        precondition(request.value(forHTTPHeaderField: "X-Note") == "It's there")
        let command = CurlCommand.render(request, followsRedirects: parsed.followsRedirects)
        let roundTrip = try CurlCommand.parse(command).makeRequest()
        precondition(roundTrip.url == request.url && roundTrip.httpMethod == request.httpMethod)
        precondition(roundTrip.allHTTPHeaderFields == request.allHTTPHeaderFields)
        precondition(roundTrip.httpBody == request.httpBody)

        let query = try CurlCommand.parse("curl -G --data-urlencode 'title=a+b /' https://example.com")
        let queryRequest = try query.makeRequest()
        precondition(query.query.count == 1 && query.query[0].value == "a+b /")
        precondition(queryRequest.url?.absoluteString == "https://example.com?title=a%2Bb%20%2F")
        let head = try CurlCommand.parse("curl -I --user 'demo:' 'https://example.com'")
        let headRequest = try head.makeRequest()
        precondition(head.method == .head && headRequest.value(forHTTPHeaderField: "Authorization") == "Basic ZGVtbzo=")
        precondition(CurlCommand.render(headRequest, followsRedirects: false).contains("--head"))
        let apiKey = try CurlCommand.parse("curl -H 'X-API-Key: token' https://example.com")
        precondition(apiKey.auth.mode == .apiKey && apiKey.auth.secret == "token")
        let empty = try CurlCommand.parse("curl --data-raw '' https://example.com").makeRequest()
        precondition(empty.httpBody?.isEmpty == true)
        for invalid in [
            "curl https://example.com | echo test",
            #"curl "https://example.com/$(hostname)""#,
            "curl --data-binary @example.json https://example.com",
            "curl --form 'document=@file.txt' https://example.com",
            "curl https://example.com https://another.example",
        ] {
            do {
                _ = try CurlCommand.parse(invalid)
                preconditionFailure("错误地导入了命令")
            } catch {}
        }
    }

    static func checkGeneratedAuthentication() throws {
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let signature = "iuEohmE1vIhncyWDr5w_k7MaTlVbk7jfiX8QEUAO6ZE"
        var signed = RequestDraft(
            url: "https://example.com/api/v1/{hostname}/ping?debug=1",
            variables: ["hostname": "node/a"],
            auth: RequestAuthentication(mode: .hmac, name: "demo-key", secret: "demo-secret")
        )
        let request = try signed.makeRequest(at: time)
        precondition(request.url?.absoluteString ==
            "https://example.com/api/v1/node%2Fa/ping?debug=1&apikey=demo-key&sign=\(signature)&timestamp=1700000000")
        precondition(!(request.url?.absoluteString ?? "").contains("demo-secret"))
        let redacted = signed.withoutStoredAuthentication()
        precondition(redacted.auth.name.isEmpty && redacted.auth.secret == nil)
        let later = try signed.makeRequest(at: time.addingTimeInterval(1))
        precondition(later.url?.absoluteString.hasSuffix("timestamp=1700000001") == true)
        precondition(later.url?.absoluteString.contains(signature) == false)

        signed.auth.placement = .header
        signed.auth.signingURI = "/custom/path"
        let headers = try signed.makeRequest(at: time)
        precondition(headers.url?.absoluteString == "https://example.com/api/v1/node%2Fa/ping?debug=1&timestamp=1700000000")
        precondition(headers.value(forHTTPHeaderField: "apikey") == "demo-key")
        precondition(headers.value(forHTTPHeaderField: "sign") == "-VN97RyUsnGZzyxDOtrTgBvoQtMVea3ZtlAG9ykzMyo")

        signed.auth.placement = .body
        signed.method = .post
        signed.body = #"{"label":"example"}"#
        let bodyRequest = try signed.makeRequest(at: time)
        let body = try JSONSerialization.jsonObject(with: bodyRequest.httpBody!) as? [String: String]
        precondition(body?["label"] == "example" && body?["apikey"] == "demo-key")
        precondition(body?["sign"] == "-VN97RyUsnGZzyxDOtrTgBvoQtMVea3ZtlAG9ykzMyo")
        precondition(bodyRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        signed.query = [RequestField("timestamp", "1")]
        do {
            _ = try signed.makeRequest(at: time)
            preconditionFailure("允许了重复时间戳")
        } catch RequestError.duplicateAuthentication("timestamp") {}

        var scripted = RequestDraft(
            method: .post, url: "https://example.com/api/v1/{hostname}/ping?debug=1",
            variables: ["hostname": "node/a", "privateInput": "demo-secret"],
            auth: RequestAuthentication(
                mode: .script,
                script: """
                if (typeof fetch !== "undefined" || typeof require !== "undefined" || typeof ObjC !== "undefined") {
                    throw new Error("不应暴露系统接口");
                }
                const message = [inputs.key, inputs.secret, request.uri, timestamp].join("_");
                return {
                    headers: { "X-Method": request.method },
                    query: { timestamp, sign: crypto.hmacSHA256Base64URL(inputs.secret, message) },
                    body: { debug: request.query[0].value, metadata: { ok: true } }
                };
                """,
                scriptInputs: [RequestField("key", "demo-key"), RequestField("secret", "{privateInput}")]
            ),
            body: #"{"label":"example"}"#
        )
        let custom = try scripted.makeRequest(at: time)
        precondition(custom.url?.absoluteString ==
            "https://example.com/api/v1/node%2Fa/ping?debug=1&sign=\(signature)&timestamp=1700000000")
        precondition(custom.value(forHTTPHeaderField: "X-Method") == "POST")
        let customBody = try JSONSerialization.jsonObject(with: custom.httpBody!) as? [String: Any]
        precondition(customBody?["label"] as? String == "example" && customBody?["debug"] as? String == "1")
        precondition((customBody?["metadata"] as? [String: Bool])?["ok"] == true)
        let stored = scripted.withoutStoredAuthentication()
        precondition(stored.auth.script == scripted.auth.script && stored.auth.scriptInputs?.allSatisfy { $0.value == nil } == true)
        precondition(stored.variables == ["hostname": "node/a"])

        scripted.auth.script = "return { query: { timestamp: 123 } };"
        do {
            _ = try scripted.makeRequest(at: time)
            preconditionFailure("接受了非字符串查询值")
        } catch RequestError.invalidAuthOutput {}

        scripted.auth.script = "while (true) {}"
        let started = ContinuousClock.now
        do {
            _ = try scripted.makeRequest(at: time)
            preconditionFailure("超时脚本仍返回了结果")
        } catch RequestError.authScriptInterrupted {}
        precondition(started.duration(to: .now) < .seconds(5))
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

        let request = try RequestDraft(url: "https://example.com/wait").makeRequest()
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

        let json = try RequestDraft(url: "https://example.com/json").makeRequest()
        let result = try await HTTPClient.send(json, using: session)
        precondition(result.status == 418)
        precondition(result.headers.lowercased().contains("content-type: application/json"))
        precondition(result.body.contains("\n") && result.body.contains("ok"))
        precondition(!result.truncated)

        let large = try RequestDraft(url: "https://example.com/large").makeRequest()
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
