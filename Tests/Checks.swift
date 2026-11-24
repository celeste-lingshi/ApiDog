import CryptoKit
import Foundation

@main
struct Checks {
    static func main() async throws {
        if AuthScript.runWorkerIfRequested() { return }
        try checkRequest()
        try checkWorkspace()
        try checkRequestDirectory()
        try checkCurl()
        try checkSignedCurlRecipe()
        try checkGeneratedAuthentication()
        try await checkResponse()
        try await checkCancellation()
        print("通过：请求内变量和认证、旧历史读取、分类与请求保存、凭证落盘、签名、脚本认证、cURL 导入导出、签名命令导入与响应提取、响应处理、请求取消")
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

    static func checkRequestDirectory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = SymmetricKey(size: .bits256)
        let storage = WorkspaceStorage(file: folder.appendingPathComponent("workspace.json"), credentialKey: { _ in key })
        var workspace = try storage.load()
        let category = RequestCategory(name: "测试分组")
        workspace.requestDirectory.categories.append(category)
        let draft = RequestDraft(
            url: "https://example.com/{host}/ping",
            variables: ["host": "example", "token": "directory-private-key"],
            auth: RequestAuthentication(mode: .hmac, name: "directory-api-key", secret: "{token}")
        )
        var saved = SavedRequest(name: "查询接口", categoryID: category.id, draft: draft)
        workspace.requestDirectory.store(saved)
        precondition(workspace.requestDirectory.requests(in: category.id) == [saved])
        workspace.append(HistoryEntry(date: .now, request: draft, status: 200, milliseconds: 10))
        saved.categoryID = nil
        saved.name = "重新命名"
        workspace.requestDirectory.store(saved)
        precondition(workspace.requestDirectory.requests(in: category.id).isEmpty)
        precondition(workspace.requestDirectory.requests(in: nil) == [saved])
        precondition(workspace.history.count == 1)

        try storage.save(workspace)
        let reopened = WorkspaceStorage(file: storage.file, credentialKey: { create in
            precondition(!create)
            return key
        })
        let restored = try reopened.load()
        let contents = try String(contentsOf: storage.file, encoding: .utf8)
        precondition(restored.requestDirectory.categories == [category])
        precondition(restored.requestDirectory.requests.count == 1)
        precondition(restored.requestDirectory.requests[0].id == saved.id)
        precondition(restored.requestDirectory.requests[0].name == "重新命名")
        precondition(restored.requestDirectory.requests[0].draft == draft)
        precondition(restored.history[0].request == draft.withoutStoredAuthentication())
        precondition(!contents.contains("directory-private-key") && !contents.contains("directory-api-key"))

        workspace.history.removeAll()
        precondition(workspace.requestDirectory.requests == [saved])
        workspace.append(HistoryEntry(date: .now, request: draft, status: 200, milliseconds: 11))
        workspace.requestDirectory.requests.removeAll { $0.id == saved.id }
        precondition(workspace.history.count == 1 && workspace.requestDirectory.requests.isEmpty)

        saved.draft.method = .post
        saved.draft.headers = [RequestField("X-Copy-Test", "enabled")]
        saved.draft.query = [RequestField("limit", "1")]
        saved.draft.body = #"{"test":true}"#
        saved.draft.route = RequestRoute(resolve: "example.com:443:127.0.0.1", noProxy: "example.com")
        saved.draft.projection = ".items[]"
        let copy = saved.duplicate(name: "跨目录副本", categoryID: category.id)
        workspace.requestDirectory.store(saved)
        workspace.requestDirectory.store(copy)
        precondition(copy.id != saved.id && copy.name == "跨目录副本" && copy.draft == saved.draft)
        precondition(workspace.requestDirectory.requests(in: nil) == [saved])
        precondition(workspace.requestDirectory.requests(in: category.id) == [copy])
        var editedCopy = copy
        editedCopy.draft.variables["host"] = "copied"
        editedCopy.draft.auth = RequestAuthentication(mode: .script, script: "function generate() {}",
                                                     scriptInputs: [RequestField("key", "script-api-key")])
        editedCopy.draft.variables.removeValue(forKey: "token")
        workspace.requestDirectory.store(editedCopy)
        precondition(workspace.requestDirectory.requests(in: nil) == [saved])

        try storage.save(workspace)
        let afterEdit = try storage.load().requestDirectory
        precondition(afterEdit.requests(in: category.id) == [editedCopy])
        precondition(afterEdit.requests(in: nil) == [saved])
        let bytes = try Data(contentsOf: storage.file)
        precondition(!String(decoding: bytes, as: UTF8.self).contains("script-api-key"))

        let destination = RequestCategory(name: "归档")
        workspace.requestDirectory.categories.append(destination)
        let missingCategory = workspace.requestDirectory.move(editedCopy.id, to: UUID())
        let missingRequest = workspace.requestDirectory.move(UUID(), to: destination.id)
        let sameCategory = workspace.requestDirectory.move(editedCopy.id, to: category.id)
        precondition(!missingCategory && !missingRequest && !sameCategory)
        let moved = workspace.requestDirectory.move(editedCopy.id, to: destination.id)
        var expected = editedCopy
        expected.categoryID = destination.id
        precondition(moved && workspace.requestDirectory.requests(in: category.id).isEmpty)
        precondition(workspace.requestDirectory.requests(in: destination.id) == [expected])
        try storage.save(workspace)
        let afterMove = try storage.load()
        precondition(afterMove.requestDirectory.requests(in: destination.id) == [expected])
        precondition(afterMove.history.count == 1)
        let movedToRoot = workspace.requestDirectory.move(editedCopy.id, to: nil)
        expected.categoryID = nil
        precondition(movedToRoot && workspace.requestDirectory.requests(in: nil) == [saved, expected])

        let wrongKey = WorkspaceStorage(file: storage.file, credentialKey: { _ in SymmetricKey(size: .bits256) })
        do {
            _ = try wrongKey.load()
            preconditionFailure("用错误的密钥打开了认证信息")
        } catch CryptoKitError.authenticationFailure {}
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
        precondition(queryRequest.httpBody == nil)
        let form = try CurlCommand.parse("curl --data-urlencode 'vip=a+b' https://example.com").makeRequest()
        precondition(form.httpMethod == "POST" && form.url?.absoluteString == "https://example.com")
        precondition(form.httpBody == Data("vip=a%2Bb".utf8))
        precondition(form.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
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

    static func checkSignedCurlRecipe() throws {
        let source = #"""
        api_host=demo.example.test
          api_path=/api/v1/list
          api_ts=$(date +%s)
          api_sign=$(printf '%s' "${LIST_API_KEY}_${LIST_SECRET}_${api_path}_${api_ts}" |
            openssl dgst -sha256 -hmac "$LIST_SECRET" -binary |
            openssl base64 -A | tr '/+' '_-' | tr -d '=')

          curl -fsS --noproxy "$api_host" --resolve "$api_host:8009:127.0.0.1" \
            --get "http://$api_host:8009$api_path" \
            --data-urlencode 'value=a+b' \
            --data-urlencode "key=$LIST_API_KEY" \
            --data-urlencode "timestamp=$api_ts" \
            --data-urlencode "sign=$api_sign" |
            jq -r '.reason[]?.port'
        """#
        var parsed = try CurlCommand.parse(source)
        precondition(parsed.url == "http://{{api_host}}:8009{{api_path}}")
        precondition(parsed.variableNames == ["api_host", "api_path"])
        precondition(parsed.variables == ["api_host": "demo.example.test", "api_path": "/api/v1/list"])
        precondition(parsed.method == .get && parsed.query.count == 1)
        precondition(parsed.query[0].name == "value" && parsed.query[0].value == "a+b")
        precondition(parsed.auth.mode == .hmac && parsed.auth.keyField == "key")
        precondition(parsed.auth.signingKeyInput == "LIST_API_KEY" && parsed.auth.signingSecretInput == "LIST_SECRET")
        precondition(parsed.auth.name.isEmpty && parsed.auth.secret == nil)
        precondition(parsed.auth.signingURI == "{{api_path}}")
        precondition(parsed.route == RequestRoute(resolve: "{{api_host}}:8009:127.0.0.1", noProxy: "{{api_host}}"))
        let route = try parsed.resolvedRoute()
        precondition(route == RequestRoute(resolve: "demo.example.test:8009:127.0.0.1", noProxy: "demo.example.test"))
        precondition(parsed.projection == ".reason[]?.port")
        let format = try ResponseProjection(parsed.projection!)
        let ports = try format.format(#"{"reason":[{"port":80},{"port":"443"}]}"#)
        let noPorts = try format.format(#"{"reason":null}"#)
        precondition(ports == "80\n443" && noPorts.isEmpty)

        parsed.auth.name = "demo-key"
        parsed.auth.secret = "demo-secret"
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let request = try parsed.makeRequest(at: fixed)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        precondition(query.contains(URLQueryItem(name: "key", value: "demo-key")))
        precondition(query.contains(URLQueryItem(name: "timestamp", value: "1700000000")))
        precondition(query.filter { $0.name == "sign" && $0.value?.count == 43 }.count == 1)
        let exported = CurlCommand.render(request, followsRedirects: false, route: route, projection: parsed.projection)
        precondition(exported.contains("--resolve 'demo.example.test:8009:127.0.0.1'"))
        precondition(exported.contains("--noproxy 'demo.example.test'"))
        precondition(exported.hasSuffix("jq -r '.reason[]?.port'"))
        let roundTrip = try CurlCommand.parse(exported)
        let replayed = try roundTrip.makeRequest()
        precondition(replayed.url == request.url && roundTrip.route == route)
        precondition(roundTrip.projection == parsed.projection)

        parsed.variables["api_host"] = "updated.example.test"
        parsed.variables["api_path"] = "/api/v2/list"
        let updated = try parsed.makeRequest(at: fixed)
        let updatedRoute = try parsed.resolvedRoute()
        precondition(updated.url?.host == "updated.example.test" && updated.url?.path == "/api/v2/list")
        precondition(updatedRoute == RequestRoute(resolve: "updated.example.test:8009:127.0.0.1", noProxy: "updated.example.test"))
        let updatedQuery = URLComponents(url: updated.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let signature = AuthCrypto.hmacBase64URL("demo-secret", "demo-key_demo-secret_/api/v2/list_1700000000")
        precondition(updatedQuery.contains(URLQueryItem(name: "sign", value: signature)))
        precondition(parsed.auth.generatedQueryNames == ["key", "timestamp", "sign"])

        for invalid in [
            source.replacingOccurrences(of: "date +%s", with: "date +%N"),
            source.replacingOccurrences(of: "$api_sign", with: "$LIST_SECRET"),
            source.replacingOccurrences(of: "127.0.0.1", with: "invalid-address"),
            source.replacingOccurrences(of: ".reason[]?.port", with: ".reason | length"),
            source.replacingOccurrences(of: "sign=$api_sign", with: "sign=prefix$api_sign"),
            "curl --resolve 'other.example.test:80:127.0.0.1' http://demo.example.test",
        ] {
            do {
                _ = try CurlCommand.parse(invalid)
                preconditionFailure("接受了不支持的命令")
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
