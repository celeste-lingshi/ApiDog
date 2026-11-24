import Foundation

enum CurlCommand {
    static func render(_ request: URLRequest, followsRedirects: Bool, route: RequestRoute? = nil,
                       projection: String? = nil) -> String {
        var options = requestOptions(request, followsRedirects: followsRedirects, route: route)
        if projection != nil { options.insert(contentsOf: [["--silent"], ["--show-error"]], at: 1) }
        let lines = options.map { option in
            ([option[0]] + option.dropFirst().map(quote)).joined(separator: " ")
        }
        let command = (["curl " + lines[0]] + lines.dropFirst()).joined(separator: " \\\n  ")
        if let projection { return command + " |\n  jq -r " + quote(projection) }
        return command
    }

    static func requestOptions(_ request: URLRequest, followsRedirects: Bool, route: RequestRoute?) -> [[String]] {
        var parts = [["--globoff"]]
        if followsRedirects { parts.append(["--location"]) }
        if let resolve = route?.resolve { parts.append(["--resolve", resolve]) }
        if let noProxy = route?.noProxy { parts.append(["--noproxy", noProxy]) }
        if request.httpMethod == HTTPMethod.head.rawValue {
            parts.append(["--head"])
        } else if let method = request.httpMethod, !(method == "POST" && request.httpBody != nil) {
            parts.append(["--request", method])
        }
        if let address = request.url?.absoluteString { parts.append(["--url", address]) }
        for (name, value) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key }) {
            let field = value.isEmpty ? name + ";" : name + ": " + value
            parts.append(["--header", field])
        }
        if let body = request.httpBody {
            parts.append(["--data-raw", String(decoding: body, as: UTF8.self)])
        }
        return parts
    }

    static func parse(_ text: String) throws -> RequestDraft {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.range(of: #"\A[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil {
            return try SignedCurlRecipe.parse(source)
        }
        return try parseCommand(source)
    }

    static func parseCommand(_ text: String, substitutions: [String: String]? = nil,
                             templateVariables: [String: String] = [:]) throws -> RequestDraft {
        let (arguments, pipeline) = try tokenize(text, substitutions: substitutions, allowingPipe: true)
        guard arguments.first == "curl" else { throw CurlError.missingCommand }
        var templates = arguments
        if var substitutions, !templateVariables.isEmpty {
            for name in templateVariables.keys { substitutions[name] = "{{\(name)}}" }
            (templates, _) = try tokenize(text, substitutions: substitutions, allowingPipe: true)
        }
        var draft = RequestDraft(variables: templateVariables)
        if let pipeline {
            guard pipeline.count == 3, pipeline[0] == "jq",
                  ["-r", "--raw-output"].contains(pipeline[1]) else { throw CurlError.unsupportedPipeline }
            _ = try ResponseProjection(pipeline[2])
            draft.projection = pipeline[2]
        }
        var route = RequestRoute()
        var method: HTTPMethod?
        var url: (literal: String, template: String)?
        var data: [String] = []
        var auth: RequestAuthentication?
        var get = false
        var head = false
        var json = false
        var endOptions = false

        func setURL(_ value: (literal: String, template: String)) throws {
            guard url == nil else { throw CurlError.multipleURLs }
            url = value
        }

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            let template = templates[index]
            index += 1
            if endOptions || !argument.hasPrefix("-") {
                try setURL((argument, template))
                continue
            }
            if argument == "--" {
                endOptions = true
                continue
            }
            let split = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let attachedShort = !argument.hasPrefix("--") && argument.count > 2
                && ["-X", "-H", "-d", "-u", "-b", "-A", "-e"].contains(String(argument.prefix(2)))
            let option = attachedShort ? String(argument.prefix(2)) : String(split[0])
            var attached = attachedShort ? String(argument.dropFirst(2)) : (split.count == 2 ? String(split[1]) : nil)

            func pair() throws -> (literal: String, template: String) {
                if let inline = attached {
                    attached = nil
                    let parsed = attachedShort ? String(template.dropFirst(2))
                        : template.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init)
                    return (inline, parsed ?? inline)
                }
                guard index < arguments.count else { throw CurlError.missingValue(option) }
                defer { index += 1 }
                return (arguments[index], templates[index])
            }

            func value() throws -> String { try pair().literal }

            switch option {
            case "--url":
                try setURL(pair())
            case "-X", "--request":
                let name = try value().uppercased()
                guard let httpMethod = HTTPMethod(rawValue: name) else { throw CurlError.unsupportedMethod(name) }
                method = httpMethod
            case "-H", "--header":
                let raw = try value()
                if raw.hasSuffix(";"), !raw.contains(":") {
                    draft.headers.append(RequestField(String(raw.dropLast())))
                } else if let field = RequestField.header(raw), field.value != "" {
                    draft.headers.append(field)
                } else {
                    throw CurlError.invalidHeader
                }
            case "-d", "--data", "--data-ascii", "--data-raw", "--data-binary", "--json":
                let raw = try value()
                if option != "--data-raw", raw.hasPrefix("@") { throw CurlError.fileReference }
                data.append(raw)
                json = json || option == "--json"
            case "--data-urlencode":
                let raw = try value()
                if let equal = raw.firstIndex(of: "=") {
                    let name = String(raw[..<equal])
                    let content = String(raw[raw.index(after: equal)...])
                    data.append((name.isEmpty ? "" : name + "=") + RequestDraft.percentEncode(content))
                } else {
                    guard !raw.contains("@") else { throw CurlError.fileReference }
                    data.append(RequestDraft.percentEncode(raw))
                }
            case "-u", "--user":
                let raw = try value()
                guard let colon = raw.firstIndex(of: ":"), auth == nil else { throw CurlError.invalidCredentials }
                auth = RequestAuthentication(mode: .basic, name: String(raw[..<colon]),
                                             secret: String(raw[raw.index(after: colon)...]))
            case "--oauth2-bearer":
                guard auth == nil else { throw CurlError.invalidCredentials }
                auth = RequestAuthentication(mode: .bearer, secret: try value())
            case "-b", "--cookie":
                let raw = try value()
                guard raw.contains("=") else { throw CurlError.fileReference }
                draft.headers.append(RequestField("Cookie", raw))
            case "-A", "--user-agent":
                draft.headers.append(RequestField("User-Agent", try value()))
            case "-e", "--referer":
                let raw = try value()
                guard !raw.hasSuffix(";auto") else { throw CurlError.unsupported(option) }
                draft.headers.append(RequestField("Referer", raw))
            case "-I", "--head": head = true
            case "-G", "--get": get = true
            case "-L", "--location": draft.followsRedirects = true
            case "--resolve":
                guard route.resolve == nil else { throw RouteError.invalidResolve }
                route.resolve = try pair().template
            case "--noproxy": route.noProxy = try pair().template
            case "-g", "--globoff", "--compressed", "--basic", "-s", "-S", "-sS", "-fsS", "-f", "--fail", "--silent", "--show-error":
                break
            default:
                throw CurlError.unsupported(option)
            }
            if attached != nil { throw CurlError.unsupported(argument) }
        }

        guard let url, let components = URLComponents(string: url.literal),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else {
            throw CurlError.invalidURL
        }
        if !get && !data.isEmpty && (head || method?.allowsBody == false) { throw CurlError.unsupportedBody }
        draft.method = method ?? (head ? .head : (get || data.isEmpty ? .get : .post))
        if head && draft.method != .head { throw CurlError.unsupportedBody }

        func addressWithoutQuery(_ address: String) -> String {
            String(address.prefix { $0 != "#" && $0 != "?" })
        }
        let literalAddress = addressWithoutQuery(url.literal)
        let templateAddress = addressWithoutQuery(url.template)
        // 变量若包含查询或片段，沿用已拆分的地址，避免把参数重复拼进去。
        draft.url = (try? draft.expand(templateAddress, encodeSegments: true)) == literalAddress
            ? templateAddress : literalAddress
        draft.query = (components.queryItems ?? []).map { RequestField($0.name, $0.value) }
        if get, !data.isEmpty {
            let suffix = data.joined(separator: "&")
            guard !suffix.contains("#"), !suffix.contains(where: \.isWhitespace),
                  let query = URLComponents(string: "http://localhost/?" + suffix) else {
                throw CurlError.invalidQuery
            }
            draft.query += (query.queryItems ?? []).map { RequestField($0.name, $0.value) }
        } else if !data.isEmpty {
            draft.body = data.joined(separator: json ? "" : "&")
            if !draft.headers.contains(where: { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
                draft.headers.append(RequestField("Content-Type", json ? "application/json" : "application/x-www-form-urlencoded"))
            }
        }
        if json, !draft.headers.contains(where: { $0.name.caseInsensitiveCompare("Accept") == .orderedSame }) {
            draft.headers.append(RequestField("Accept", "application/json"))
        }

        let authorization = draft.headers.indices.filter {
            draft.headers[$0].name.caseInsensitiveCompare("Authorization") == .orderedSame
        }
        if let auth {
            guard authorization.isEmpty else { throw CurlError.invalidCredentials }
            draft.auth = auth
        } else if authorization.count == 1, let position = authorization.first,
                  let auth = decodeAuthorization(draft.headers[position].value ?? "") {
            draft.auth = auth
            draft.headers.remove(at: position)
        }
        if draft.auth.mode == .none {
            let keys = draft.headers.indices.filter { draft.headers[$0].name.caseInsensitiveCompare("X-API-Key") == .orderedSame }
            if keys.count == 1, let position = keys.first, let secret = draft.headers[position].value, !secret.isEmpty {
                draft.auth = RequestAuthentication(mode: .apiKey, name: draft.headers[position].name, secret: secret)
                draft.headers.remove(at: position)
            }
        }
        if route.isConfigured { draft.route = route }
        do {
            _ = try draft.makeRequest()
        } catch RequestError.missingVariable {
            // 模板变量可在导入后填写。
        }
        return draft
    }

    private static func decodeAuthorization(_ value: String) -> RequestAuthentication? {
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        switch parts[0].lowercased() {
        case "bearer": return RequestAuthentication(mode: .bearer, secret: String(parts[1]))
        case "basic":
            guard let data = Data(base64Encoded: String(parts[1])), let credentials = String(data: data, encoding: .utf8),
                  let colon = credentials.firstIndex(of: ":"), colon != credentials.startIndex else { return nil }
            return RequestAuthentication(mode: .basic, name: String(credentials[..<colon]),
                                         secret: String(credentials[credentials.index(after: colon)...]))
        default: return nil
        }
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private enum Quoting { case plain, single, double, ansi }

    static func tokenize(_ text: String, substitutions: [String: String]? = nil, allowingPipe: Bool = false)
        throws -> ([String], [String]?) {
        var mode = Quoting.plain
        var words: [String] = []
        var beforePipe: [String]?
        var word = ""
        var started = false
        var cursor = text.startIndex

        func next() -> Character? {
            guard cursor != text.endIndex else { return nil }
            let character = text[cursor]
            text.formIndex(after: &cursor)
            return character
        }

        func variable() throws -> String {
            guard let substitutions, cursor != text.endIndex else { throw CurlError.shellExpression }
            let braced = text[cursor] == "{"
            if braced { text.formIndex(after: &cursor) }
            let start = cursor
            while cursor != text.endIndex, text[cursor].isASCII,
                  text[cursor].isLetter || text[cursor].isNumber || text[cursor] == "_" {
                text.formIndex(after: &cursor)
            }
            let name = String(text[start..<cursor])
            if braced, next() != "}" { throw CurlError.shellExpression }
            guard let value = substitutions[name] else { throw CurlError.unknownVariable(name) }
            return value
        }

        while let c = next() {
            if mode == .single {
                if c == "'" { mode = .plain } else { word.append(c) }
                continue
            }
            if mode == .ansi {
                if c == "'" { mode = .plain; continue }
                if c != "\\" { word.append(c); continue }
                guard let next = next() else { throw CurlError.invalidQuoting }
                switch next {
                case "n": word.append("\n")
                case "r": word.append("\r")
                case "t": word.append("\t")
                case "\\", "'", "\"": word.append(next)
                default: throw CurlError.invalidQuoting
                }
                continue
            }
            if c == "\\" {
                guard let escaped = next() else { throw CurlError.invalidQuoting }
                if escaped.isNewline { continue }
                if mode == .double && !"\"\\$".contains(escaped) { word.append("\\") }
                word.append(escaped)
                started = true
                continue
            }
            if mode == .double {
                if c == "\"" { mode = .plain }
                else if c == "$" { word += try variable() }
                else if c == "\u{60}" { throw CurlError.shellExpression }
                else { word.append(c) }
                continue
            }
            if c.isWhitespace {
                if started { words.append(word); word = ""; started = false }
                continue
            }
            if c == "|", allowingPipe {
                guard beforePipe == nil else { throw CurlError.unsupportedPipeline }
                if started { words.append(word); word = ""; started = false }
                beforePipe = words
                words = []
                continue
            }
            started = true
            switch c {
            case "'": mode = .single
            case "\"": mode = .double
            case "$":
                guard next() == "'" else { throw CurlError.shellExpression }
                mode = .ansi
            case "\u{60}", ";", "|", "&", ">", "<", "(", ")": throw CurlError.shellExpression
            default: word.append(c)
            }
        }
        guard mode == .plain else { throw CurlError.invalidQuoting }
        if started { words.append(word) }
        return beforePipe.map { ($0, words) } ?? (words, nil)
    }
}

enum CurlError: LocalizedError {
    case missingCommand, multipleURLs, invalidURL, invalidQuoting, shellExpression, fileReference
    case unsupported(String), missingValue(String), unsupportedMethod(String), invalidHeader, invalidCredentials
    case unsupportedBody, invalidQuery, unsupportedPipeline, unknownVariable(String)

    var errorDescription: String? {
        switch self {
        case .missingCommand: return "请粘贴以 curl 开头的命令。"
        case .multipleURLs: return "一次只能导入一个请求地址。"
        case .invalidURL: return "命令需要一个完整的 HTTP 或 HTTPS 地址。"
        case .invalidQuoting: return "命令里的引号或转义不完整，或包含暂不支持的转义。"
        case .shellExpression: return "命令含 Shell 表达式。请粘贴已展开的请求命令。"
        case .fileReference: return "导入仅接收文本，不会读取文件引用。"
        case .unsupported(let option): return "暂不支持 cURL 参数 \(option)。"
        case .missingValue(let option): return "cURL 参数 \(option) 缺少值。"
        case .unsupportedMethod(let method): return "暂不支持请求方法 \(method)。"
        case .invalidHeader: return "请检查 cURL 的请求头。目前支持带值的请求头和末尾为分号的空请求头。"
        case .invalidCredentials: return "请使用明确的一种认证方式，Basic 需要用户名和密码。"
        case .unsupportedBody: return "请求方法和正文选项不兼容，GET 或 HEAD 无法携带正文。"
        case .unsupportedPipeline: return "响应管道支持 jq -r 和简单字段路径，例如 .reason[]?.port。"
        case .unknownVariable(let name): return "无法静态展开 Shell 变量「\(name)」。"
        case .invalidQuery: return "请先对 cURL 的查询字符串做 URL 编码，或使用 --data-urlencode。"
        }
    }
}
